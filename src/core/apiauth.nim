## IAM-003: the API tokens of the REST API. A request carries `Authorization: Bearer cnm_<id>_<secret>`. The secret is 32 random bytes
## (hex); only its SHA-256 is stored (a fast hash is right for a secret that is already 256 bits of randomness, which no dictionary can guess;
## a password hash such as Argon2id protects secrets a person chooses), shown once at creation, with a scope, an expiry, the time of last use,
## and revocation. The scope is `admin` (every route) or `org:<slug>` (the runs of one organisation, and nothing else).
##
## The first administrator token is made the way TeamCity makes its super user token: at its first start (the table has no administrator yet)
## the core makes one, keeps its hash, and writes the token to its log once. That token works for one thing only, to be changed
## (`POST /api/v1/token:rotate` answers with a new token and revokes the old one); every other route answers 403 `token_change_required`
## until then. Nothing is generated at render time, so helmfile and `helm template` see no random value. A lost token is made again from
## inside the Pod: `kubectl exec deploy/cinim-core -- /core admin-token-reset`. An operator who wants a token of their own sets
## `CINIM_ADMIN_TOKEN` (the chart value `auth.adminToken` or a Secret): it is compared, not stored, needs no change, and cannot be rotated by the API.
## With neither `CINIM_AUTH=on` nor `CINIM_ADMIN_TOKEN` the API is open, as before this module (development, tests); the core says so at start.
##
## Pure parts (the header, the token, the scope rules) are tested in tests/unit/tapiauth.nim; the rows are the glue.
import std/[json, strutils, times, sysrand]
import crunchy
import ../common/[rqlite, ctrlauth]
import rbac
import ../common/sodiumpw
export rbac

const
  tokenPrefix* = "cnm_"
  initialName* = "initial administrator"      ## the name of the first token: its row tells that the first start has been done
  touchEvery = 60            ## seconds between two writes of `last_used_at` of one token: reads must not turn into a write each

type
  Principal* = object
    ok*: bool                ## the token is known, not expired, not revoked
    admin*: bool
    org*: string             ## the slug of an `org:<slug>` token
    name*, id*: string
    operator*: bool          ## the token of `CINIM_ADMIN_TOKEN`, which is not a row
    user*: string            ## the user a `user:<name>` token stands for (IAM-001)
    roles*: seq[string]      ## that user's roles at the shard level, read when the request came
    shardWide*: bool         ## a role of the shard that is not `admin`: the rights of `rw` or `ro` hold in every organisation
    mustChange*: bool        ## the first token: good for rotating itself, nothing else
    why*: string             ## when not ok: `missing`, `malformed`, `unknown`, `expired`, `revoked`

func toHex(a: openArray[byte]): string =
  const digits = "0123456789abcdef"
  for b in a:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

proc secretHash*(secret: string): string =
  ## what is stored: the SHA-256 of the secret, hex
  toHex(sha256(secret))

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
  ## `admin`, `user:<name>` (the rights of that user), or `org:<slug>` with a slug of the rules of SHD-001 (lowercase letters, digits and hyphens, starting with a letter)
  if scope == "admin": return true
  if scope.startsWith(userScopePrefix): return userOfScope(scope).len > 0
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

func acrossOrgs*(p: Principal): bool = p.ok and (p.admin or p.shardWide)
  ## the rights hold in every organisation: an administrator's, and the shard-level roles (which every organisation inherits)

func mayUseOrg*(p: Principal; org: string): bool =
  ## whether this principal may touch the runs of this organisation: an administrator or a shard-level role any, an organisation's token its own
  p.acrossOrgs or (p.ok and p.org.len > 0 and p.org == org)

# ------------------------------------------------------------------ the rows

proc createApiToken*(c: var RqClient; name, scope: string; expiresAt, now: int64; mustChange = false): tuple[id, token: string] =
  let t = mintToken()
  discard c.execute(%*[["INSERT INTO api_tokens (id, name, secret_hash, scope, created_at, expires_at, must_change) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        t.id, name, secretHash(t.secret), scope, now, expiresAt, (if mustChange: 1 else: 0)]])
  (t.id, t.token)

proc bootstrapAdminToken*(c: var RqClient; now: int64; force = false): string =
  ## The first start (no administrator token was ever made): makes one that has to be changed, and returns it for the log. "" when it was done before.
  ## `force` is the reset from inside the Pod, for a token that was lost: every other administrator token stays as it is.
  if not force:
    let r = c.query(%*[["SELECT count(*) FROM api_tokens WHERE name = ?", initialName]])
    if r["results"][0]{"values"}[0][0].getInt > 0: return ""
  if force:
    # a first token that nobody has changed is revoked by the new one: there is one of them at a time (the other tokens stay)
    discard c.execute(%*[["UPDATE api_tokens SET revoked_at = ? WHERE must_change = 1 AND revoked_at = 0", now]])
  c.createApiToken(initialName, "admin", 0, now, mustChange = true).token

proc rotateApiToken*(c: var RqClient; id: string; now: int64): tuple[ok: bool, id, token: string] =
  ## The caller's own token is replaced by a new one of the same scope and expiry, the old one is revoked in the same transaction, and the new one
  ## needs no change. The first token is called `administrator` from then on.
  let r = c.query(%*[["SELECT name, scope, expires_at FROM api_tokens WHERE id = ? AND revoked_at = 0", id]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0: return
  let t = mintToken()
  let name = if vals[0][0].getStr == initialName: "administrator" else: vals[0][0].getStr
  discard c.execute(%*[
    ["INSERT INTO api_tokens (id, name, secret_hash, scope, created_at, expires_at, must_change) VALUES (?, ?, ?, ?, ?, ?, 0)",
     t.id, name, secretHash(t.secret), vals[0][1].getStr, now, vals[0][2].getBiggestInt],
    ["UPDATE api_tokens SET revoked_at = ? WHERE id = ? AND revoked_at = 0", now, id]], transaction = true)
  (true, t.id, t.token)

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

# ------------------------------------------------------------------ users and roles (IAM-001)

const
  sessionSeconds* = 8 * 3600        ## how long a token from POST /api/v1/login is good
  roleDescriptions = [(roleAdmin, "every route"), (roleRw, "reads, and starts and changes runs, in every organisation"),
                      (roleRo, "reads runs and the plain facts of the shard")]

proc mintPassword*(): string = randomHex(32)
  ## the password the core makes for a user: 256 random bits (a person changes it for one of their own; either is stored as an Argon2id string, common/sodiumpw.nim)

proc userRoles*(c: var RqClient; name: string): tuple[found, disabled: bool, roles: seq[string]] =
  ## the user, and the roles it has at the shard level (the ones every organisation inherits)
  let r = c.query(%*[["SELECT disabled FROM users WHERE name = ?", name], ["SELECT role FROM role_bindings WHERE user_name = ? AND scope = ? ORDER BY role", name, shardScope]])
  let u = r["results"][0]{"values"}
  if u == nil or u.len == 0: return
  result.found = true
  result.disabled = u[0][0].getInt > 0
  let rs = r["results"][1]{"values"}
  if rs != nil:
    for v in rs: result.roles.add v[0].getStr

proc ensureRoles*(c: var RqClient) =
  var stmts = newJArray()
  for (role, text) in roleDescriptions: stmts.add %*["INSERT OR IGNORE INTO roles (name, description) VALUES (?, ?)", role, text]
  discard c.execute(stmts, transaction = true)

proc newUserToken(c: var RqClient; user: string; now: int64): string =
  c.createApiToken("user " & user, userScope(user), 0, now).token

proc bootstrapShardUsers*(c: var RqClient; now: int64): seq[UserCredential] =
  ## The first start (no user exists): a user for each role of the shard - `admin`, `rw`, `ro` - with a password and a token made here, returned for the log
  ## once. Nothing is made if there is a user already. Changing the password at the first login is not required (not built).
  c.ensureRoles()
  let have = c.query(%*[["SELECT count(*) FROM users"]])["results"][0]{"values"}[0][0].getInt
  if have > 0: return
  var stmts = newJArray()
  var made: seq[UserCredential]
  for role in shardRoles:
    let pw = mintPassword()
    stmts.add %*["INSERT OR IGNORE INTO users (name, password_hash, created_at) VALUES (?, ?, ?)", role, passwordHash(pw), now]
    stmts.add %*["INSERT OR IGNORE INTO role_bindings (user_name, role, scope) VALUES (?, ?, ?)", role, role, shardScope]
    made.add UserCredential(user: role, role: role, password: pw)
  discard c.execute(stmts, transaction = true)
  for m in made.mitems:
    m.token = c.newUserToken(m.user, now)
  made

proc resetUserCredentials*(c: var RqClient; user: string; now: int64): tuple[ok: bool, cred: UserCredential] =
  ## A new password and a new token for a user (a lost one, a leaked one): every token of that user, also the ones from a login, is revoked.
  let u = c.userRoles(user)
  if not u.found: return
  let pw = mintPassword()
  discard c.execute(%*[
    ["UPDATE users SET password_hash = ? WHERE name = ?", passwordHash(pw), user],
    ["UPDATE api_tokens SET revoked_at = ? WHERE scope = ? AND revoked_at = 0", now, userScope(user)]], transaction = true)
  let role = if u.roles.len > 0: u.roles[0] else: ""
  (true, UserCredential(user: user, role: role, password: pw, token: c.newUserToken(user, now)))

proc listUsers*(c: var RqClient): JsonNode =
  ## the users with their roles; never a password or a hash
  result = newJArray()
  let r = c.query(%*[["SELECT name, created_at, disabled FROM users ORDER BY name"]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for v in vals:
      let u = c.userRoles(v[0].getStr)
      result.add %*{"name": v[0].getStr, "roles": u.roles, "scope": shardScope, "created_at": v[1].getBiggestInt, "disabled": v[2].getInt > 0}

proc passwordIs*(c: var RqClient; user, password: string): bool =
  ## whether this is the user's password. For a user who does not exist the same work is done (a hash is made), so that the time does not tell.
  let r = c.query(%*[["SELECT password_hash FROM users WHERE name = ?", user]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0:
    discard passwordHash(password)
    return false
  passwordMatches(vals[0][0].getStr, password)

proc changePassword*(c: var RqClient; user, password: string; now: int64; keepToken = ""): tuple[ok: bool, sessionsRevoked: int] =
  ## The user's password is replaced (the caller has checked the rights and the length). The tokens that logins made are revoked, except `keepToken`, the one the
  ## change was asked with; the tokens made for the user (`user <name>`) stay.
  if not c.userRoles(user).found: return
  let r = c.execute(%*[
    ["UPDATE users SET password_hash = ? WHERE name = ?", passwordHash(password), user],
    ["UPDATE api_tokens SET revoked_at = ? WHERE scope = ? AND name = ? AND id != ? AND revoked_at = 0", now, userScope(user), "login " & user, keepToken]],
    transaction = true)
  (true, r["results"][1]{"rows_affected"}.getInt)

proc login*(c: var RqClient; user, password: string; now: int64): tuple[ok: bool, token: string, expiresAt: int64, roles: seq[string]] =
  ## A token for a user who proves the password: good for `sessionSeconds`, with the rights of the user's roles. An unknown user, a wrong password and a
  ## switched-off user are the same answer, and the same work is done for each.
  let same = c.passwordIs(user, password)
  let u = c.userRoles(user)
  if not (same and u.found and not u.disabled and u.roles.len > 0): return
  let t = c.createApiToken("login " & user, userScope(user), now + sessionSeconds, now)
  (true, t.token, now + sessionSeconds, u.roles)

proc authenticate*(c: var RqClient; adminToken, bearer: string; now: int64): Principal =
  ## the principal of a request. The administrator token of the chart is compared in constant time on its hash; every other token is looked up
  ## by its id and its secret compared the same way.
  if bearer.len == 0: return Principal(why: "missing")
  if adminToken.len > 0 and constantTimeEqual(secretHash(bearer), secretHash(adminToken)):
    return Principal(ok: true, admin: true, operator: true, name: "shard administrator", id: "admin")
  let t = splitToken(bearer)
  if not t.ok: return Principal(why: "malformed")
  let r = c.query(%*[["SELECT secret_hash, scope, name, expires_at, revoked_at, last_used_at, must_change FROM api_tokens WHERE id = ?", t.id]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0: return Principal(why: "unknown")
  let row = vals[0]
  if not constantTimeEqual(secretHash(t.secret), row[0].getStr): return Principal(why: "unknown")
  if row[4].getBiggestInt > 0: return Principal(why: "revoked")
  if row[3].getBiggestInt > 0 and now >= row[3].getBiggestInt: return Principal(why: "expired")
  let userName = userOfScope(row[1].getStr)
  if userName.len > 0:
    # a token of a user: the rights are the user's roles now, so that taking a role away or switching the user off works at once
    let u = c.userRoles(userName)
    if not u.found or u.disabled or u.roles.len == 0: return Principal(why: "revoked")
    result = Principal(ok: true, user: userName, roles: u.roles, admin: roleAdmin in u.roles, shardWide: roleAdmin notin u.roles)
  else:
    result = principalOf(row[1].getStr)
  result.name = row[2].getStr
  result.id = t.id
  result.mustChange = row[6].getInt > 0
  if result.ok and now - row[5].getBiggestInt >= touchEvery:
    try: discard c.execute(%*[["UPDATE api_tokens SET last_used_at = ? WHERE id = ?", now, t.id]])
    except CatchableError: discard         # the use is still allowed; the time of use is bookkeeping
