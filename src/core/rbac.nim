## IAM-001, RBAC (D-50, D-84): the four built-in roles - `admin`, `rw`, `dev`, `ro` - are sets of permissions made in code (permissions.nim), and an administrator makes roles of their own.
## A role is given to a user at the **shard** (it holds in every organisation) or in one **organisation** (`role_bindings.scope`, `org:<slug>`). What the four have:
##
##   admin  every permission
##   rw     everything but who may do what (the users, the roles, the API tokens, the access of an organisation), the object stores, the audit, the choice of an organisation's
##          store and the variables of the shard (as GitLab's Maintainer and GitHub's Maintain: runs, triggers, secrets, settings, organisations)
##   dev    reads what `ro` reads, starts runs and checks a script, stops a run, starts the failed ones again, fires a manual trigger; nothing is deleted or changed
##   ro     reads runs (state, steps, logs, artifacts), the components, the launch gate, the profile settings, the alerts, the organisations, their triggers, groups, variables, locks
##
## Which permission a route needs is `needOf` in permissions.nim: a route that is not named there is closed to every role but `admin`, so a route added later stays closed until it is
## named. `roleMay` here answers for a built-in role given at the shard; it is the old specification of the four roles (tests/unit/trbac.nim), kept to prove that the permissions
## say the same. The gate asks `mayCall` of apiauth.nim, which knows the organisations too. Pure; tested in tests/unit/trbac.nim and tests/unit/tpermissions.nim.
import std/[strutils, unicode, json]
import permissions
export permissions

const
  roleAdmin* = "admin"
  roleRw* = "rw"
  roleRo* = "ro"
  roleDev* = "dev"
  shardRoles* = [roleAdmin, roleRw, roleDev, roleRo]
  shardScope* = "shard"               ## a binding of this scope applies to every organisation of the shard
  userScopePrefix* = "user:"          ## the scope of an API token that stands for a user: its rights are the user's roles as they are when the request comes
  runsBase* = "/api/v1/runs"
  minPasswordLength* = 16             ## characters (not bytes)
  maxPasswordBytes* = 256

type UserCredential* = object
  ## what the core makes for a user and shows once
  user*, role*, password*, token*: string

func isString*(j: JsonNode; key: string): bool =
  ## whether `j` is an object that has `key` with a string in it. `j{key}` is **nil** when the key is missing, and `.kind` of nil is a crash that takes a thread of the
  ## server with it: a body like `{}` must be asked about this way.
  j != nil and j.kind == JObject and (let v = j{key}; v != nil and v.kind == JString)

func validRole*(role: string): bool = role in shardRoles

func validUserName*(name: string): bool =
  ## lowercase letters, digits, `-` and `_`, starting with a letter, at most 32
  if name.len < 1 or name.len > 32 or name[0] notin {'a' .. 'z'}: return false
  for ch in name:
    if ch notin {'a' .. 'z', '0' .. '9', '-', '_'}: return false
  true

func validDirectoryId*(uid: string): bool =
  ## what a directory's login name may be here: lowercase letters, digits, `.`, `_`, `-`, at most 64 (a name with other characters is refused rather than changed: two people must not become one)
  if uid.len < 1 or uid.len > 64: return false
  for ch in uid:
    if ch notin {'a' .. 'z', '0' .. '9', '.', '_', '-'}: return false
  true

func validAccountName*(name: string): bool =
  ## the name of an account that exists: a local user (`validUserName`) or a person a directory vouches for, `<login>@<organisation slug>` (D-87). A local user is never made with an `@`,
  ## so the two cannot meet.
  if validUserName(name): return true
  let at = name.find('@')
  if at < 1 or at == name.high: return false
  let slug = name[at + 1 .. ^1]
  if not validDirectoryId(name[0 ..< at]) or slug.len > 40 or slug[0] notin {'a' .. 'z'}: return false
  for ch in slug:
    if ch notin {'a' .. 'z', '0' .. '9', '-'}: return false
  true

func userOfPasswordPath*(path: string): string =
  ## the user named in `/api/v1/users/<name>/password`, "" for any other path
  const head = "/api/v1/users/"
  const tail = "/password"
  if path.startsWith(head) and path.endsWith(tail) and path.len > head.len + tail.len:
    let name = path[head.len ..< path.len - tail.len]
    if validAccountName(name): return name

func roleMay*(role, meth, path: string): bool =
  ## whether a built-in role, given at the shard, allows this call: the permission the route needs (permissions.nim) is one the role has. An administrator may call anything,
  ## also a route that is not named; every other role, only the named ones.
  if role == roleAdmin: return true
  let n = needOf(meth, path)
  n.permission.len > 0 and n.permission in builtinPermissions(role)

func rolesMay*(roles: openArray[string]; meth, path: string): bool =
  for r in roles:
    if roleMay(r, meth, path): return true

func passwordProblem*(password: string): string =
  ## why a password a person chose is refused, "" when it is good: at least 16 characters, and not absurdly long (it is hashed with a cost that grows with its size)
  if password.runeLen < minPasswordLength: return "the password must be at least " & $minPasswordLength & " characters long"
  if password.len > maxPasswordBytes: return "the password must be at most " & $maxPasswordBytes & " bytes long"

func passwordPath*(user: string): string = "/api/v1/users/" & user & "/password"

func selfService*(user, meth, path: string): bool =
  ## what any user may do besides what the role allows: change their own password
  user.len > 0 and meth == "PUT" and path == passwordPath(user)

func userScope*(name: string): string = userScopePrefix & name

func userOfScope*(scope: string): string =
  ## the user of a `user:<name>` scope; "" for any other
  if scope.startsWith(userScopePrefix) and validAccountName(scope[userScopePrefix.len .. ^1]): scope[userScopePrefix.len .. ^1] else: ""

func credentialLine*(c: UserCredential): string =
  ## the line the core writes to its log, made to be parsed: it starts with the fixed word `cinim-credentials` at the beginning of the line, then `key=value`
  ## pairs separated by one space, in the order user, role, password, token; a value holds no space (names are restricted, the secrets are hex)
  "cinim-credentials user=" & c.user & " role=" & c.role & " password=" & c.password & " token=" & c.token

func parseCredentialLine*(line: string): tuple[ok: bool, cred: UserCredential] =
  ## the reverse, for the tests and for a script that reads the log (`grep '^cinim-credentials'`)
  let parts = line.strip.split(' ')
  if parts.len != 5 or parts[0] != "cinim-credentials": return
  var got: array[4, string]
  for i, key in ["user", "role", "password", "token"]:
    let p = parts[i + 1]
    if not p.startsWith(key & "="): return
    got[i] = p[key.len + 1 .. ^1]
  (true, UserCredential(user: got[0], role: got[1], password: got[2], token: got[3]))
