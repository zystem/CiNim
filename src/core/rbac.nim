## IAM-001, basic RBAC (D-50): four roles of the shard - `admin`, `rw`, `dev`, `ro` - given to users. A role is given at the **shard** level and is inherited by
## every organisation of the shard: the scope of a binding is `shard` (an organisation-level binding, `org:<slug>`, is the next step and is not built).
##
##   admin  every route (what the `admin` scope of an API token is)
##   rw     almost an administrator: everything, reads and writes, deletes and edits (as GitLab's Maintainer and GitHub's Maintain: runs, triggers, secrets, settings,
##          organisations), except what is the shard's own: the management of who may do what - the users, the roles and the API tokens - and the object store
##          (its endpoint and keys are infrastructure, as GitLab keeps them in the instance's admin area); the own password every user changes
##   dev    what a developer does: reads what `ro` reads, starts runs (POST /api/v1/runs, and a manual trigger of an organisation: POST .../triggers/{id}:fire), stops them
##          (POST .../runs/{id}:cancel) and starts the failed ones again (POST .../runs/{id}:retry); nothing is deleted or changed
##   ro     reads runs (state, steps, logs, artifacts), the components, the launch gate, the profile settings, the alerts, the organisations and their triggers
##
## `dev` and `ro` are allow-lists, so a route added later is closed to them until it is named; `rw` is a deny-list (`adminOnlyPath`), so a route added later is open
## to it - a route that belongs to the shard's own things must be named in `adminOnlyPath`. Pure; tested in tests/unit/trbac.nim.
import std/[strutils, unicode, json]

const
  roleAdmin* = "admin"
  roleRw* = "rw"
  roleRo* = "ro"
  roleDev* = "dev"
  shardRoles* = [roleAdmin, roleRw, roleDev, roleRo]
  shardScope* = "shard"               ## a binding of this scope applies to every organisation of the shard
  userScopePrefix* = "user:"          ## the scope of an API token that stands for a user: its rights are the user's roles as they are when the request comes
  runsBase = "/api/v1/runs"
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

func userOfPasswordPath*(path: string): string =
  ## the user named in `/api/v1/users/<name>/password`, "" for any other path
  const head = "/api/v1/users/"
  const tail = "/password"
  if path.startsWith(head) and path.endsWith(tail) and path.len > head.len + tail.len:
    let name = path[head.len ..< path.len - tail.len]
    if validUserName(name): return name

func isRead(meth: string): bool = meth in ["GET", "HEAD"]

func underRuns(path: string): bool = path.startsWith(runsBase)

func readablePath(path: string): bool =
  ## what a reader may GET
  if underRuns(path): return true
  if path in ["/api/v1/components", "/api/v1/launch-gate", "/api/v1/profile", "/api/v1/alerts", "/api/v1/router", "/api/v1/organizations",
              "/api/v1/organizations:check"]: return true
  path.startsWith("/api/v1/organizations/") and path.endsWith("/triggers")

func adminOnlyPath(path: string): bool =
  ## what is the shard's own and only an administrator's: the management of who may do what (the users, the roles, the API tokens) and the object store of the shard
  for head in ["/api/v1/users", "/api/v1/roles", "/api/v1/tokens", "/api/v1/storage"]:
    if path == head or path.startsWith(head & "/") or path.startsWith(head & ":"): return true

func developerMay(meth, path: string): bool =
  ## what a developer may do besides reading: start a run, directly or by firing a manual trigger of an organisation, stop a run, start a failed one again
  if meth != "POST": return false
  if path == runsBase: return true
  if path.startsWith(runsBase & "/") and (path.endsWith(":cancel") or path.endsWith(":retry")): return true
  path.startsWith("/api/v1/organizations/") and "/triggers/" in path and path.endsWith(":fire")

func roleMay*(role, meth, path: string): bool =
  case role
  of roleAdmin: true
  of roleDev: (isRead(meth) and readablePath(path)) or developerMay(meth, path)
  of roleRw: not adminOnlyPath(path)
  of roleRo: isRead(meth) and readablePath(path)
  else: false

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
  if scope.startsWith(userScopePrefix) and validUserName(scope[userScopePrefix.len .. ^1]): scope[userScopePrefix.len .. ^1] else: ""

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
