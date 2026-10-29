## IAM-003: the API tokens of the REST API. A request carries `Authorization: Bearer cnm_<id>_<secret>`. The secret is 32 random bytes
## (hex); only its SHA-256 is stored (a fast hash is right for a secret that is already 256 bits of randomness, which no dictionary can guess;
## a password hash such as Argon2id protects secrets a person chooses), shown once at creation, with a scope, an expiry, the time of last use,
## and revocation. The scope is `admin` (every route) or `org:<slug>` (the runs of one organisation, and nothing else).
##
## The first credentials are the user `admin`'s (IAM-001, D-50), made at the first start with the API authentication on: a password and a token that the core writes to its log once,
## and the password has to be changed before anything else is allowed. Nothing is generated at render time, so helmfile and `helm template` see no random value. An operator who
## wants a token of their own sets `CINIM_ADMIN_TOKEN` (the chart value `auth.adminToken` or a Secret): it is compared, not stored, and cannot be rotated by the API.
## With neither `CINIM_AUTH=on` nor `CINIM_ADMIN_TOKEN` the API is open, as before this module (development, tests); the core says so at start.
##
## Pure parts (the header, the token, the scope rules) are tested in tests/unit/tapiauth.nim; the rows are the glue.
import std/[json, strutils, times, sysrand, sets, tables]
import crunchy
import ../common/[rqlite, ctrlauth]
import rbac
import ../common/sodiumpw
export rbac

const
  tokenPrefix* = "cnm_"
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
    grants*: Grants          ## what the user's roles give, at the shard and in each organisation (D-84)
    need*: Need              ## what the request being served needs, set by the gate: `mayUseOrg` asks it for the organisation the handler finds
    mustChange*: bool        ## the user's password has to be changed first: the only thing allowed is the change of it
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
  ## whether this principal may touch the runs of this organisation: an administrator any; a user, the organisations where the permission the request needs is held (at the shard
  ## it holds in every one); an organisation's token its own
  if not p.ok: return false
  if p.admin: return true
  if p.user.len > 0:
    if p.need.permission.len > 0: return p.grants.holds(p.need.permission, org)
    return p.shardWide or org in p.grants.orgs
  p.org.len > 0 and p.org == org

func mayUseIn*(p: Principal; org, group: string): bool =
  ## like `mayUseOrg`, for a thing at a group or project of the organisation (a run's `project`, a trigger's): a binding on that group or above it counts too
  if p.ok and not p.admin and p.user.len > 0 and p.need.permission.len > 0: return p.grants.holds(p.need.permission, org, group)
  p.mayUseOrg(org)

func mayIn*(p: Principal; perm, org: string; group = ""): bool =
  ## whether the principal holds `perm` for `org` ("" is the shard itself) and, with `group`, for that group or project; an organisation's token holds every permission of its own runs
  if not p.ok: return false
  if p.admin: return true
  if p.user.len > 0: return p.grants.holds(perm, org, group)
  p.org.len > 0 and p.org == org and perm.startsWith("run.")

func visibleGroups*(p: Principal; perm: string): seq[tuple[org, path: string]] =
  ## the groups and projects on which a binding gives `perm` (the ones a binding of the organisation or of the shard covers are in `visibleOrgs`)
  if p.ok and not p.admin and p.user.len > 0: return p.grants.groupsWith(perm)

func visibleOrgs*(p: Principal; perm: string): tuple[all: bool, slugs: seq[string]] =
  ## where `perm` is held: every organisation (a binding at the shard, an administrator), or these
  if not p.ok: return
  if p.admin or (p.user.len > 0 and perm in p.grants.shard): return (true, @[])
  if p.user.len > 0: return (false, p.grants.orgsWith(perm))
  if p.org.len > 0: return (false, @[p.org])

func mayCall*(p: Principal; meth, path: string): bool =
  ## The one answer to "may this caller make this call": the gate of the API asks it, and so does the page of a run that says which actions to offer (`actions`).
  ## An administrator any; a user, what the roles allow (rbac.nim) and the change of their own password; a token of an organisation, the routes under `runsBase`
  ## (which of the organisation's runs is checked where the run is known: `mayUseOrg`).
  if not p.ok: return false
  if p.admin: return true
  if p.user.len > 0: return p.grants.allows(needOf(meth, path)) or selfService(p.user, meth, path)
  p.org.len > 0 and path.startsWith(runsBase)

# ------------------------------------------------------------------ the rows

proc createApiToken*(c: var RqClient; name, scope: string; expiresAt, now: int64): tuple[id, token: string] =
  let t = mintToken()
  discard c.execute(%*[["INSERT INTO api_tokens (id, name, secret_hash, scope, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
                        t.id, name, secretHash(t.secret), scope, now, expiresAt]])
  (t.id, t.token)

proc rotateApiToken*(c: var RqClient; id: string; now: int64): tuple[ok: bool, id, token: string] =
  ## The caller's own token is replaced by a new one of the same scope and expiry, the old one is revoked in the same transaction.
  let r = c.query(%*[["SELECT name, scope, expires_at FROM api_tokens WHERE id = ? AND revoked_at = 0", id]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0: return
  let t = mintToken()
  let name = vals[0][0].getStr
  discard c.execute(%*[
    ["INSERT INTO api_tokens (id, name, secret_hash, scope, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
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
  roleDescriptions = [(roleAdmin, "every route"), (roleRw, "almost an administrator: everything but the users, the roles, the API tokens and the object store"),
                      (roleDev, "reads, starts and stops runs (also by a manual trigger), in every organisation"),
                      (roleRo, "reads runs and the plain facts of the shard")]

proc mintPassword*(): string = randomHex(32)
  ## the password the core makes for a user: 256 random bits (a person changes it for one of their own; either is stored as an Argon2id string, common/sodiumpw.nim)

proc rolePermissions*(c: var RqClient; role: string): seq[string] =
  ## the permissions in a role: a built-in one is made in code (permissions.nim), one an administrator made is in `role_permissions`
  if isBuiltin(role): return builtinPermissions(role)
  let r = c.query(%*[["SELECT permission FROM role_permissions WHERE role = ? ORDER BY permission", role]])["results"][0]{"values"}
  if r != nil:
    for v in r: result.add v[0].getStr

proc userRoles*(c: var RqClient; name: string): tuple[found, disabled, mustChange: bool, roles: seq[string], bindings: seq[tuple[role, scope: string]], grants: Grants] =
  ## the user; the roles it has at the shard level (the ones every organisation inherits); every binding, at the shard and in an organisation; and what they give (D-84)
  let r = c.query(%*[["SELECT disabled, must_change FROM users WHERE name = ?", name], ["SELECT role, scope FROM role_bindings WHERE user_name = ? ORDER BY scope, role", name]])
  let u = r["results"][0]{"values"}
  if u == nil or u.len == 0: return
  result.found = true
  result.disabled = u[0][0].getInt > 0
  result.mustChange = u[0][1].getInt > 0
  let rs = r["results"][1]{"values"}
  var known = initTable[string, seq[string]]()
  if rs != nil:
    for v in rs:
      let role = v[0].getStr
      let scope = v[1].getStr
      result.bindings.add (role, scope)
      if scope == shardScope: result.roles.add role
      if role notin known: known[role] = c.rolePermissions(role)
      result.grants.addRole(scope, known[role])

func isOrgScope*(scope: string): bool = scope.startsWith("org:") and scope.len > 4

proc ensureRoles*(c: var RqClient) =
  var stmts = newJArray()
  for (role, text) in roleDescriptions: stmts.add %*["INSERT OR IGNORE INTO roles (name, description) VALUES (?, ?)", role, text]
  discard c.execute(stmts, transaction = true)

proc newUserToken(c: var RqClient; user: string; now: int64): string =
  c.createApiToken("user " & user, userScope(user), 0, now).token

proc bootstrapAdminUser*(c: var RqClient; now: int64): seq[UserCredential] =
  ## The first start (no user exists): the user `admin`, with a password and a token made here and returned for the log once, and the duty to change the password before
  ## anything else is done (the other users are made by an administrator). The roles of the shard are made too. Nothing is made if there is a user already.
  c.ensureRoles()
  let have = c.query(%*[["SELECT count(*) FROM users"]])["results"][0]{"values"}[0][0].getInt
  if have > 0: return
  let pw = mintPassword()
  discard c.execute(%*[
    ["INSERT OR IGNORE INTO users (name, password_hash, created_at, must_change) VALUES (?, ?, ?, 1)", roleAdmin, passwordHash(pw), now],
    ["INSERT OR IGNORE INTO role_bindings (user_name, role, scope) VALUES (?, ?, ?)", roleAdmin, roleAdmin, shardScope]], transaction = true)
  @[UserCredential(user: roleAdmin, role: roleAdmin, password: pw, token: c.newUserToken(roleAdmin, now))]

proc createUser*(c: var RqClient; name, role, password: string; now: int64; scope = shardScope): bool =
  ## An administrator makes a user with one role, at the shard or (`scope` = `org:<slug>`) in one organisation, and a password (checked by the caller). False if the name is taken.
  if c.userRoles(name).found: return false
  discard c.execute(%*[
    ["INSERT INTO users (name, password_hash, created_at) VALUES (?, ?, ?)", name, passwordHash(password), now],
    ["INSERT INTO role_bindings (user_name, role, scope) VALUES (?, ?, ?)", name, role, scope]], transaction = true)
  true

proc deleteUser*(c: var RqClient; name: string; now: int64): bool =
  ## The user, the bindings and every token of the user are gone. False if there is no such user.
  if not c.userRoles(name).found: return false
  discard c.execute(%*[
    ["UPDATE api_tokens SET revoked_at = ? WHERE scope = ? AND revoked_at = 0", now, userScope(name)],
    ["DELETE FROM role_bindings WHERE user_name = ?", name],
    ["DELETE FROM users WHERE name = ?", name]], transaction = true)
  true

proc listRoles*(c: var RqClient): JsonNode =
  ## every role with the permissions in it; `builtin` roles are made in code and cannot be changed
  result = newJArray()
  let r = c.query(%*[["SELECT name, description FROM roles ORDER BY name"]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for v in vals:
      let name = v[0].getStr
      result.add %*{"name": name, "description": v[1].getStr, "scope": shardScope, "builtin": isBuiltin(name), "permissions": c.rolePermissions(name)}

proc roleExists*(c: var RqClient; name: string): bool =
  if isBuiltin(name): return true
  let v = c.query(%*[["SELECT 1 FROM roles WHERE name = ?", name]])["results"][0]{"values"}
  v != nil and v.len > 0                          # rqlite leaves `values` out when there is no row

proc putRole*(c: var RqClient; name, description: string; permissions: seq[string]): string =
  ## Makes a role, or replaces the permissions of one an administrator made; "" when done, otherwise why not. The built-in four are not touched.
  if not validRoleName(name): return "a role name is lowercase letters, digits, - and _, starts with a letter, at most 32, and is not admin, rw, dev or ro"
  if permissions.len == 0: return "a role has at least one permission"
  for p in permissions:
    if not isPermission(p): return "no such permission: " & p
  var stmts = newJArray()
  stmts.add %*["INSERT INTO roles (name, description) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET description = excluded.description", name, description]
  stmts.add %*["DELETE FROM role_permissions WHERE role = ?", name]
  for p in permissions: stmts.add %*["INSERT OR IGNORE INTO role_permissions (role, permission) VALUES (?, ?)", name, p]
  discard c.execute(stmts, transaction = true)

type RoleDelete* = enum rdDeleted, rdNotFound, rdBuiltin, rdInUse

proc deleteRole*(c: var RqClient; name: string): RoleDelete =
  if isBuiltin(name): return rdBuiltin
  if not c.roleExists(name): return rdNotFound
  let bound = c.query(%*[["SELECT 1 FROM role_bindings WHERE role = ? LIMIT 1", name]])["results"][0]{"values"}
  if bound != nil and bound.len > 0: return rdInUse
  discard c.execute(%*[["DELETE FROM role_permissions WHERE role = ?", name], ["DELETE FROM roles WHERE name = ?", name]], transaction = true)
  rdDeleted

proc listMembers*(c: var RqClient; scope: string): JsonNode =
  ## who has a role at this scope (`org:<slug>` or `org:<slug>/<group path>`; a binding exactly there; the ones at the shard are in GET /users)
  result = newJArray()
  let vals = c.query(%*[["SELECT user_name, role FROM role_bindings WHERE scope = ? ORDER BY user_name, role", scope]])["results"][0]{"values"}
  var cur = ""
  if vals != nil:
    for v in vals:
      if v[0].getStr != cur:
        cur = v[0].getStr
        result.add %*{"user": cur, "roles": []}
      result[result.len - 1]["roles"].add %v[1].getStr

proc setMember*(c: var RqClient; scope, user: string; roles: seq[string]): string =
  ## The roles of an existing user at this scope are these (replacing the ones it had there); an empty list takes them all away. "" when done, otherwise why not.
  if not c.userRoles(user).found: return "no such user: " & user
  for r in roles:
    if not c.roleExists(r): return "no such role: " & r
  var stmts = newJArray()
  stmts.add %*["DELETE FROM role_bindings WHERE user_name = ? AND scope = ? AND source = ''", user, scope]          # the roles that come from a directory are the directory's to give and take away (D-87)
  for r in roles: stmts.add %*["INSERT OR IGNORE INTO role_bindings (user_name, role, scope) VALUES (?, ?, ?)", user, r, scope]
  discard c.execute(stmts, transaction = true)

proc resetUserCredentials*(c: var RqClient; user: string; now: int64): tuple[ok: bool, cred: UserCredential] =
  ## A new password and a new token for a user (a lost one, a leaked one): every token of that user, also the ones from a login, is revoked, and the password has to be changed at once.
  let u = c.userRoles(user)
  if not u.found: return
  let pw = mintPassword()
  discard c.execute(%*[
    ["UPDATE users SET password_hash = ?, must_change = 1 WHERE name = ?", passwordHash(pw), user],
    ["UPDATE api_tokens SET revoked_at = ? WHERE scope = ? AND revoked_at = 0", now, userScope(user)]], transaction = true)
  let role = if u.roles.len > 0: u.roles[0] else: ""
  (true, UserCredential(user: user, role: role, password: pw, token: c.newUserToken(user, now)))

proc listUsers*(c: var RqClient): JsonNode =
  ## the users with their roles; never a password or a hash
  result = newJArray()
  let r = c.query(%*[["SELECT name, created_at, disabled, must_change, source FROM users ORDER BY name"]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for v in vals:
      let u = c.userRoles(v[0].getStr)
      var inOrgs = newJObject()
      for b in u.bindings:
        if isOrgScope(b.scope):
          if not inOrgs.hasKey(b.scope[4 .. ^1]): inOrgs[b.scope[4 .. ^1]] = newJArray()
          inOrgs[b.scope[4 .. ^1]].add %b.role
      result.add %*{"name": v[0].getStr, "roles": u.roles, "organizations": inOrgs, "source": v[4].getStr, "scope": shardScope, "created_at": v[1].getBiggestInt, "disabled": v[2].getInt > 0, "password_change_required": v[3].getInt > 0}

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
    ["UPDATE users SET password_hash = ?, must_change = 0 WHERE name = ?", passwordHash(password), user],
    ["UPDATE api_tokens SET revoked_at = ? WHERE scope = ? AND name = ? AND id != ? AND revoked_at = 0", now, userScope(user), "login " & user, keepToken]],
    transaction = true)
  (true, r["results"][1]{"rows_affected"}.getInt)

proc sessionFor*(c: var RqClient; user: string; now: int64): tuple[ok: bool, token: string, expiresAt: int64, roles: seq[string], mustChange: bool] =
  ## a token for a user whose identity has been proved (by a password, or by a directory): good for `sessionSeconds`, with the rights of the user's roles
  let u = c.userRoles(user)
  if not (u.found and not u.disabled and u.bindings.len > 0): return
  let t = c.createApiToken("login " & user, userScope(user), now + sessionSeconds, now)
  (true, t.token, now + sessionSeconds, u.roles, u.mustChange)

proc login*(c: var RqClient; user, password: string; now: int64): tuple[ok: bool, token: string, expiresAt: int64, roles: seq[string], mustChange: bool] =
  ## A token for a user who proves the password: good for `sessionSeconds`, with the rights of the user's roles. An unknown user, a wrong password and a
  ## switched-off user are the same answer, and the same work is done for each.
  let same = c.passwordIs(user, password)
  if not same: return
  c.sessionFor(user, now)

proc userSourceOf*(c: var RqClient; name: string): string =
  ## "" for a local user (and for one that does not exist); `ldap:<server id>` for a person a directory vouches for
  let v = c.query(%*[["SELECT source FROM users WHERE name = ?", name]])["results"][0]{"values"}
  if v != nil and v.len > 0: v[0][0].getStr else: ""

proc authenticate*(c: var RqClient; adminToken, bearer: string; now: int64): Principal =
  ## the principal of a request. The administrator token of the chart is compared in constant time on its hash; every other token is looked up
  ## by its id and its secret compared the same way.
  if bearer.len == 0: return Principal(why: "missing")
  if adminToken.len > 0 and constantTimeEqual(secretHash(bearer), secretHash(adminToken)):
    return Principal(ok: true, admin: true, operator: true, name: "shard administrator", id: "admin")
  let t = splitToken(bearer)
  if not t.ok: return Principal(why: "malformed")
  let r = c.query(%*[["SELECT secret_hash, scope, name, expires_at, revoked_at, last_used_at FROM api_tokens WHERE id = ?", t.id]])
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
    if not u.found or u.disabled or u.bindings.len == 0: return Principal(why: "revoked")
    result = Principal(ok: true, user: userName, roles: u.roles, admin: roleAdmin in u.roles, shardWide: u.roles.len > 0 and roleAdmin notin u.roles, mustChange: u.mustChange,
                       grants: u.grants)
  else:
    result = principalOf(row[1].getStr)
  result.name = row[2].getStr
  result.id = t.id
  if result.ok and now - row[5].getBiggestInt >= touchEvery:
    try: discard c.execute(%*[["UPDATE api_tokens SET last_used_at = ? WHERE id = ?", now, t.id]])
    except CatchableError: discard         # the use is still allowed; the time of use is bookkeeping
