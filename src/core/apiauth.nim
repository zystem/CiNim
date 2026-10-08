## IAM-003: the API tokens of the REST API. A request carries `Authorization: Bearer cnm_<id>_<secret>`. The secret is 32 random bytes
## (hex); only its SHA-256 is stored (a fast hash is right for a secret that is already 256 bits of randomness, which no dictionary can guess;
## a password hash such as Argon2id protects secrets a person chooses), shown once at creation, with a scope, an expiry, the time of last use,
## and revocation. The scope is `admin` (every route) or `org:<slug>` (the runs of one organisation, and nothing else).
##
## The shard's own administrator token is not in the database: it comes from a Secret of the chart (`CINIM_ADMIN_TOKEN`), so that a shard
## that has just been installed can make the first token. Without `CINIM_ADMIN_TOKEN` the API is open, as it was before this module
## (development, tests); the core says so at start.
##
## Pure parts (the header, the token, the scope rules) are tested in tests/unit/tapiauth.nim; the rows are the glue.
import std/[json, strutils, times, sysrand]
import crunchy
import ../common/[rqlite, ctrlauth]

const
  tokenPrefix* = "cnm_"
  touchEvery = 60            ## seconds between two writes of `last_used_at` of one token: reads must not turn into a write each

type
  Principal* = object
    ok*: bool                ## the token is known, not expired, not revoked
    admin*: bool
    org*: string             ## the slug of an `org:<slug>` token
    name*, id*: string
    why*: string             ## when not ok: `missing`, `malformed`, `unknown`, `expired`, `revoked`

func toHex(a: openArray[byte]): string =
  const digits = "0123456789abcdef"
  for b in a:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

proc secretHash*(secret: string): string =
  ## what is stored: the SHA-256 of the secret, hex
  toHex(sha256(secret))

proc derivedAdminToken*(master: string): string =
  ## The administrator's token when nobody has given one: HMAC-SHA256 of a fixed text under the core's own secret key (the CURVE `core` key, which is in a
  ## Secret that the operator already holds). It is the same at every install and upgrade of the same keys, so that a chart rendered with
  ## `helm template` (helmfile, Argo CD) does not make a new one each time; it changes with the keys. `core admin-token` prints it.
  "cnm_admin_" & toHex(hmacSha256(master, "cinim/api/admin/v1"))

proc randomHex(n: int): string =
  var buf = newSeq[byte](n)
  if not urandom(buf): raise newException(OSError, "no source of randomness")
  toHex(buf)

proc mintToken*(): tuple[id, secret, token: string] =
  ## a new token: 6 random bytes of id (it is the row's key and is not secret) and 32 of secret
  let id = randomHex(6)
  let secret = randomHex(32)
  (id, secret, tokenPrefix & id & "_" & secret)

func splitToken*(token: string): tuple[ok: bool, id, secret: string] =
  if not token.startsWith(tokenPrefix): return
  let rest = token[tokenPrefix.len .. ^1]
  let us = rest.find('_')
  if us != 12 or rest.len != 12 + 1 + 64: return
  for ch in rest[0 ..< 12] & rest[13 .. ^1]:
    if ch notin HexDigits: return
  (true, rest[0 ..< 12], rest[13 .. ^1])

func bearerOf*(rawRequest: string): string =
  ## the bearer token of a raw HTTP request, "" when there is none; only the header part is looked at, the name is case-insensitive
  let headEnd = rawRequest.find("\r\n\r\n")
  let head = if headEnd >= 0: rawRequest[0 ..< headEnd] else: rawRequest
  for line in head.split("\r\n"):
    let colon = line.find(':')
    if colon <= 0 or line[0 ..< colon].strip.toLowerAscii != "authorization": continue
    let v = line[colon + 1 .. ^1].strip
    if v.len > 7 and v[0 ..< 7].toLowerAscii == "bearer ": return v[7 .. ^1].strip
  ""

func validScope*(scope: string): bool =
  ## `admin`, or `org:<slug>` with a slug of the rules of SHD-001 (lowercase letters, digits and hyphens, starting with a letter)
  if scope == "admin": return true
  if not scope.startsWith("org:"): return false
  let slug = scope[4 .. ^1]
  if slug.len < 1 or slug.len > 40 or slug[0] notin {'a' .. 'z'}: return false
  for ch in slug:
    if ch notin {'a' .. 'z', '0' .. '9', '-'}: return false
  slug[^1] != '-'

func principalOf*(scope: string): Principal =
  if scope == "admin": Principal(ok: true, admin: true)
  elif scope.startsWith("org:"): Principal(ok: true, org: scope[4 .. ^1])
  else: Principal(why: "unknown")

func mayUseOrg*(p: Principal; org: string): bool =
  ## whether this principal may touch the runs of this organisation: an administrator any, an organisation's token its own
  p.ok and (p.admin or (p.org.len > 0 and p.org == org))

# ------------------------------------------------------------------ the rows

proc createApiToken*(c: var RqClient; name, scope: string; expiresAt, now: int64): tuple[id, token: string] =
  let t = mintToken()
  discard c.execute(%*[["INSERT INTO api_tokens (id, name, secret_hash, scope, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
                        t.id, name, secretHash(t.secret), scope, now, expiresAt]])
  (t.id, t.token)

proc listApiTokens*(c: var RqClient): JsonNode =
  ## never the secret, nor its hash
  result = newJArray()
  let r = c.query(%*[["SELECT id, name, scope, created_at, expires_at, last_used_at, revoked_at FROM api_tokens ORDER BY created_at"]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for v in vals:
      result.add %*{"id": v[0].getStr, "name": v[1].getStr, "scope": v[2].getStr, "created_at": v[3].getBiggestInt,
                    "expires_at": v[4].getBiggestInt, "last_used_at": v[5].getBiggestInt, "revoked_at": v[6].getBiggestInt}

proc revokeApiToken*(c: var RqClient; id: string; now: int64): bool =
  let r = c.execute(%*[["UPDATE api_tokens SET revoked_at = ? WHERE id = ? AND revoked_at = 0", now, id]])
  r["results"][0]{"rows_affected"}.getInt > 0

proc authenticate*(c: var RqClient; adminToken, bearer: string; now: int64): Principal =
  ## the principal of a request. The administrator token of the chart is compared in constant time on its hash; every other token is looked up
  ## by its id and its secret compared the same way.
  if bearer.len == 0: return Principal(why: "missing")
  if adminToken.len > 0 and constantTimeEqual(secretHash(bearer), secretHash(adminToken)):
    return Principal(ok: true, admin: true, name: "shard administrator", id: "admin")
  let t = splitToken(bearer)
  if not t.ok: return Principal(why: "malformed")
  let r = c.query(%*[["SELECT secret_hash, scope, name, expires_at, revoked_at, last_used_at FROM api_tokens WHERE id = ?", t.id]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0: return Principal(why: "unknown")
  let row = vals[0]
  if not constantTimeEqual(secretHash(t.secret), row[0].getStr): return Principal(why: "unknown")
  if row[4].getBiggestInt > 0: return Principal(why: "revoked")
  if row[3].getBiggestInt > 0 and now >= row[3].getBiggestInt: return Principal(why: "expired")
  result = principalOf(row[1].getStr)
  result.name = row[2].getStr
  result.id = t.id
  if result.ok and now - row[5].getBiggestInt >= touchEvery:
    try: discard c.execute(%*[["UPDATE api_tokens SET last_used_at = ? WHERE id = ?", now, t.id]])
    except CatchableError: discard         # the use is still allowed; the time of use is bookkeeping
