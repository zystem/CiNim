## IAM-001, D-84: the rights of the API as a list of **permissions**, one for each kind of operation (`run.start`, `run.abort`, `trigger.fire`, ...). A role is a set of permissions;
## the four roles of D-50 (`admin`, `rw`, `dev`, `ro`) are sets made here, in code, and an administrator makes roles of their own (`roles`, `role_permissions`). A role is given to a
## user at the **shard** (it holds in every organisation), at one **organisation** (`role_bindings.scope`, `org:<slug>`; it holds there) or at a **group or project** of an organisation
## (`org:<slug>/<path>`; it holds for that node and everything under it, and only for the permissions that are about things in the tree of groups: runs, triggers, variables,
## groups, holds). Pure; tested in tests/unit/trbac.nim and tests/unit/tpermissions.nim.
##
## `needOf(method, path)` says what a request needs: a permission, and where it has to be held - at the shard (the shard's own things), in the organisation the path names, or in
## the organisation that the handler finds (a run's, the one in the body): the gate lets a request in when the permission is held anywhere, the handler asks again for the organisation.
## A route that is not in the table needs no permission that any role has: only an administrator may call it, so a route added later is closed until it is named here.
import std/[strutils, sets, tables]

type
  Level* = enum
    lvGroup        ## about a thing in the tree of groups: may be given on a group or a project (and in an organisation, and at the shard)
    lvOrg          ## may be given in an organisation (and at the shard, where it holds in every organisation)
    lvShard        ## the shard's own: held only through a binding at the shard
  Perm = tuple[name: string, level: Level, text: string]

const
  catalogue*: seq[Perm] = @[
    ("run.read", lvGroup, "see runs and their steps"),
    ("run.start", lvGroup, "start a run"),
    ("run.check", lvGroup, "check a script before a run (POST /pipelines:check)"),
    ("run.abort", lvGroup, "stop a run"),
    ("run.retry", lvGroup, "run the failed steps of a run again"),
    ("run.delete", lvGroup, "delete a run"),
    ("log.read", lvGroup, "read the logs of a run and of its steps"),
    ("artifact.read", lvGroup, "list and download the artifacts of a run"),
    ("trigger.read", lvGroup, "see the triggers of an organisation"),
    ("trigger.write", lvGroup, "make, delete, switch and re-key triggers"),
    ("trigger.fire", lvGroup, "fire a manual trigger"),
    ("variable.read", lvGroup, "read variables"),
    ("variable.write", lvGroup, "write and delete variables of an organisation or of a group"),
    ("secret.read", lvGroup, "see the names of the secrets of an organisation"),
    ("secret.write", lvGroup, "set and delete secrets"),
    ("group.read", lvGroup, "see groups and projects"),
    ("group.write", lvGroup, "make and delete groups and projects"),
    ("hold.read", lvGroup, "see legal holds"),
    ("hold.write", lvGroup, "place and release legal holds"),
    ("cache.read", lvOrg, "see the caches of an organisation"),
    ("cache.delete", lvOrg, "delete caches"),
    ("lock.read", lvOrg, "see the locks of an organisation"),
    ("lock.write", lvOrg, "change the locks of an organisation"),
    ("storage.read", lvOrg, "see which store an organisation uses"),
    ("org.read", lvGroup, "see organisations"),
    ("run.start.protected", lvGroup, "start a run on a protected ref of a project (the secrets marked protected go to such runs only)"),
    ("ref.protect", lvGroup, "choose which refs of a project are protected"),
    ("profile.grant", lvGroup, "choose which privileged profiles (build, deploy) the pipelines of a project may use"),
    ("access.read", lvGroup, "see who has which role in an organisation, and the roles and permissions"),
    ("access.write", lvGroup, "give and take away roles in an organisation"),
    ("ldap.read", lvOrg, "see the directories of an organisation and which of their groups give which role"),
    ("ldap.map", lvOrg, "choose which groups of a directory give which role in the organisation, and sync now"),
    ("ldap.write", lvShard, "add, change, check and remove the directories of an organisation (the core connects to the address given)"),
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

  roAdds = ["run.read", "log.read", "artifact.read", "trigger.read", "lock.read", "variable.read", "group.read", "hold.read", "cache.read", "storage.read", "org.read"]
  devAdds = ["run.start", "run.check", "run.abort", "run.retry", "trigger.fire"]
  rwNot = ["user.manage", "role.manage", "token.manage", "store.manage", "audit.read", "storage.write", "shard.variable.write", "access.read", "access.write", "ldap.read", "ldap.map", "ldap.write"]
  builtinRoles* = ["admin", "rw", "dev", "ro"]
  checkedByHandlers* = ["run.start.protected", "ref.protect", "profile.grant"]       ## permissions that no route needs by itself: a handler asks for them when the request carries the thing they are about

func isPermission*(name: string): bool =
  for p in catalogue:
    if p.name == name: return true

func levelOf*(name: string): Level =
  for p in catalogue:
    if p.name == name: return p.level
  lvShard

func builtinPermissions*(role: string): seq[string] =
  ## what a built-in role has in it; nothing for a word that is not one. The shard is the super administrator's (D-90): only `admin` has the permissions of the shard's own, and the other
  ## three are for an organisation and below, where those would do nothing.
  case role
  of "admin":
    for p in catalogue: result.add p.name
  of "rw":
    for p in catalogue:
      if p.name notin rwNot and p.level != lvShard: result.add p.name
  of "dev": result = @roAdds & @devAdds
  of "ro": result = @roAdds
  else: discard

func isBuiltin*(role: string): bool = role in builtinRoles

func allowedAtShard*(role: string): bool = role == "admin"
  ## D-90: the shard has no users but its administrators; every other role is given in an organisation or below

func validRoleName*(name: string): bool =
  ## the name of a role an administrator makes: lowercase letters, digits, `-` and `_`, starting with a letter, at most 32, and not one of the four
  if name.len < 1 or name.len > 32 or name[0] notin {'a' .. 'z'} or isBuiltin(name): return false
  for ch in name:
    if ch notin {'a' .. 'z', '0' .. '9', '-', '_'}: return false
  true

type
  NeedScope* = enum
    nsShard      ## held through a binding at the shard
    nsOrg        ## held at the shard or in the organisation `org` that the path names; when `group` is set, also on that group or above it (a binding on a group or project)
    nsInOrg      ## held in the organisation or on any group of it: a list, whose handler leaves out what the caller may not see
    nsAny        ## held anywhere; the handler finds the organisation (and the group) and asks `holds` for it
  Need* = object
    permission*: string     ## "" for a route that is not in the table
    scope*: NeedScope
    org*: string
    group*: string          ## the path of the group or project the route names ("" for none)

func need(permission: string; scope: NeedScope; org = ""; group = ""): Need = Need(permission: permission, scope: scope, org: org, group: group)

func isRead(meth: string): bool = meth in ["GET", "HEAD"]

func groupPathOf(afterWord: string): string =
  ## the path of a group in `/groups/<path>[/variables/NAME | /settings | /hold]`; `variables`, `settings` and `hold` cannot be the name of a group
  var segs: seq[string]
  for seg in afterWord.strip(chars = {'/'}).split('/'):
    if seg.len == 0: continue                            # as `normalPath` of groups.nim reads a path
    if seg in ["variables", "settings", "hold", "members", "secrets"]: break
    segs.add seg
  segs.join("/")

func orgNeed(meth, org, rest: string): Need =
  ## `rest` is what follows `/api/v1/organizations/<slug>`: "" or a path that starts with a slash
  let write = not isRead(meth)
  func has(part: string): bool = rest == part or rest.startsWith(part & "/") or rest.startsWith(part & ":")
  func onTree(): bool = rest.startsWith("/groups/") or rest.startsWith("/projects/")
  func treeNeed(perm: string): Need =
    let gp = groupPathOf(rest[rest.find('/', 1) .. ^1])
    need(perm, (if gp.len > 0: nsOrg else: nsInOrg), org, gp)
  if rest.len == 0: return (if meth == "DELETE": need("org.delete", nsShard) else: Need())
  if rest.endsWith("/storage"): return (if write: need("storage.write", nsShard) else: need("storage.read", nsOrg, org))
  # a hold is placed on the organisation or on a group, and read; `/holds` lists them
  if rest == "/hold" or rest == "/holds": return need(if write: "hold.write" else: "hold.read", nsOrg, org)       # the holds of the whole organisation: not for a binding on a group
  if onTree() and ("/secrets/" in rest or rest.endsWith("/secrets")): return treeNeed(if write: "secret.write" else: "secret.read")
  if onTree() and rest.endsWith("/hold"): return treeNeed(if write: "hold.write" else: "hold.read")
  if onTree() and ("/members/" in rest or rest.endsWith("/members")): return treeNeed(if write: "access.write" else: "access.read")      # the roles on a group or project
  if rest.startsWith("/triggers"):
    let tail = rest["/triggers".len .. ^1]
    let colon = tail.rfind(':')
    if colon >= 0 and not write: return Need()
    if colon >= 0:
      let action = tail[colon + 1 .. ^1]
      if action == "fire": return need("trigger.fire", nsInOrg, org)           # the trigger knows its project: the handler asks for it
      if action in ["enable", "disable", "rotate-secret"]: return need("trigger.write", nsInOrg, org)
      return Need()
    return need(if write: "trigger.write" else: "trigger.read", nsInOrg, org)
  if has("/locks"): return need(if write: "lock.write" else: "lock.read", nsOrg, org)
  if has("/variables"): return need(if write: "variable.write" else: "variable.read", nsOrg, org)
  if onTree() and "/variables" in rest: return treeNeed(if write: "variable.write" else: "variable.read")
  if has("/groups") or has("/projects"):
    if onTree(): return treeNeed(if write: "group.write" else: "group.read")
    return need(if write: "group.write" else: "group.read", (if write: nsOrg else: nsInOrg), org)       # the list of groups; making one names a path
  if has("/caches"): return need(if write: "cache.delete" else: "cache.read", nsOrg, org)
  if has("/secrets"): return need(if write: "secret.write" else: "secret.read", nsOrg, org)
  if has("/members"): return need(if write: "access.write" else: "access.read", nsOrg, org)
  if has("/ldap"):
    # D-87: the directories of an organisation. Adding one makes the core connect to an address someone typed, so it is the shard's; the map of groups to roles is the organisation's
    if rest == "/ldap" or rest == "/ldap/": return (if write: Need() else: need("ldap.read", nsOrg, org))
    if rest.startsWith("/ldap/servers/"):
      if rest.endsWith(":sync"): return (if meth == "POST": need("ldap.map", nsOrg, org) else: Need())
      return need("ldap.write", nsShard, org)
    if rest == "/ldap/mappings" or rest.startsWith("/ldap/mappings/") or rest.startsWith("/ldap/accounts/"): return need("ldap.map", nsOrg, org)
    return Need()

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
  GroupBinding* = tuple[path: string, perms: HashSet[string]]
  Grants* = object
    ## what a user holds: the permissions of the roles at the shard, in each organisation, and on groups and projects of an organisation
    shard*: HashSet[string]
    orgs*: Table[string, HashSet[string]]
    groups*: Table[string, seq[GroupBinding]]

func covers*(boundPath, group: string): bool =
  ## whether a binding on `boundPath` reaches the group or project at `group`: that node, and everything under it
  boundPath.len > 0 and (group == boundPath or group.startsWith(boundPath & "/"))

proc addRole*(g: var Grants; scope: string; perms: openArray[string]) =
  ## `scope` is "shard", "org:<slug>" or "org:<slug>/<group path>". A permission does nothing where it is not about: one of the shard's own in an organisation, and anything but
  ## a thing in the tree of groups on a group.
  if scope == "shard":
    for p in perms: g.shard.incl p
  elif scope.startsWith("org:") and scope.len > 4:
    let rest = scope[4 .. ^1]
    let slash = rest.find('/')
    let slug = if slash < 0: rest else: rest[0 ..< slash]
    if slug.len == 0: return
    if slash < 0:
      if slug notin g.orgs: g.orgs[slug] = initHashSet[string]()
      for p in perms:
        if levelOf(p) != lvShard: g.orgs[slug].incl p
    elif slash < rest.len - 1:
      var kept = initHashSet[string]()
      for p in perms:
        if levelOf(p) == lvGroup: kept.incl p
      if slug notin g.groups: g.groups[slug] = @[]
      g.groups[slug].add (rest[slash + 1 .. ^1], kept)

func holds*(g: Grants; perm: string; org = ""; group = ""): bool =
  ## whether `perm` is held for `org` ("" asks about the shard itself: only a binding at the shard counts) and, with `group`, for that group or project: a binding at the shard or in
  ## the organisation holds for all of them, a binding on a group for it and the groups under it.
  if perm in g.shard: return true
  if org.len == 0: return false
  if levelOf(perm) != lvShard and org in g.orgs and perm in g.orgs[org]: return true
  if group.len > 0 and levelOf(perm) == lvGroup and org in g.groups:
    for b in g.groups[org]:
      if perm in b.perms and covers(b.path, group): return true

func holdsWithin*(g: Grants; perm, org: string): bool =
  ## held in the organisation, or on some group or project of it (the gate of a list: the handler leaves out what is not for the caller)
  if g.holds(perm, org): return true
  if levelOf(perm) == lvGroup and org in g.groups:
    for b in g.groups[org]:
      if perm in b.perms: return true

func holdsAnywhere*(g: Grants; perm: string): bool =
  if perm in g.shard: return true
  if levelOf(perm) == lvShard: return false
  for _, perms in g.orgs:
    if perm in perms: return true
  if levelOf(perm) == lvGroup:
    for _, bs in g.groups:
      for b in bs:
        if perm in b.perms: return true

func orgsWith*(g: Grants; perm: string): seq[string] =
  ## the organisations (by slug) in which `perm` is held through a binding of the organisation; the ones a binding at the shard covers are not listed
  if levelOf(perm) == lvShard: return
  for slug, perms in g.orgs:
    if perm in perms: result.add slug

func groupsWith*(g: Grants; perm: string): seq[tuple[org, path: string]] =
  ## the groups and projects on which `perm` is held through a binding on them
  if levelOf(perm) != lvGroup: return
  for slug, bs in g.groups:
    for b in bs:
      if perm in b.perms: result.add (slug, b.path)

func orgsTouched*(g: Grants): seq[string] =
  ## every organisation in which the user has a binding, of the organisation or of a group of it
  for slug, _ in g.orgs: result.add slug
  for slug, _ in g.groups:
    if slug notin result: result.add slug

func allows*(g: Grants; n: Need): bool =
  ## the gate: whether a request with this need may go on (a route that is not named is refused here, whatever is held)
  if n.permission.len == 0: return false
  case n.scope
  of nsShard: n.permission in g.shard
  of nsOrg: g.holds(n.permission, n.org, n.group)
  of nsInOrg: g.holdsWithin(n.permission, n.org)
  of nsAny: g.holdsAnywhere(n.permission)

func grantsOfRoles*(roles: openArray[string]): Grants =
  ## what the built-in roles give at the shard (the pure tests and the first start use this; the API reads custom roles from the database)
  for r in roles: result.addRole("shard", builtinPermissions(r))
