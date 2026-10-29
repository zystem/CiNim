## The store of the step secrets (IAM-003, SEC-001, 6.7): values encrypted in the shard's database, so that they are backed up and restored with it.
##
## Envelope encryption with XChaCha20-Poly1305 (libsodium, common/sodiumaead.nim; D-45). A master key (the KEK) wraps one data key (DEK) per organisation; a DEK encrypts the values of that organisation
## only. Every ciphertext binds what it is to its place (the additional data holds the tenant, the name and the version), so a row cannot be swapped for
## another. The KEK is not in the database: it is a file the operator provides (`CINIM_SECRETS_KEY_FILE`, 64 hex digits) or, when none is given, derived from
## the core's own CURVE key, which the operator already keeps; it has to be backed up apart from the database (a database restored without it holds
## nothing readable; GitLab and Drone say the same of their keys). A check value is stored with the first secret, so that a core that starts with another
## key refuses to serve secrets instead of writing new ones that the old ones cannot be read with.
##
## `KekProvider` is the seam for a key that lives elsewhere (a PKCS#11 token behind p11-kit or a YubiHSM connector, Vault or OpenBao Transit, a cloud KMS):
## the vault only asks it to wrap and unwrap a data key. Built so far: `fileKek` and `derivedKek`.
import std/[strutils, json, atomics, locks, tables]
import std/times
import crunchy
import ../common/[rqlite, ctrlauth, sodiumaead]
import kekprovider, dekcache, stepsecrets
export kekprovider

const formatTag = "v2."      ## the format of a sealed text: the algorithm is named by it, so that another can follow

func toHex(a: openArray[byte]): string =
  const digits = "0123456789abcdef"
  for b in a:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

func fromHex(s: string): tuple[ok: bool, bytes: seq[byte]] =
  if s.len mod 2 != 0: return
  var i = 0
  while i < s.len:
    let v = try: parseHexInt(s[i .. i + 1]) except ValueError: return
    result.bytes.add byte(v)
    i += 2
  result.ok = true

proc seal*(key: openArray[byte]; plain: string; aad: string): string =
  ## `v2.` and hex of nonce, ciphertext and tag; the nonce is fresh and random
  let nonce = randomBytes(nonceBytes)
  formatTag & toHex(nonce) & toHex(encrypt(key, nonce, plain, aad))

proc unseal*(key: openArray[byte]; sealed, aad: string): tuple[ok: bool, plain: string] =
  ## not ok when the key is another, the text was changed, or it belongs to another place (another additional data)
  if key.len != keyBytes or not sealed.startsWith(formatTag): return
  let raw = fromHex(sealed[formatTag.len .. ^1])
  if not raw.ok or raw.bytes.len < nonceBytes + tagBytes: return
  decrypt(key, raw.bytes[0 ..< nonceBytes], raw.bytes[nonceBytes .. ^1], aad)

# ------------------------------------------------------------------ the master key

proc kekFromBytes(id: string; key: seq[byte]): KekProvider =
  let k = key
  KekProvider(id: id,
    wrap: proc (plain: seq[byte]; aad: string): WrapResult {.gcsafe.} =
      var t = newString(plain.len)
      if plain.len > 0: copyMem(addr t[0], unsafeAddr plain[0], plain.len)
      (true, false, "", seal(k, t, aad)),
    unwrap: proc (wrapped: string; aad: string): UnwrapResult {.gcsafe.} =
      let u = unseal(k, wrapped, aad)
      if not u.ok: return refused("the key is not the one that wrapped this")
      result.ok = true
      for ch in u.plain: result.plain.add byte(ch))

proc fileKek*(path: string): tuple[ok: bool, kek: KekProvider, error: string] =
  ## the key from a file of 64 hex digits (the operator's own, kept apart from the database)
  let text = try: readFile(path).strip except IOError: return (false, KekProvider(), "cannot read " & path)
  let raw = fromHex(text)
  if not raw.ok or raw.bytes.len != keyBytes: return (false, KekProvider(), path & " must hold 64 hexadecimal digits (32 bytes)")
  (true, kekFromBytes("file", raw.bytes), "")

proc derivedKek*(coreSecretKey: string): KekProvider =
  ## no key given: HMAC-SHA256 of a fixed text under the core's own CURVE key (the operator keeps that key already; changing it loses the secrets)
  let d = hmacSha256(coreSecretKey, "cinim/secrets/kek/v1")
  var k = newSeq[byte](keyBytes)
  for i in 0 ..< keyBytes: k[i] = d[i]
  kekFromBytes("derived-from-core-key", k)

# ------------------------------------------------------------------ the rows

func dekAad(tenant: string): string = "cinim/dek/v1|" & tenant
func valueAad(tenant, name: string; version: int; groupId = ""): string =
  ## the organisation's secret keeps the form it was sealed in (v1); one of a group has the group in it, so that a value moved to another group's row does not open
  if groupId.len == 0: "cinim/secret/v1|" & tenant & "|" & name & "|" & $version
  else: "cinim/secret/v2|" & tenant & "|" & groupId & "|" & name & "|" & $version
const checkAad = "cinim/kek-check/v1"
const checkText = "cinim secrets key check"

var
  kekReport*: proc (up: bool) {.gcsafe.}      ## told whether the master key answered (the component `keyservice` in /api/v1/components); set by vaultsetup.nim
  vaultErrorText: string
  vaultErrorLock: Lock
initLock(vaultErrorLock)

proc setVaultError*(text: string) =
  withLock vaultErrorLock: vaultErrorText = text

proc vaultError*(): string =
  withLock vaultErrorLock: result = if vaultErrorText.len > 0: vaultErrorText else: "the secrets are not set up"

proc told(up: bool) =
  if kekReport != nil: kekReport(up)

var deks = initDekCache(600.0)          ## see core/dekcache.nim; the time can be set with `setDekCacheSeconds`

proc setDekCacheSeconds*(seconds: float) =
  deks.ttl = seconds

proc ensureKeyCheck*(c: var RqClient; kek: KekProvider): tuple[ok, retry: bool, error: string] =
  ## the first start stores a value sealed under the key; a later start with another key finds that it cannot read it
  let r = c.query(%*[["SELECT value FROM vault_meta WHERE key = 'kek_check'"]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0:
    let w = kek.wrap(@(checkText.toOpenArrayByte(0, checkText.high)), checkAad)
    if not w.ok: return (false, w.retry, "the key of the secrets (" & kek.id & ") cannot be used: " & w.error)
    discard c.execute(%*[["INSERT OR IGNORE INTO vault_meta (key, value) VALUES ('kek_check', ?)", w.wrapped]])
    return (true, false, "")
  let u = kek.unwrap(vals[0][0].getStr, checkAad)
  if not u.ok:
    if u.retry: return (false, true, "the key of the secrets (" & kek.id & ") does not answer: " & u.error)
    return (false, false, "the key of the secrets (" & kek.id & ") is not the one that sealed the secrets in this database: restore the key, or the secrets cannot be read")
  (true, false, "")

type RekeyReport* = tuple[ok, retry: bool, moved, already, failed: int, errors: seq[string]]

proc rekeyRow(c: var RqClient; oldKek, newKek: KekProvider; dryRun: bool; table, idColumn, id, column, aad: string; rep: var RekeyReport): bool =
  ## one text moved from the old key to the new one: true when it is moved or was, false when it is left (and told)
  let cur = c.query(%*[["SELECT " & column & " FROM " & table & " WHERE " & idColumn & " = ?", id]])["results"][0]{"values"}
  if cur == nil or cur.len == 0: return true
  let text = cur[0][0].getStr
  var u = oldKek.unwrap(text, aad)
  defer:
    for i in 0 ..< u.plain.len: u.plain[i] = 0
  if not u.ok:
    if u.retry:
      rep.retry = true
      rep.errors.add table & " " & id & ": the old key does not answer: " & u.error
      return false
    let n = newKek.unwrap(text, aad)
    if n.ok:
      inc rep.already
      return true
    rep.errors.add table & " " & id & ": neither the old key nor the new one opens it (" & u.error & ")"
    return false
  let w = newKek.wrap(u.plain, aad)
  if not w.ok:
    if w.retry: rep.retry = true
    rep.errors.add table & " " & id & ": the new key cannot seal it: " & w.error
    return false
  let back = newKek.unwrap(w.wrapped, aad)
  if not back.ok or back.plain != u.plain:
    rep.errors.add table & " " & id & ": the new key does not open what it sealed; left as it was"
    return false
  if not dryRun:
    discard c.execute(%*[["UPDATE " & table & " SET " & column & " = ? WHERE " & idColumn & " = ? AND " & column & " = ?", w.wrapped, id, text]])
  inc rep.moved
  true

proc rekeySealed*(c: var RqClient; oldKek, newKek: KekProvider; dryRun = false): RekeyReport =
  ## D-80: the master key moves to another (another key service, a key file, ...). Each data key of an organisation is opened with `oldKek` and sealed with `newKek`, and read back with it, and
  ## only then does the row change (compare-and-set on the text read, so a writer that came in between wins and the next run finds it); the secrets themselves are not touched. The check text
  ## of the vault moves last, and only when every data key has: until then the core still starts with the old key. A row that the old key refuses for good but the new key opens has moved already
  ## (a run that stopped, or was run twice); one that neither opens is told and left. `dryRun` does everything but the change of the rows. `retry`: a key service did not answer; run it again.
  ## The data key is in the memory of this process while it moves, and is wiped after.
  var rep: RekeyReport
  let orgs = c.query(%*[["SELECT tenant_id FROM org_keys ORDER BY tenant_id"]])["results"][0]{"values"}
  if orgs != nil:
    for o in orgs.elems:
      if not c.rekeyRow(oldKek, newKek, dryRun, "org_keys", "tenant_id", o[0].getStr, "wrapped", dekAad(o[0].getStr), rep): inc rep.failed
  if rep.failed == 0:
    # the check text last: with it moved the core starts with the new key only
    if not c.rekeyRow(oldKek, newKek, dryRun, "vault_meta", "key", "kek_check", "value", checkAad, rep): inc rep.failed
  else:
    rep.errors.add "the check text of the vault was not moved: not all the data keys are, and the core still starts with the old key"
  rep.ok = rep.failed == 0
  rep

proc dekFor(c: var RqClient; kek: KekProvider; tenant: string; create: bool): tuple[ok, retry: bool, dek: seq[byte], error: string] =
  let now = epochTime()
  let cached = deks.get(tenant, now)
  if cached.found: return (true, false, cached.dek, "")
  let r = c.query(%*[["SELECT wrapped FROM org_keys WHERE tenant_id = ?", tenant]])
  let vals = r["results"][0]{"values"}
  var wrapped = ""
  if vals != nil and vals.len > 0:
    wrapped = vals[0][0].getStr
  elif not create:
    return (false, false, @[], "the organisation has no data key")
  else:
    let dek = randomBytes(keyBytes)
    let w = kek.wrap(dek, dekAad(tenant))
    told(w.ok or not w.retry)
    if not w.ok: return (false, w.retry, @[], "the key of the secrets cannot wrap: " & w.error)
    discard c.execute(%*[["INSERT OR IGNORE INTO org_keys (tenant_id, wrapped, created_at) VALUES (?, ?, strftime('%s','now'))", tenant, w.wrapped]])
    # another writer may have been first: read what is stored, that is the key
    wrapped = c.query(%*[["SELECT wrapped FROM org_keys WHERE tenant_id = ?", tenant]])["results"][0]{"values"}[0][0].getStr
  let u = kek.unwrap(wrapped, dekAad(tenant))
  told(u.ok or not u.retry)                # a refusal is an answer; only a silence or a locked token is "down"
  if not u.ok: return (false, u.retry, @[], "the data key cannot be opened: " & u.error)
  deks.put(tenant, u.plain, now)
  (true, false, u.plain, "")

proc putSecret*(c: var RqClient; kek: KekProvider; tenant, name, value: string; now: int64; groupId = ""; protected = false): tuple[ok, retry: bool, version: int, error: string] =
  ## a new value is a new version of the secret; `groupId` is the group that holds it ("" for the organisation)
  let d = dekFor(c, kek, tenant, create = true)
  if not d.ok: return (false, d.retry, 0, d.error)
  let cur = c.query(%*[["SELECT version FROM step_secrets WHERE tenant_id = ? AND group_id = ? AND name = ?", tenant, groupId, name]])
  let cv = cur["results"][0]{"values"}
  let version = (if cv != nil and cv.len > 0: cv[0][0].getInt else: 0) + 1
  let sealed = seal(d.dek, value, valueAad(tenant, name, version, groupId))
  discard c.execute(%*[["INSERT INTO step_secrets (tenant_id, group_id, name, version, updated_at, value_enc, protected) VALUES (?, ?, ?, ?, ?, ?, ?) " &
                        "ON CONFLICT(tenant_id, group_id, name) DO UPDATE SET version = excluded.version, updated_at = excluded.updated_at, value_enc = excluded.value_enc, protected = excluded.protected",
                        tenant, groupId, name, version, now, sealed, (if protected: 1 else: 0)]])
  (true, false, version, "")

proc getSecrets*(c: var RqClient; kek: KekProvider; tenant: string; names: seq[string]; groupId = ""; trusted = false): tuple[ok, retry: bool, values: seq[(string, string)], error: string] =
  ## the current values of the named secrets, decrypted, for a run of this group (D-86): the nearest holder of each name up the tree, and a protected one only when `trusted`;
  ## `retry` when the master key does not answer now
  if names.len == 0: return (true, false, @[], "")
  let d = dekFor(c, kek, tenant, create = false)
  if not d.ok: return (false, d.retry, @[], d.error)
  let seen = c.visibleSecrets(tenant, groupId)
  for n in names:
    if n notin seen: return (false, false, @[], "there is no secret " & n & " for this project")
    if seen[n].protected and not trusted: return (false, false, @[], "the secret " & n & " is protected: it goes to runs on a protected ref of the project only")
    let holder = seen[n].groupId
    let r = c.query(%*[["SELECT version, value_enc FROM step_secrets WHERE tenant_id = ? AND group_id = ? AND name = ?", tenant, holder, n]])
    let v = r["results"][0]{"values"}
    if v == nil or v.len == 0 or v[0][1].getStr.len == 0: return (false, false, @[], "the organisation has no secret " & n)
    let u = unseal(d.dek, v[0][1].getStr, valueAad(tenant, n, v[0][0].getInt, holder))
    if not u.ok: return (false, false, @[], "the secret " & n & " cannot be read")
    result.values.add (n, u.plain)
  result.ok = true

proc sealOrgText*(c: var RqClient; kek: KekProvider; tenant, label, plain: string): tuple[ok, retry: bool, sealed, error: string] =
  ## a piece of text that is not a step secret (the password a core binds to a directory with) sealed with the organisation's data key; `label` is bound into it, so that it opens only where it was made for
  let d = dekFor(c, kek, tenant, create = true)
  if not d.ok: return (false, d.retry, "", d.error)
  (true, false, seal(d.dek, plain, "cinim/text/v1|" & tenant & "|" & label), "")

proc openOrgText*(c: var RqClient; kek: KekProvider; tenant, label, sealed: string): tuple[ok, retry: bool, plain, error: string] =
  let d = dekFor(c, kek, tenant, create = false)
  if not d.ok: return (false, d.retry, "", d.error)
  let u = unseal(d.dek, sealed, "cinim/text/v1|" & tenant & "|" & label)
  if not u.ok: return (false, false, "", "the sealed text cannot be opened")
  (true, false, u.plain, "")

# ------------------------------------------------------------------ the active key

var
  activeKek: KekProvider            ## set once at start by the API (before it serves), read by the threads that serve the shims
  kekReady: Atomic[bool]

proc activateVault*(k: KekProvider) =
  activeKek = k
  kekReady.store(true)

proc vaultKek*(): tuple[ready: bool, kek: KekProvider] =
  {.cast(gcsafe).}:
    (kekReady.load, activeKek)
