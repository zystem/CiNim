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
import std/[json, strutils, times, sysrand, sets, tables, algorithm]
import crunchy
import ../common/[rqlite, ctrlauth]
import rbac
import ../common/sodiumpw
export rbac

const
  maxBindingRefs* = 16        ## the refs a condition of one binding names
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
    grants*: Grants          ## what the user's roles give, at the shard and in each organisation (D-84)
    bindings*: seq[tuple[role, scope, source: string, cond: BindingCondition]]       ## the roles themselves, for GET /api/v1/me (with what each is tied to, D-92)
    need*: Need              ## what the request being served needs, set by the gate: `mayUseOrg` asks it for the organisation the handler finds
    limited*: bool           ## D-99: a token with a subset of the permissions of its user, or a token of one step: it is not an administrator whatever the user is, and it makes no token
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

func headerOfRaw*(rawRequest, name: string): string =
  ## the value of a header of a raw HTTP request ("" when there is none or `name` is empty); only the head is looked at, the name is case-insensitive
  if name.len == 0: return
  let headEnd = rawRequest.find("\r\n\r\n")
  let head = if headEnd >= 0: rawRequest[0 ..< headEnd] else: rawRequest
  for line in head.split("\r\n"):
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].strip.toLowerAscii == name.toLowerAscii: return line[colon + 1 .. ^1].strip

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


func mayUseOrg*(p: Principal; org: string): bool =
  ## whether this principal may touch the runs of this organisation: an administrator any; a user, the organisations where the permission the request needs is held (at the shard
  ## it holds in every one - only an administrator has anything at the shard, D-90); an organisation's token its own
  if not p.ok: return false
  if p.admin: return true
  if p.user.len > 0:
    if p.need.permission.len > 0: return p.grants.holds(p.need.permission, org)
    return org in p.grants.orgs
  p.org.len > 0 and p.org == org

func mayUseIn*(p: Principal; org, group: string): bool =
  ## like `mayUseOrg`, for a thing at a group or project of the organisation (a run's `project`, a trigger's): a binding on that group or above it counts too
  if p.ok and not p.admin and p.user.len > 0 and p.need.permission.len > 0: return p.grants.holds(p.need.permission, org, group)
  p.mayUseOrg(org)

func runFactsOf*(p: Principal; startedBy, ref0: string): RunFacts =
  ## a run is the caller's own when they started it: the actor recorded at its start is the caller (`actorOf` of the audit)
  RunFacts(own: startedBy.len > 0 and p.user.len > 0 and startedBy == "user:" & p.user, ref0: ref0)

func mayUseRun*(p: Principal; run: JsonNode): bool =
  ## `mayUseIn` for a run as `getRun` gives it (D-92): a binding that holds for the caller's own runs, or for some refs, counts when this run is such
  let org = run{"organization"}.getStr
  let group = run{"project"}.getStr
  if p.ok and not p.admin and p.user.len > 0 and p.need.permission.len > 0:
    let src = run{"source"}
    return p.grants.holdsRun(p.need.permission, org, group, p.runFactsOf(run{"started_by"}.getStr, (if src != nil and src.kind == JObject: src{"ref"}.getStr else: "")))
  p.mayUseOrg(org)

func mayInRun*(p: Principal; perm: string; run: JsonNode): bool =
  ## whether the caller holds `perm` for this run (the actions offered with it): D-92 as `mayUseRun`
  let org = run{"organization"}.getStr
  let group = run{"project"}.getStr
  if not p.ok: return false
  if p.admin: return true
  if p.user.len > 0:
    let src = run{"source"}
    return p.grants.holdsRun(perm, org, group, p.runFactsOf(run{"started_by"}.getStr, (if src != nil and src.kind == JObject: src{"ref"}.getStr else: "")))
  p.org.len > 0 and p.org == org and perm.startsWith("run.")

func mayStart*(p: Principal; perm, org, group, ref0: string): bool =
  ## whether the caller may start a run of this project on this ref ("" for none): the run will be theirs, so only the refs of a condition count (D-92)
  if not p.ok: return false
  if p.admin: return true
  if p.user.len > 0: return p.grants.holdsRun(perm, org, group, RunFacts(own: true, ref0: ref0))
  p.org.len > 0 and p.org == org and perm.startsWith("run.")

func mayStartSomewhere*(p: Principal; perm, org, group: string): bool =
  ## the first look at a start, before the ref is known: held outright, or through a binding tied to some refs (`mayStart` asks again with the ref)
  if not p.ok: return false
  if p.admin: return true
  if p.user.len > 0: return p.grants.holds(perm, org, group) or (isRunPermission(perm) and org.len > 0 and p.grants.holdsWithin(perm, org))
  p.org.len > 0 and p.org == org and perm.startsWith("run.")

func mayFireOn*(p: Principal; org, group, ref0: string): bool =
  ## a trigger started by hand makes a run: whoever holds `run.start` only through a binding tied to refs may fire it on those refs only (D-92); anyone else is as they were
  if not p.ok or p.admin or p.user.len == 0: return true
  if p.grants.holds("run.start", org, group) or not p.grants.holdsWithin("run.start", org): return true
  p.grants.holdsRun("run.start", org, group, RunFacts(own: true, ref0: ref0))

func mayIn*(p: Principal; perm, org: string; group = ""): bool =
  ## whether the principal holds `perm` for `org` ("" is the shard itself) and, with `group`, for that group or project; an organisation's token holds every permission of its own runs
  if not p.ok: return false
  if p.admin: return true
  if p.user.len > 0: return p.grants.holds(perm, org, group)
  p.org.len > 0 and p.org == org and perm.startsWith("run.")

func visibleGroups*(p: Principal; perm: string): seq[tuple[org, path: string]] =
  ## the groups and projects on which a binding gives `perm` (the ones a binding of the organisation or of the shard covers are in `visibleOrgs`)
  if p.ok and not p.admin and p.user.len > 0: return p.grants.groupsWith(perm)

func visibleLimited*(p: Principal; perm: string): seq[tuple[org, path: string, onlyOwn: bool, refs: seq[string]]] =
  ## the places where `perm` is held through a binding with a condition (D-92)
  if p.ok and not p.admin and p.user.len > 0: return p.grants.limitedWith(perm)

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
  if meth == "GET" and (path == "/api/v1/me" or path == "/api/v1/me/can"): return true          # whoever asks is told about themself
  if p.admin: return true
  if p.user.len > 0 and not p.limited and (path == "/api/v1/me/tokens" or path.startsWith("/api/v1/me/tokens/") or path == "/api/v1/me/mfa" or path.startsWith("/api/v1/me/mfa/")): return true          # D-99: a person\'s own tokens
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

type TokenRestrict* = object
  permissions*: seq[string]
  organization*, group*: string          ## the organisation (and the project or group in it) the token is for; "" for the places its user holds the permissions

proc parseRestrict*(text: string): TokenRestrict =
  if text.len == 0: return
  try:
    let j = parseJson(text)
    if j.kind != JObject: return
    if j.hasKey("permissions") and j["permissions"].kind == JArray:
      for x in j["permissions"]: (if x.kind == JString: result.permissions.add x.getStr)
    result.organization = j{"organization"}.getStr
    result.group = j{"group"}.getStr
  except JsonParsingError: discard

func restrictGrants*(g: Grants; r: TokenRestrict): Grants =
  ## D-99: what a token with a subset of its user\'s permissions holds: the permissions it names, and only where the user holds them (and only in the organisation, or the project, it is for). A role
  ## of the shard becomes the organisation\'s when the token is for one; a token for no organisation keeps the places the user has.
  let perms = r.permissions.toHashSet
  if r.organization.len == 0 and r.group.len == 0:
    for p in perms:
      if p in g.shard: result.shard.incl p
    for slug, set in g.orgs:
      var kept = initHashSet[string]()
      for p in set:
        if p in perms: kept.incl p
      if kept.len > 0: result.orgs[slug] = kept
    for slug, bs in g.groups:
      for b in bs:
        var kept = initHashSet[string]()
        for p in b.perms:
          if p in perms: kept.incl p
        if kept.len > 0: result.groups.mgetOrPut(slug, @[]).add (b.path, kept)
    for slug, bs in g.limited:
      for b in bs:
        var kept = initHashSet[string]()
        for p in b.perms:
          if p in perms: kept.incl p
        if kept.len > 0: result.limited.mgetOrPut(slug, @[]).add (b.path, kept, b.onlyOwn, b.refs)
    return
  let org = r.organization
  if r.group.len > 0:
    var kept = initHashSet[string]()
    for p in perms:
      if levelOf(p) == lvGroup and g.holds(p, org, r.group): kept.incl p
    if kept.len > 0: result.groups[org] = @[(r.group, kept)]
    for b in g.limited.getOrDefault(org):
      if b.path.len == 0 or covers(b.path, r.group):
        var lk = initHashSet[string]()
        for p in b.perms:
          if p in perms: lk.incl p
        if lk.len > 0: result.limited.mgetOrPut(org, @[]).add (r.group, lk, b.onlyOwn, b.refs)
    return
  var kept = initHashSet[string]()
  for p in perms:
    if levelOf(p) != lvShard and g.holds(p, org): kept.incl p
  if kept.len > 0: result.orgs[org] = kept
  for b in g.groups.getOrDefault(org):
    var gk = initHashSet[string]()
    for p in b.perms:
      if p in perms: gk.incl p
    if gk.len > 0: result.groups.mgetOrPut(org, @[]).add (b.path, gk)
  for b in g.limited.getOrDefault(org):
    var lk = initHashSet[string]()
    for p in b.perms:
      if p in perms: lk.incl p
    if lk.len > 0: result.limited.mgetOrPut(org, @[]).add (b.path, lk, b.onlyOwn, b.refs)

proc listOwnTokens*(c: var RqClient; user: string): JsonNode =
  result = newJArray()
  let vals = c.query(%*[["SELECT id, name, created_at, expires_at, last_used_at, revoked_at, restrict FROM api_tokens WHERE scope = ? ORDER BY created_at", userScope(user)]])["results"][0]{"values"}
  if vals != nil:
    for v in vals:
      var item = %*{"id": v[0].getStr, "name": v[1].getStr, "created_at": v[2].getBiggestInt, "expires_at": v[3].getBiggestInt, "last_used_at": v[4].getBiggestInt, "revoked_at": v[5].getBiggestInt}
      if v[6].getStr.len > 0: item["restrict"] = (try: parseJson(v[6].getStr) except JsonParsingError: newJNull())
      result.add item

proc revokeOwnToken*(c: var RqClient; user, id: string; now: int64): bool =
  c.execute(%*[["UPDATE api_tokens SET revoked_at = ? WHERE id = ? AND scope = ? AND revoked_at = 0", now, id, userScope(user)]])["results"][0]{"rows_affected"}.getInt > 0

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

proc legacyShardBindings*(c: var RqClient): seq[tuple[user, role: string]] =
  ## roles other than `admin` given at the shard before D-90: they are not rights any more, and this lists them so that they can be seen and the users moved into an organisation or deleted
  let v = c.query(%*[["SELECT user_name, role FROM role_bindings WHERE scope = ? AND role != ? ORDER BY user_name", shardScope, roleAdmin]])["results"][0]{"values"}
  if v != nil:
    for r in v: result.add (r[0].getStr, r[1].getStr)

func conditionOf*(expiresAt: int64; onlyOwn: bool; refs: string): BindingCondition =
  ## the condition of a row: the refs are kept one to a line
  result = BindingCondition(expiresAt: expiresAt, onlyOwn: onlyOwn)
  for l in refs.splitLines:
    let t = l.strip
    if t.len > 0: result.refs.add t

proc userRoles*(c: var RqClient; name: string; now = 0'i64): tuple[found, disabled, mustChange: bool, roles: seq[string], bindings: seq[tuple[role, scope, source: string, cond: BindingCondition]], grants: Grants, ignored: seq[string]] =
  ## the user; the roles it has at the shard level (the ones every organisation inherits); every binding, at the shard and in an organisation; and what they give (D-84).
  ## A binding whose term has passed (`expires_at`, D-92) is not read at all: it gives nothing and is not listed.
  let at = if now > 0: now else: getTime().toUnix()
  let r = c.query(%*[["SELECT disabled, must_change FROM users WHERE name = ?", name], ["SELECT role, scope, source, expires_at, only_own, refs FROM role_bindings WHERE user_name = ? AND (expires_at = 0 OR expires_at > ?) ORDER BY scope, role", name, at]])
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
      if scope == shardScope and not allowedAtShard(role):
        result.ignored.add role                       # D-90: the shard has no users but administrators; a role of another kind given there before is not a right any more
        continue
      let cond = conditionOf(v[3].getBiggestInt, v[4].getInt > 0, v[5].getStr)
      result.bindings.add (role, scope, v[2].getStr, cond)
      if scope == shardScope: result.roles.add role
      if role notin known: known[role] = c.rolePermissions(role)
      result.grants.addRole(scope, known[role], cond)
  # D-91: the roles of the teams the user is a member of, in the organisation of the team and below (a team\'s binding outside its organisation is no right)
  let tv = c.query(%*[["SELECT o.slug, t.name FROM team_members m JOIN teams t ON t.id = m.team_id JOIN organizations o ON o.id = t.tenant_id WHERE m.user_name = ?", name]])["results"][0]{"values"}
  if tv != nil:
    for t in tv:
      let slug = t[0].getStr
      let subject = "team:" & slug & "/" & t[1].getStr
      let tb = c.query(%*[["SELECT role, scope, expires_at, only_own, refs FROM role_bindings WHERE user_name = ? AND (expires_at = 0 OR expires_at > ?) ORDER BY scope, role", subject, at]])["results"][0]{"values"}
      if tb != nil:
        for b in tb:
          let scope = b[1].getStr
          if scope != "org:" & slug and not scope.startsWith("org:" & slug & "/"): continue
          let role = b[0].getStr
          let cond = conditionOf(b[2].getBiggestInt, b[3].getInt > 0, b[4].getStr)
          result.bindings.add (role, scope, subject, cond)
          if role notin known: known[role] = c.rolePermissions(role)
          result.grants.addRole(scope, known[role], cond)

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
    ["DELETE FROM team_members WHERE user_name = ?", name],
    ["DELETE FROM user_mfa WHERE user_name = ?", name],
    ["DELETE FROM step_secrets WHERE tenant_id = '~mfa' AND name = ?", name],
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

func conditionView*(cond: BindingCondition; now: int64): JsonNode =
  ## what a binding is tied to, for the API; `expired` is shown on a binding that is listed after its term (the lists of members show it, the rights do not read it)
  result = newJObject()
  if cond.expiresAt > 0:
    result["expires_at"] = %cond.expiresAt
    if now >= cond.expiresAt: result["expired"] = %true
  if cond.onlyOwn: result["only_own"] = %true
  if cond.refs.len > 0: result["refs"] = %cond.refs

proc bindingConditionOf*(j: JsonNode): tuple[cond: BindingCondition, error: string] =
  ## the condition in the body of a member call (D-92): `expires_at` (unix seconds, or a time as RFC 3339), `only_own` (true), `refs` (a list of names or prefixes with a `*`)
  if j.hasKey("expires_at") and j["expires_at"].kind != JNull:
    let e = j["expires_at"]
    if e.kind == JInt: result.cond.expiresAt = e.getBiggestInt
    elif e.kind == JString:
      try: result.cond.expiresAt = parse(e.getStr, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()).toTime.toUnix
      except CatchableError:
        result.error = "expires_at is unix seconds or a time like 2026-12-31T23:59:59Z"
        return
    else:
      result.error = "expires_at is unix seconds or a time like 2026-12-31T23:59:59Z"
      return
    if result.cond.expiresAt < 0:
      result.error = "expires_at is in the past"
      return
  if j.hasKey("only_own"):
    if j["only_own"].kind != JBool:
      result.error = "only_own is true or false"
      return
    result.cond.onlyOwn = j["only_own"].getBool
  if j.hasKey("refs") and j["refs"].kind != JNull:
    if j["refs"].kind != JArray:
      result.error = "refs is a list of branch or tag names, or names followed by *"
      return
    for r in j["refs"].elems:
      if r.kind != JString:
        result.error = "refs is a list of branch or tag names, or names followed by *"
        return
      result.cond.refs.add r.getStr

proc listMembers*(c: var RqClient; scope: string; now = 0'i64): JsonNode =
  ## who has a role at this scope (`org:<slug>` or `org:<slug>/<group path>`; a binding exactly there; the ones at the shard are in GET /users). `roles` are the names;
  ## `conditions` has an entry for each role that is tied to a term, to the user's own runs or to refs (D-92), and the binding of an ended term is still listed, marked `expired`.
  result = newJArray()
  let at = if now > 0: now else: getTime().toUnix()
  let vals = c.query(%*[["SELECT user_name, role, expires_at, only_own, refs FROM role_bindings WHERE scope = ? ORDER BY user_name, role", scope]])["results"][0]{"values"}
  var cur = ""
  if vals != nil:
    for v in vals:
      if v[0].getStr != cur:
        cur = v[0].getStr
        result.add %*{"user": cur, "roles": []}
      result[result.len - 1]["roles"].add %v[1].getStr
      let view = conditionView(conditionOf(v[2].getBiggestInt, v[3].getInt > 0, v[4].getStr), at)
      if view.len > 0:
        if not result[result.len - 1].hasKey("conditions"): result[result.len - 1]["conditions"] = newJObject()
        result[result.len - 1]["conditions"][v[1].getStr] = view

proc setMember*(c: var RqClient; scope, user: string; roles: seq[string]; conds = initTable[string, BindingCondition](); now = 0'i64): string =
  ## The roles of an existing user at this scope are these (replacing the ones it had there); an empty list takes them all away. `conds` ties a role to a term, to the user's own runs
  ## or to refs (D-92). "" when done, otherwise why not.
  if user.startsWith("team:"):
    # D-91: the roles of a team, in its own organisation and below
    let at = user.find('/')
    let slug = if at > 5: user[5 ..< at] else: ""
    if slug.len == 0 or not (scope == "org:" & slug or scope.startsWith("org:" & slug & "/")): return "a team has roles in its own organisation and below only"
    let found = c.query(%*[["SELECT 1 FROM teams t JOIN organizations o ON o.id = t.tenant_id WHERE o.slug = ? AND t.name = ?", slug, user[at + 1 .. ^1]]])["results"][0]{"values"}
    if found == nil or found.len == 0: return "no such team: " & user[at + 1 .. ^1]
  elif not c.userRoles(user).found: return "no such user: " & user
  let at = if now > 0: now else: getTime().toUnix()
  for r in roles:
    if not c.roleExists(r): return "no such role: " & r
    let cd = conds.getOrDefault(r)
    if cd.expiresAt < 0 or (cd.expiresAt > 0 and cd.expiresAt <= at): return "the term of " & r & " is in the past"
    if cd.refs.len > maxBindingRefs: return "at most " & $maxBindingRefs & " refs to a role"
    for pat in cd.refs:
      if not isRefPattern(pat): return "a ref is a branch or tag name, or a name followed by * (" & pat & ")"
    if cd.limits and scope == shardScope: return "a condition is for a role in an organisation"
  var stmts = newJArray()
  stmts.add %*["DELETE FROM role_bindings WHERE user_name = ? AND scope = ? AND source = ''", user, scope]          # the roles that come from a directory are the directory's to give and take away (D-87)
  for r in roles:
    let cd = conds.getOrDefault(r)
    stmts.add %*["INSERT OR IGNORE INTO role_bindings (user_name, role, scope, expires_at, only_own, refs) VALUES (?, ?, ?, ?, ?, ?)", user, r, scope, cd.expiresAt, (if cd.onlyOwn: 1 else: 0), cd.refs.join("\n")]
  discard c.execute(stmts, transaction = true)

proc resetUserCredentials*(c: var RqClient; user: string; now: int64): tuple[ok: bool, cred: UserCredential] =
  ## A new password and a new token for a user (a lost one, a leaked one): every token of that user, also the ones from a login, is revoked, and the password has to be changed at once.
  let u = c.userRoles(user)
  if not u.found: return
  let pw = mintPassword()
  discard c.execute(%*[
    ["UPDATE users SET password_hash = ?, must_change = 1 WHERE name = ?", passwordHash(pw), user],
    ["DELETE FROM user_mfa WHERE user_name = ?", user],          # D-101: a lost password is often a lost phone: the reset turns the second factor off, the person sets it up again
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
      result.add %*{"name": v[0].getStr, "roles": u.roles, "ignored_shard_roles": u.ignored, "organizations": inOrgs, "source": v[4].getStr, "scope": shardScope, "created_at": v[1].getBiggestInt, "disabled": v[2].getInt > 0, "password_change_required": v[3].getInt > 0}

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

# ------------------------------------------------------------------ who am I, and may I

func sortedList(set: HashSet[string]): JsonNode =
  var names: seq[string]
  for n in set: names.add n
  names.sort()
  result = newJArray()
  for n in names: result.add %n

proc whoAmI*(c: var RqClient; p: Principal; organizationSlugs: seq[string]): JsonNode =
  ## GET /api/v1/me: the caller as the core sees it. Who, which roles at which place, what they come to (the permissions at the shard, in each organisation, on each group), and which
  ## organisations the caller sees. `organizationSlugs` is every organisation of the shard, for a caller who may see all.
  let kind = if p.operator: "operator" elif p.user.len > 0: "user" elif p.org.len > 0: "organization token" elif p.name == "open API": "open api" else: "administrator token"
  result = %*{"kind": kind, "name": p.name, "user": p.user, "administrator": p.admin, "password_change_required": p.mustChange}
  if p.org.len > 0: result["organization"] = %p.org
  var bs = newJArray()
  for b in p.bindings:
    var item = %*{"role": b.role, "scope": b.scope, "source": b.source}
    let tied = conditionView(b.cond, 0)
    if tied.len > 0: item["condition"] = tied
    bs.add item
  result["bindings"] = bs
  var perms = newJObject()
  if p.admin:
    var all = newJArray()
    for pm in catalogue: all.add %pm.name
    perms["shard"] = all
    result["permissions"] = perms
  elif p.user.len > 0:
    perms["shard"] = sortedList(p.grants.shard)
    var orgs = newJObject()
    for slug, set in p.grants.orgs: orgs[slug] = sortedList(set)
    perms["organizations"] = orgs
    var groups = newJObject()
    for slug, list in p.grants.groups:
      var arr = newJArray()
      for b in list: arr.add %*{"path": b.path, "permissions": sortedList(b.perms)}
      groups[slug] = arr
    perms["groups"] = groups
    # D-92: the run permissions that hold for some runs only
    var tied = newJObject()
    for slug, list in p.grants.limited:
      var arr = newJArray()
      for b in list:
        var item = %*{"permissions": sortedList(b.perms)}
        if b.path.len > 0: item["path"] = %b.path
        if b.onlyOwn: item["only_own"] = %true
        if b.refs.len > 0: item["refs"] = %b.refs
        arr.add item
      tied[slug] = arr
    if tied.len > 0: perms["conditional"] = tied
    result["permissions"] = perms
  else:
    result["permissions"] = %*{"note": "an organisation\'s token may use the routes of its own runs"}
  # the organisations the caller sees: all, or these
  var seen = newJArray()
  if p.admin or (p.user.len > 0 and "org.read" in p.grants.shard):
    result["organizations"] = %*{"all": true, "slugs": organizationSlugs}
  else:
    var slugs: seq[string]
    if p.user.len > 0: slugs = p.grants.orgsTouched
    elif p.org.len > 0: slugs = @[p.org]
    slugs.sort()
    for s in slugs: seen.add %s
    result["organizations"] = %*{"all": false, "slugs": seen}

proc explainCall*(c: var RqClient; p: Principal; meth, path, org, group: string): JsonNode =
  ## GET /api/v1/me/can: may the caller make this call, which permission it needs and where, and which of their roles give it. `org` and `group` say which organisation and
  ## group the thing is in, for a route (a run\'s, a trigger\'s) whose organisation the path does not name.
  let n = needOf(meth, path)
  let where = case n.scope
    of nsShard: "at the shard"
    of nsOrg: (if n.group.len > 0: "in the organisation " & n.org & ", or on the group " & n.group & " or above it" else: "in the organisation " & n.org)
    of nsInOrg: "in the organisation " & n.org & " or on a group of it"
    of nsAny: "anywhere" & (if org.len > 0: ", here in " & org & (if group.len > 0: "/" & group else: "") else: "")
  result = %*{"method": meth, "path": path, "permission": n.permission, "needs": (if n.permission.len == 0: "" else: where), "allowed": false, "granted_by": []}
  if not p.ok:
    result["reason"] = %"not logged in"
    return
  if p.admin:
    result["allowed"] = %true
    result["reason"] = %"an administrator may make any call"
    return
  if meth == "GET" and (path == "/api/v1/me" or path == "/api/v1/me/can"):
    result["allowed"] = %true
    result["reason"] = %"everyone may ask about themself"
    return
  if p.user.len == 0:
    let ok = p.mayCall(meth, path)
    result["allowed"] = %ok
    result["reason"] = %(if ok: "a token of an organisation may use the routes of its own runs" else: "a token of an organisation may use the routes of its own runs only")
    return
  if selfService(p.user, meth, path):
    result["allowed"] = %true
    result["reason"] = %"every user may change their own password"
    return
  if p.limited:
    let ok = p.mayCall(meth, path)
    result["allowed"] = %ok
    result["reason"] = %(if ok: "this token holds the permission" else: "this token holds a subset of its user\'s permissions and does not hold " & n.permission)
    return
  if n.permission.len == 0:
    result["reason"] = %"this route is named for no role: only an administrator may call it"
    return
  # which bindings give it: each binding is tried alone
  var by = newJArray()
  for b in p.bindings:
    var g: Grants
    g.addRole(b.scope, c.rolePermissions(b.role), b.cond)
    let gives = if n.scope == nsAny and org.len > 0: g.holds(n.permission, org, group) or (isRunPermission(n.permission) and g.holdsWithin(n.permission, org))
                elif n.scope == nsAny: g.holdsAnywhere(n.permission)
                else: g.allows(n)
    if gives:
      var item = %*{"role": b.role, "scope": b.scope}
      if b.source.len > 0: item["source"] = %b.source               # given through a team, or by a directory
      if b.cond.limits and isRunPermission(n.permission): item["condition"] = conditionView(b.cond, 0)          # D-92: holds for some runs only; the call is allowed when the run is one of them
      by.add item
  result["granted_by"] = by
  let allowed = by.len > 0
  result["allowed"] = %allowed
  result["reason"] = %(if allowed: "held through the roles listed" elif n.scope == nsShard: "this needs a role at the shard, and a role in an organisation does not count" else: "no role of yours has " & n.permission & " " & where)

proc createRestrictedToken*(c: var RqClient; user, name: string; r: TokenRestrict; expiresAt, now: int64): tuple[id, token, error: string] =
  ## A token of `user` that holds only the permissions named (a subset of what the user holds now; a token can lose rights with its user, never gain any). "" error when made.
  if r.permissions.len == 0 or r.permissions.len > 40: return ("", "", "permissions is a list of 1 to 40 permissions")
  let u = c.userRoles(user, now)
  if not u.found: return ("", "", "no such user")
  for p in r.permissions:
    if not isPermission(p): return ("", "", "no such permission: " & p)
    if r.organization.len > 0 and levelOf(p) == lvShard: return ("", "", "a token for an organisation cannot hold " & p & ", which is the shard\'s own")
    let held = if r.organization.len > 0: u.grants.holds(p, r.organization, r.group) or (r.group.len == 0 and u.grants.holdsWithin(p, r.organization))
               else: u.grants.holdsAnywhere(p)
    if not held: return ("", "", "you do not hold " & p & (if r.organization.len > 0: " in " & r.organization else: ""))
  if name.len == 0 or name.len > 100: return ("", "", "a token has a name of 1 to 100 characters")
  let t = mintToken()
  var j = %*{"permissions": r.permissions}
  if r.organization.len > 0: j["organization"] = %r.organization
  if r.group.len > 0: j["group"] = %r.group
  discard c.execute(%*[["INSERT INTO api_tokens (id, name, secret_hash, scope, created_at, expires_at, restrict) VALUES (?, ?, ?, ?, ?, ?, ?)", t.id, name, secretHash(t.secret), userScope(user), now, expiresAt, $j]])
  (t.id, t.token, "")

const
  stepTokenReadPermissions* = ["run.read", "log.read", "artifact.read"]
  stepTokenPermissions* = ["run.read", "log.read", "artifact.read", "run.abort", "run.retry", "run.start", "trigger.fire", "group.read", "variable.read", "cache.read"]
  stepTokenSeconds* = 6 * 3600'i64
  apiTokenName* = "CINIM_API_TOKEN"

proc mintStepToken*(c: var RqClient; runId: string; step, attempt: int; perms: seq[string]; now: int64): tuple[token, error: string] =
  ## D-99: the token of a step that asked for one (`api = {...}`): for the project of the run, the permissions it named, while the run lasts. What it may name is limited: reading the run, its logs and
  ## artifacts for any run; the rest (stopping, starting, firing) only when the person who started the run holds it where the run is, so a step never has more than the person has.
  if perms.len == 0 or perms.len > 10: return ("", "api is a list of 1 to 10 permissions")
  let r = c.query(%*[["SELECT COALESCE(o.slug, ''), COALESCE(g.path, ''), COALESCE(r.actor_id, '') FROM runs r LEFT JOIN organizations o ON o.id = r.tenant_id LEFT JOIN groups g ON g.id = r.group_id WHERE r.id = ?", runId]])["results"][0]{"values"}
  if r == nil or r.len == 0: return ("", "no such run")
  let slug = r[0][0].getStr
  let path = r[0][1].getStr
  let actor = r[0][2].getStr
  if slug.len == 0: return ("", "a step token belongs to a run of an organisation")
  var held: Grants
  var person = false
  if actor.startsWith("user:"):
    let u = c.userRoles(actor[5 .. ^1], now)
    if u.found and not u.disabled:
      held = u.grants
      person = true
  for p in perms:
    if p notin stepTokenPermissions: return ("", p & " cannot be given to a step (it may be one of " & stepTokenPermissions.join(", ") & ")")
    if p in stepTokenReadPermissions: continue
    if not person: return ("", p & " needs a run started by a person: this run was started by " & (if actor.len > 0: actor else: "nobody"))
    if not held.holds(p, slug, path): return ("", "the person who started the run does not hold " & p & " for " & slug & (if path.len > 0: "/" & path else: ""))
  let name = "step " & runId & "/" & $step & "/" & $attempt
  let t = mintToken()
  discard c.execute(%*[["UPDATE api_tokens SET revoked_at = ? WHERE name = ? AND revoked_at = 0", now, name],
    ["INSERT INTO api_tokens (id, name, secret_hash, scope, created_at, expires_at, restrict) VALUES (?, ?, ?, ?, ?, ?, ?)", t.id, name, secretHash(t.secret), "run:" & runId, now, now + stepTokenSeconds, $(%*{"permissions": perms})]], transaction = true)
  (t.token, "")

proc authenticate*(c: var RqClient; adminToken, bearer: string; now: int64): Principal =
  ## the principal of a request. The administrator token of the chart is compared in constant time on its hash; every other token is looked up
  ## by its id and its secret compared the same way.
  if bearer.len == 0: return Principal(why: "missing")
  if adminToken.len > 0 and constantTimeEqual(secretHash(bearer), secretHash(adminToken)):
    return Principal(ok: true, admin: true, operator: true, name: "shard administrator", id: "admin")
  let t = splitToken(bearer)
  if not t.ok: return Principal(why: "malformed")
  let r = c.query(%*[["SELECT secret_hash, scope, name, expires_at, revoked_at, last_used_at, restrict FROM api_tokens WHERE id = ?", t.id]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0: return Principal(why: "unknown")
  let row = vals[0]
  if not constantTimeEqual(secretHash(t.secret), row[0].getStr): return Principal(why: "unknown")
  if row[4].getBiggestInt > 0: return Principal(why: "revoked")
  if row[3].getBiggestInt > 0 and now >= row[3].getBiggestInt: return Principal(why: "expired")
  let userName = userOfScope(row[1].getStr)
  if userName.len > 0:
    # a token of a user: the rights are the user's roles now, so that taking a role away or switching the user off works at once
    let u = c.userRoles(userName, now)
    if not u.found or u.disabled or u.bindings.len == 0: return Principal(why: "revoked")
    result = Principal(ok: true, user: userName, roles: u.roles, admin: roleAdmin in u.roles, mustChange: u.mustChange,
                       grants: u.grants, bindings: u.bindings)
    if row[6].getStr.len > 0:
      # D-99: a token with a subset: what the user holds now, cut to the permissions (and the place) the token was made for; never an administrator
      result.grants = restrictGrants(u.grants, parseRestrict(row[6].getStr))
      result.admin = false
      result.limited = true
  elif row[1].getStr.startsWith("run:"):
    # D-99: the token of one step: for the project of the run, the permissions it was made with, and only while the run has not ended
    let rid = row[1].getStr[4 .. ^1]
    let rs = c.query(%*[["SELECT r.state, COALESCE(o.slug, ''), COALESCE(g.path, '') FROM runs r LEFT JOIN organizations o ON o.id = r.tenant_id LEFT JOIN groups g ON g.id = r.group_id WHERE r.id = ?", rid]])["results"][0]{"values"}
    if rs == nil or rs.len == 0 or rs[0][0].getStr in ["OK", "FAILED", "ABORTED", "SKIPPED", "TIMED_OUT", "INFRASTRUCTURE_ERROR"]: return Principal(why: "revoked")
    let rr = parseRestrict(row[6].getStr)
    var g: Grants
    g.addRole("org:" & rs[0][1].getStr & (if rs[0][2].getStr.len > 0: "/" & rs[0][2].getStr else: ""), rr.permissions)
    result = Principal(ok: true, user: "~" & t.id, grants: g, limited: true)
  else:
    result = principalOf(row[1].getStr)
  result.name = row[2].getStr
  result.id = t.id
  if result.ok and now - row[5].getBiggestInt >= touchEvery:
    try: discard c.execute(%*[["UPDATE api_tokens SET last_used_at = ? WHERE id = ?", now, t.id]])
    except CatchableError: discard         # the use is still allowed; the time of use is bookkeeping
