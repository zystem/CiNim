## IAM-001, basic RBAC (D-50): four roles of the shard - `admin`, `rw`, `dev`, `ro` - given to users. A role is given at the **shard** level and is inherited by
## every organisation of the shard: the scope of a binding is `shard` (an organisation-level binding, `org:<slug>`, is the next step and is not built).
##
##   admin  every route (what the `admin` scope of an API token is)
##   rw     reads what `ro` reads, and starts and changes runs (POST, PUT, PATCH, DELETE under /api/v1/runs) in every organisation
##   dev    reads what `ro` reads, and starts runs (POST /api/v1/runs, and a manual trigger of an organisation: POST .../triggers/{id}:fire), nothing else
##   ro     reads runs (state, steps, logs, artifacts), the components, the launch gate, the profile settings, the alerts, the organisations and their triggers
##
## Everything not named here is the administrator's: users, tokens, the object store, secrets, organisations (create, switch off, controller credentials),
## the settings. The rule is an allow-list, so a route added later is closed to `rw` and `ro` until it is named. Pure; tested in tests/unit/trbac.nim.
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
func isWrite(meth: string): bool = meth in ["POST", "PUT", "PATCH", "DELETE"]

func underRuns(path: string): bool = path.startsWith(runsBase)

func readablePath(path: string): bool =
  ## what a reader may GET
  if underRuns(path): return true
  if path in ["/api/v1/components", "/api/v1/launch-gate", "/api/v1/profile", "/api/v1/alerts", "/api/v1/router", "/api/v1/organizations",
              "/api/v1/organizations:check"]: return true
  path.startsWith("/api/v1/organizations/") and path.endsWith("/triggers")

func startsRun(meth, path: string): bool =
  ## what a developer may do besides reading: start a run, directly or by firing a manual trigger of an organisation
  if meth != "POST": return false
  if path == runsBase: return true
  path.startsWith("/api/v1/organizations/") and "/triggers/" in path and path.endsWith(":fire")

func roleMay*(role, meth, path: string): bool =
  case role
  of roleAdmin: true
  of roleDev: (isRead(meth) and readablePath(path)) or startsRun(meth, path)
  of roleRw: (isRead(meth) and readablePath(path)) or (isWrite(meth) and underRuns(path))
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
