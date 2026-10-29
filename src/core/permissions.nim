## IAM-001, D-84: the rights of the API as a list of **permissions**, one for each kind of operation (`run.start`, `run.abort`, `trigger.fire`, ...). A role is a set of permissions;
## the four roles of D-50 (`admin`, `rw`, `dev`, `ro`) are sets made here, in code, and an administrator makes roles of their own (`roles`, `role_permissions`). A role is given to a
## user at the **shard** (it holds in every organisation) or at one **organisation** (`role_bindings.scope`, `org:<slug>`; it holds there). Pure; tested in tests/unit/trbac.nim and
## tests/unit/tpermissions.nim.
##
## `needOf(method, path)` says what a request needs: a permission, and where it has to be held - at the shard (the shard's own things), in the organisation the path names, or in
## the organisation that the handler finds (a run's, the one in the body): the gate lets a request in when the permission is held anywhere, the handler asks again for the organisation.
## A route that is not in the table needs no permission that any role has: only an administrator may call it, so a route added later is closed until it is named here.
import std/[strutils, sets, tables]

type
  Level* = enum
    lvOrg          ## may be given in an organisation (and at the shard, where it holds in every organisation)
    lvShard        ## the shard's own: held only through a binding at the shard
  Perm = tuple[name: string, level: Level, text: string]

const
  catalogue*: seq[Perm] = @[
    ("run.read", lvOrg, "see runs and their steps"),
    ("run.start", lvOrg, "start a run"),
    ("run.check", lvOrg, "check a script before a run (POST /pipelines:check)"),
    ("run.abort", lvOrg, "stop a run"),
    ("run.retry", lvOrg, "run the failed steps of a run again"),
    ("run.delete", lvOrg, "delete a run"),
    ("log.read", lvOrg, "read the logs of a run and of its steps"),
    ("artifact.read", lvOrg, "list and download the artifacts of a run"),
    ("trigger.read", lvOrg, "see the triggers of an organisation"),
    ("trigger.write", lvOrg, "make, delete, switch and re-key triggers"),
    ("trigger.fire", lvOrg, "fire a manual trigger"),
    ("variable.read", lvOrg, "read variables"),
    ("variable.write", lvOrg, "write and delete variables of an organisation or of a group"),
    ("secret.read", lvOrg, "see the names of the secrets of an organisation"),
    ("secret.write", lvOrg, "set and delete secrets"),
    ("group.read", lvOrg, "see groups and projects"),
    ("group.write", lvOrg, "make and delete groups and projects"),
    ("hold.read", lvOrg, "see legal holds"),
    ("hold.write", lvOrg, "place and release legal holds"),
    ("cache.read", lvOrg, "see the caches of an organisation"),
    ("cache.delete", lvOrg, "delete caches"),
    ("lock.read", lvOrg, "see the locks of an organisation"),
    ("lock.write", lvOrg, "change the locks of an organisation"),
    ("storage.read", lvOrg, "see which store an organisation uses"),
    ("org.read", lvOrg, "see organisations"),
    ("access.read", lvOrg, "see who has which role in an organisation, and the roles and permissions"),
    ("access.write", lvOrg, "give and take away roles in an organisation"),
    ("shard.read", lvShard, "see the components, the launch gate, the alerts, the router, the profile and the checks of the shard"),
    ("shard.write", lvShard, "change the profile, the launch gate and the reconciliation of the shard"),
    ("shard.variable.write", lvShard, "write the variables of the shard"),
    ("org.create", lvShard, "make an organisation"),
    ("org.delete", lvShard, "switch an organisation off and delete it"),
    ("storage.write", lvShard, "choose the store of an organisation"),
    ("store.manage", lvShard, "see and check the object stores of the shard"),
    ("user.manage", lvShard, "make, delete and reset users"),
    ("role.manage", lvShard, "make and delete roles"),
    ("token.manage", lvShard, "make, list and revoke API tokens"),
    ("audit.read", lvShard, "read the audit log")]

  roAdds = ["run.read", "log.read", "artifact.read", "trigger.read", "lock.read", "variable.read", "group.read", "hold.read", "cache.read", "storage.read", "org.read", "shard.read"]
  devAdds = ["run.start", "run.check", "run.abort", "run.retry", "trigger.fire"]
  rwNot = ["user.manage", "role.manage", "token.manage", "store.manage", "audit.read", "storage.write", "shard.variable.write", "access.read", "access.write"]
  builtinRoles* = ["admin", "rw", "dev", "ro"]

func isPermission*(name: string): bool =
  for p in catalogue:
    if p.name == name: return true

func levelOf*(name: string): Level =
  for p in catalogue:
    if p.name == name: return p.level
  lvShard

func builtinPermissions*(role: string): seq[string] =
  ## what a role of the shard has in it; "" for a word that is not one
  case role
  of "admin":
    for p in catalogue: result.add p.name
  of "rw":
    for p in catalogue:
      if p.name notin rwNot: result.add p.name
  of "dev": result = @roAdds & @devAdds
  of "ro": result = @roAdds
  else: discard

func isBuiltin*(role: string): bool = role in builtinRoles

func validRoleName*(name: string): bool =
  ## the name of a role an administrator makes: lowercase letters, digits, `-` and `_`, starting with a letter, at most 32, and not one of the four
  if name.len < 1 or name.len > 32 or name[0] notin {'a' .. 'z'} or isBuiltin(name): return false
  for ch in name:
    if ch notin {'a' .. 'z', '0' .. '9', '-', '_'}: return false
  true

type
  NeedScope* = enum
    nsShard      ## held through a binding at the shard
    nsOrg        ## held at the shard or in the organisation `org` that the path names
    nsAny        ## held anywhere; the handler finds the organisation and asks `holds` for it
  Need* = object
    permission*: string     ## "" for a route that is not in the table
    scope*: NeedScope
    org*: string

func need(permission: string; scope: NeedScope; org = ""): Need = Need(permission: permission, scope: scope, org: org)

func isRead(meth: string): bool = meth in ["GET", "HEAD"]

func orgNeed(meth, org, rest: string): Need =
  ## `rest` is what follows `/api/v1/organizations/<slug>`: "" or a path that starts with a slash
  let write = not isRead(meth)
  func has(part: string): bool = rest == part or rest.startsWith(part & "/") or rest.startsWith(part & ":")
  if rest.len == 0: return (if meth == "DELETE": need("org.delete", nsShard) else: Need())
  if rest.endsWith("/storage"): return (if write: need("storage.write", nsShard) else: need("storage.read", nsOrg, org))
  # a hold is placed on the organisation or on a group, and read; `/holds` lists them
  if rest == "/hold" or rest == "/holds" or (rest.endsWith("/hold") and (rest.startsWith("/groups/") or rest.startsWith("/projects/"))):
    return need(if write: "hold.write" else: "hold.read", nsOrg, org)
  if rest.startsWith("/triggers"):
    let tail = rest["/triggers".len .. ^1]
    let colon = tail.rfind(':')
    if colon >= 0 and not write: return Need()
    if colon >= 0:
      let action = tail[colon + 1 .. ^1]
      return (if action == "fire": need("trigger.fire", nsOrg, org) elif action in ["enable", "disable", "rotate-secret"]: need("trigger.write", nsOrg, org) else: Need())
    return need(if write: "trigger.write" else: "trigger.read", nsOrg, org)
  if has("/locks"): return need(if write: "lock.write" else: "lock.read", nsOrg, org)
  if has("/variables") or ((rest.startsWith("/groups/") or rest.startsWith("/projects/")) and "/variables" in rest):
    return need(if write: "variable.write" else: "variable.read", nsOrg, org)
  if has("/groups") or has("/projects"): return need(if write: "group.write" else: "group.read", nsOrg, org)
  if has("/caches"): return need(if write: "cache.delete" else: "cache.read", nsOrg, org)
  if has("/secrets"): return need(if write: "secret.write" else: "secret.read", nsOrg, org)
  if has("/members"): return need(if write: "access.write" else: "access.read", nsOrg, org)
  Need()

func needOf*(meth, path: string): Need =
  ## What the request needs. `path` is the path without the query. A route that is not named gives the empty permission.
  const api = "/api/v1/"
  if not path.startsWith(api): return Need()
  let rest = path[api.len .. ^1]
  let write = not isRead(meth)
  if rest == "users" or rest.startsWith("users/") or rest.startsWith("users:"): return need("user.manage", nsShard)
  if rest == "roles" or rest.startsWith("roles/"): return (if write: need("role.manage", nsShard) else: need("access.read", nsAny))
  if rest == "permissions": return (if write: Need() else: need("access.read", nsAny))
  if rest == "tokens" or rest.startsWith("tokens/") or rest.startsWith("tokens:"): return need("token.manage", nsShard)
  if rest == "audit" or rest.startsWith("audit/"): return need("audit.read", nsShard)
  if rest == "stores" or rest.startsWith("stores/") or rest.startsWith("stores:"): return need("store.manage", nsShard)
  if rest in ["components", "alerts", "router", "organizations:check"]: return (if write: Need() else: need("shard.read", nsShard))
  if rest == "launch-gate": return need(if write: "shard.write" else: "shard.read", nsShard)
  if rest == "profile": return need(if write: "shard.write" else: "shard.read", nsShard)
  if rest == "organizations:reconcile": return need("shard.write", nsShard)
  if rest == "variables" or rest.startsWith("variables/"): return need(if write: "shard.variable.write" else: "variable.read", nsShard)
  if rest == "organizations": return (if write: need("org.create", nsShard) else: need("org.read", nsAny))
  if rest.startsWith("organizations/"):
    let after = rest["organizations/".len .. ^1]
    let slash = after.find('/')
    let slug = if slash < 0: after else: after[0 ..< slash]
    if slug.len == 0: return Need()
    return orgNeed(meth, slug, if slash < 0: "" else: after[slash .. ^1])
  if rest == "pipelines:check": return (if meth == "POST": need("run.check", nsAny) else: Need())
  if rest == "runs": return (if meth == "POST": need("run.start", nsAny) elif isRead(meth): need("run.read", nsAny) else: Need())
  if rest.startsWith("runs/"):
    let tail = rest["runs/".len .. ^1]
    if tail.endsWith(":abort"): return need("run.abort", nsAny)
    if tail.endsWith(":retry"): return need("run.retry", nsAny)
    if tail.endsWith(":hold") or tail.endsWith(":release"): return need("hold.write", nsAny)
    if meth == "DELETE": return need("run.delete", nsAny)
    if not isRead(meth): return Need()
    if tail.endsWith("/log"): return need("log.read", nsAny)
    if "/artifacts" in tail: return need("artifact.read", nsAny)
    return need("run.read", nsAny)
  Need()

type
  Grants* = object
    ## what a user holds: the permissions of the roles at the shard, and of the roles in each organisation
    shard*: HashSet[string]
    orgs*: Table[string, HashSet[string]]

proc addRole*(g: var Grants; scope: string; perms: openArray[string]) =
  ## `scope` is "shard" or "org:<slug>". A permission of the shard's own does nothing in an organisation, whatever role it came in.
  if scope == "shard":
    for p in perms: g.shard.incl p
  elif scope.startsWith("org:") and scope.len > 4:
    let slug = scope[4 .. ^1]
    if slug notin g.orgs: g.orgs[slug] = initHashSet[string]()
    for p in perms:
      if levelOf(p) == lvOrg: g.orgs[slug].incl p

func holds*(g: Grants; perm: string; org = ""): bool =
  ## whether `perm` is held for `org` ("" asks about the shard itself: only a binding at the shard counts). A binding at the shard holds in every organisation.
  if perm in g.shard: return true
  org.len > 0 and levelOf(perm) == lvOrg and org in g.orgs and perm in g.orgs[org]

func holdsAnywhere*(g: Grants; perm: string): bool =
  if perm in g.shard: return true
  if levelOf(perm) != lvOrg: return false
  for _, perms in g.orgs:
    if perm in perms: return true

func orgsWith*(g: Grants; perm: string): seq[string] =
  ## the organisations (by slug) in which `perm` is held through a binding of the organisation; the ones a binding at the shard covers are not listed
  if levelOf(perm) != lvOrg: return
  for slug, perms in g.orgs:
    if perm in perms: result.add slug

func allows*(g: Grants; n: Need): bool =
  ## the gate: whether a request with this need may go on (a route that is not named is refused here, whatever is held)
  if n.permission.len == 0: return false
  case n.scope
  of nsShard: n.permission in g.shard
  of nsOrg: g.holds(n.permission, n.org)
  of nsAny: g.holdsAnywhere(n.permission)

func grantsOfRoles*(roles: openArray[string]): Grants =
  ## what the built-in roles give at the shard (the pure tests and the first start use this; the API reads custom roles from the database)
  for r in roles: result.addRole("shard", builtinPermissions(r))
