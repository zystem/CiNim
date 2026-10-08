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
import std/[strutils, json, atomics]
import crunchy
import ../common/[rqlite, ctrlauth, sodiumaead]

const formatTag = "v2."      ## the format of a sealed text: the algorithm is named by it, so that another can follow

type
  KekProvider* = object
    ## wraps and unwraps a data key; `id` says which key it is (kept with the wrapped key)
    id*: string
    wrap*: proc (plain: seq[byte]; aad: string): string {.gcsafe.}
    unwrap*: proc (wrapped: string; aad: string): tuple[ok: bool, plain: seq[byte]] {.gcsafe.}

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
    wrap: proc (plain: seq[byte]; aad: string): string {.gcsafe.} =
      var s = newString(plain.len)
      if plain.len > 0: copyMem(addr s[0], unsafeAddr plain[0], plain.len)
      seal(k, s, aad),
    unwrap: proc (wrapped: string; aad: string): tuple[ok: bool, plain: seq[byte]] {.gcsafe.} =
      let u = unseal(k, wrapped, aad)
      if not u.ok: return
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
func valueAad(tenant, name: string; version: int): string = "cinim/secret/v1|" & tenant & "|" & name & "|" & $version
const checkAad = "cinim/kek-check/v1"
const checkText = "cinim secrets key check"

proc ensureKeyCheck*(c: var RqClient; kek: KekProvider): tuple[ok: bool, error: string] =
  ## the first start stores a value sealed under the key; a later start with another key finds that it cannot read it
  let r = c.query(%*[["SELECT value FROM vault_meta WHERE key = 'kek_check'"]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0:
    let w = kek.wrap(@(checkText.toOpenArrayByte(0, checkText.high)), checkAad)
    discard c.execute(%*[["INSERT OR IGNORE INTO vault_meta (key, value) VALUES ('kek_check', ?)", w]])
    return (true, "")
  let u = kek.unwrap(vals[0][0].getStr, checkAad)
  if not u.ok:
    return (false, "the key of the secrets (" & kek.id & ") is not the one that sealed the secrets in this database: restore the key, or the secrets cannot be read")
  (true, "")

proc dekFor(c: var RqClient; kek: KekProvider; tenant: string; create: bool): tuple[ok: bool, dek: seq[byte]] =
  let r = c.query(%*[["SELECT wrapped FROM org_keys WHERE tenant_id = ?", tenant]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0:
    let u = kek.unwrap(vals[0][0].getStr, dekAad(tenant))
    return (u.ok, u.plain)
  if not create: return
  let dek = randomBytes(keyBytes)
  let w = kek.wrap(dek, dekAad(tenant))
  discard c.execute(%*[["INSERT OR IGNORE INTO org_keys (tenant_id, wrapped, created_at) VALUES (?, ?, strftime('%s','now'))", tenant, w]])
  # another writer may have been first: read what is stored, that is the key
  let again = c.query(%*[["SELECT wrapped FROM org_keys WHERE tenant_id = ?", tenant]])
  let u = kek.unwrap(again["results"][0]{"values"}[0][0].getStr, dekAad(tenant))
  (u.ok, u.plain)

proc putSecret*(c: var RqClient; kek: KekProvider; tenant, name, value: string; now: int64): tuple[ok: bool, version: int, error: string] =
  ## a new value is a new version of the secret
  let d = dekFor(c, kek, tenant, create = true)
  if not d.ok: return (false, 0, "the organisation's data key cannot be read with the key of the secrets")
  let cur = c.query(%*[["SELECT version FROM step_secrets WHERE tenant_id = ? AND name = ?", tenant, name]])
  let cv = cur["results"][0]{"values"}
  let version = (if cv != nil and cv.len > 0: cv[0][0].getInt else: 0) + 1
  let sealed = seal(d.dek, value, valueAad(tenant, name, version))
  discard c.execute(%*[["INSERT INTO step_secrets (tenant_id, name, version, updated_at, value_enc) VALUES (?, ?, ?, ?, ?) " &
                        "ON CONFLICT(tenant_id, name) DO UPDATE SET version = excluded.version, updated_at = excluded.updated_at, value_enc = excluded.value_enc",
                        tenant, name, version, now, sealed]])
  (true, version, "")

proc getSecrets*(c: var RqClient; kek: KekProvider; tenant: string; names: seq[string]): tuple[ok: bool, values: seq[(string, string)], error: string] =
  ## the current values of the named secrets of an organisation, decrypted; not ok when a name is unknown or a value cannot be read
  if names.len == 0: return (true, @[], "")
  let d = dekFor(c, kek, tenant, create = false)
  if not d.ok: return (false, @[], "the organisation has no readable data key")
  for n in names:
    let r = c.query(%*[["SELECT version, value_enc FROM step_secrets WHERE tenant_id = ? AND name = ?", tenant, n]])
    let v = r["results"][0]{"values"}
    if v == nil or v.len == 0 or v[0][1].getStr.len == 0: return (false, @[], "the organisation has no secret " & n)
    let u = unseal(d.dek, v[0][1].getStr, valueAad(tenant, n, v[0][0].getInt))
    if not u.ok: return (false, @[], "the secret " & n & " cannot be read")
    result.values.add (n, u.plain)
  result.ok = true

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
