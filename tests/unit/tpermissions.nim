## IAM-001, D-84: the permissions of the API, the roles made of them, and what a user holds at the shard and in an organisation. Pure.
import std/[unittest, sets, tables, sequtils, strutils]
import ../../src/core/permissions

func g(shard: openArray[string] = [], orgs: openArray[(string, seq[string])] = []): Grants =
  result.addRole("shard", shard)
  for (slug, perms) in orgs: result.addRole("org:" & slug, perms)

suite "D-84 the catalogue and the roles built in code":
  test "every permission has a level, names are unique, and the four roles are made of catalogue names only":
    check catalogue.mapIt(it.name).toHashSet.len == catalogue.len
    for r in builtinRoles:
      for p in builtinPermissions(r): check isPermission(p)
    check builtinPermissions("boss").len == 0 and not isPermission("run.fly")
  test "admin has every permission; rw every one but access, the users, tokens, stores, audit, the shard's variables and the choice of a store; dev is ro and starts, stops and repeats; ro only reads":
    check builtinPermissions("admin").len == catalogue.len
    let rw = builtinPermissions("rw")
    for p in ["user.manage", "role.manage", "token.manage", "store.manage", "audit.read", "storage.write", "shard.variable.write", "access.read", "access.write"]: check p notin rw
    for p in ["run.start", "run.delete", "trigger.write", "secret.write", "hold.write"]: check p in rw
    for p in ["org.create", "org.delete", "shard.write", "shard.read"]: check p notin rw                           # D-90: the shard\'s own things are the administrator\'s
    let dev = builtinPermissions("dev")
    for p in ["run.read", "run.start", "run.check", "run.abort", "run.retry", "trigger.fire", "log.read"]: check p in dev
    for p in ["trigger.write", "run.delete", "secret.read", "variable.write", "hold.write", "shard.write"]: check p notin dev
    let ro = builtinPermissions("ro")
    check ro.allIt(it.endsWith(".read")) and "run.start" notin ro and "secret.read" notin ro and "shard.read" notin ro
    for r in ["rw", "dev", "ro"]:
      for p in builtinPermissions(r): check levelOf(p) != lvShard
  test "a role of one's own has a plain name, and not one of the four":
    check validRoleName("deployer") and validRoleName("qa-team_2")
    check not validRoleName("admin") and not validRoleName("") and not validRoleName("Deployer") and not validRoleName("1x") and not validRoleName("a b")

suite "D-84 what a request needs":
  test "runs: reading, starting, stopping, repeating, holding, deleting, the logs and the artifacts each need a permission of their own, held anywhere (the handler knows the organisation)":
    for (m, p, want) in [("GET", "/api/v1/runs", "run.read"), ("GET", "/api/v1/runs/s1_x", "run.read"), ("POST", "/api/v1/runs", "run.start"),
                         ("POST", "/api/v1/pipelines:check", "run.check"), ("POST", "/api/v1/runs/s1_x:abort", "run.abort"), ("POST", "/api/v1/runs/s1_x:retry", "run.retry"),
                         ("POST", "/api/v1/runs/s1_x:hold", "hold.write"), ("POST", "/api/v1/runs/s1_x:release", "hold.write"), ("DELETE", "/api/v1/runs/s1_x", "run.delete"),
                         ("GET", "/api/v1/runs/s1_x/log", "log.read"), ("GET", "/api/v1/runs/s1_x/steps/3/log", "log.read"), ("GET", "/api/v1/runs/s1_x/artifacts/a/b", "artifact.read")]:
      let n = needOf(m, p)
      check n.permission == want and n.scope == nsAny
  test "the routes of an organisation name it, and each kind of operation has its permission":
    for (m, p, want) in [("GET", "/api/v1/organizations/acme/triggers", "trigger.read"), ("POST", "/api/v1/organizations/acme/triggers", "trigger.write"),
                         ("DELETE", "/api/v1/organizations/acme/triggers/t1", "trigger.write"), ("POST", "/api/v1/organizations/acme/triggers/t1:fire", "trigger.fire"),
                         ("POST", "/api/v1/organizations/acme/triggers/t1:enable", "trigger.write"), ("POST", "/api/v1/organizations/acme/triggers/t1:rotate-secret", "trigger.write"),
                         ("GET", "/api/v1/organizations/acme/variables", "variable.read"), ("PUT", "/api/v1/organizations/acme/variables/URL", "variable.write"),
                         ("PUT", "/api/v1/organizations/acme/groups/team/variables/URL", "variable.write"), ("GET", "/api/v1/organizations/acme/groups/team", "group.read"),
                         ("PUT", "/api/v1/organizations/acme/projects/team/app", "group.write"), ("GET", "/api/v1/organizations/acme/holds", "hold.read"),
                         ("PUT", "/api/v1/organizations/acme/hold", "hold.write"), ("DELETE", "/api/v1/organizations/acme/groups/team/hold", "hold.write"),
                         ("GET", "/api/v1/organizations/acme/caches", "cache.read"), ("DELETE", "/api/v1/organizations/acme/caches", "cache.delete"),
                         ("GET", "/api/v1/organizations/acme/secrets/TOKEN", "secret.read"), ("PUT", "/api/v1/organizations/acme/secrets/TOKEN", "secret.write"),
                         ("GET", "/api/v1/organizations/acme/locks/stand", "lock.read"), ("GET", "/api/v1/organizations/acme/storage", "storage.read"),
                         ("GET", "/api/v1/organizations/acme/members", "access.read"), ("PUT", "/api/v1/organizations/acme/members/ann", "access.write"),
                         ("GET", "/api/v1/organizations/acme/teams", "access.read"), ("PUT", "/api/v1/organizations/acme/teams/qa", "access.write"), ("DELETE", "/api/v1/organizations/acme/teams/qa", "access.write"),
                         ("PUT", "/api/v1/organizations/acme/teams/qa/members/ann", "access.write"), ("DELETE", "/api/v1/organizations/acme/teams/qa/members/ann", "access.write"),
                         ("DELETE", "/api/v1/organizations/acme/members/ann", "access.write")]:
      let n = needOf(m, p)
      check n.permission == want and n.scope in {nsOrg, nsInOrg} and n.org == "acme"
  test "the shard's own things need a binding at the shard":
    for (m, p, want) in [("GET", "/api/v1/users", "user.manage"), ("POST", "/api/v1/users", "user.manage"), ("PUT", "/api/v1/roles/deployer", "role.manage"),
                         ("GET", "/api/v1/tokens", "token.manage"), ("GET", "/api/v1/audit", "audit.read"), ("POST", "/api/v1/stores:check", "store.manage"),
                         ("GET", "/api/v1/components", "shard.read"), ("PUT", "/api/v1/profile", "shard.write"), ("POST", "/api/v1/organizations", "org.create"),
                         ("DELETE", "/api/v1/organizations/acme", "org.delete"), ("PUT", "/api/v1/organizations/acme/storage", "storage.write"),
                         ("PUT", "/api/v1/variables/URL", "shard.variable.write"), ("GET", "/api/v1/variables", "variable.read"), ("POST", "/api/v1/organizations:reconcile", "shard.write")]:
      let n = needOf(m, p)
      check n.permission == want and n.scope == nsShard
  test "reading the roles and the permissions, and the list of organisations, is held anywhere (what is shown is cut by the handler)":
    for (m, p, want) in [("GET", "/api/v1/roles", "access.read"), ("GET", "/api/v1/permissions", "access.read"), ("GET", "/api/v1/organizations", "org.read")]:
      check needOf(m, p) == Need(permission: want, scope: nsAny, org: "")
  test "a route that is not named needs nothing that any role has, so only an administrator calls it":
    for (m, p) in [("GET", "/api/v1/unknown"), ("PUT", "/api/v1/runs/s1_x"), ("POST", "/api/v1/organizations/acme/nothing"), ("PUT", "/api/v1/components"),
                   ("POST", "/api/v1/organizations/acme/triggers/t1:explode"), ("GET", "/elsewhere"), ("POST", "/api/v1/permissions")]:
      check needOf(m, p).permission == ""
      check not grantsOfRoles(["rw", "dev", "ro"]).allows(needOf(m, p))
  test "every permission of the catalogue is needed by some route (a permission nothing asks for is a mistake)":
    var used = initHashSet[string]()
    for (m, p) in [("GET", "/api/v1/runs"), ("POST", "/api/v1/runs"), ("POST", "/api/v1/pipelines:check"), ("POST", "/api/v1/runs/x:abort"), ("POST", "/api/v1/runs/x:retry"), ("POST", "/api/v1/runs/x:approve"),
                   ("DELETE", "/api/v1/runs/x"), ("GET", "/api/v1/runs/x/log"), ("GET", "/api/v1/runs/x/artifacts"), ("GET", "/api/v1/organizations/o/triggers"),
                   ("POST", "/api/v1/organizations/o/triggers"), ("POST", "/api/v1/organizations/o/triggers/t:fire"), ("GET", "/api/v1/organizations/o/variables"),
                   ("PUT", "/api/v1/organizations/o/variables/V"), ("GET", "/api/v1/organizations/o/secrets"), ("PUT", "/api/v1/organizations/o/secrets/S"),
                   ("GET", "/api/v1/organizations/o/groups"), ("PUT", "/api/v1/organizations/o/groups/g"), ("GET", "/api/v1/organizations/o/holds"), ("PUT", "/api/v1/organizations/o/hold"),
                   ("GET", "/api/v1/organizations/o/caches"), ("DELETE", "/api/v1/organizations/o/caches"), ("GET", "/api/v1/organizations/o/locks"), ("PUT", "/api/v1/organizations/o/locks/l"),
                   ("GET", "/api/v1/organizations/o/storage"), ("GET", "/api/v1/organizations"), ("GET", "/api/v1/roles"), ("PUT", "/api/v1/organizations/o/members/u"),
                   ("GET", "/api/v1/components"), ("PUT", "/api/v1/profile"), ("PUT", "/api/v1/variables/V"), ("POST", "/api/v1/organizations"), ("DELETE", "/api/v1/organizations/o"),
                   ("PUT", "/api/v1/organizations/o/storage"), ("GET", "/api/v1/stores"), ("GET", "/api/v1/users"), ("PUT", "/api/v1/roles/r"), ("GET", "/api/v1/tokens"), ("GET", "/api/v1/audit"),
                   ("GET", "/api/v1/organizations/o/ldap"), ("POST", "/api/v1/organizations/o/ldap/mappings"), ("PUT", "/api/v1/organizations/o/ldap/servers/s")]:
      used.incl needOf(m, p).permission
    for p in catalogue: check p.name in used or p.name in checkedByHandlers

suite "D-87 the directories of an organisation":
  test "reading is the organisation\'s, the map and the sync are the organisation\'s, adding and checking a directory is the shard\'s":
    check needOf("GET", "/api/v1/organizations/acme/ldap") == Need(permission: "ldap.read", scope: nsOrg, org: "acme")
    for (m, p, want, sc) in [("PUT", "/api/v1/organizations/acme/ldap/servers/corp", "ldap.write", nsShard), ("DELETE", "/api/v1/organizations/acme/ldap/servers/corp", "ldap.write", nsShard),
                             ("POST", "/api/v1/organizations/acme/ldap/servers/corp:check", "ldap.write", nsShard), ("POST", "/api/v1/organizations/acme/ldap/servers/corp:sync", "ldap.map", nsOrg),
                             ("POST", "/api/v1/organizations/acme/ldap/mappings", "ldap.map", nsOrg), ("DELETE", "/api/v1/organizations/acme/ldap/mappings/m1", "ldap.map", nsOrg),
                             ("PUT", "/api/v1/organizations/acme/ldap/accounts/ann", "ldap.map", nsOrg), ("DELETE", "/api/v1/organizations/acme/ldap/accounts/ann", "ldap.map", nsOrg)]:
      let n = needOf(m, p)
      check n.permission == want and n.scope == sc and n.org == "acme"
    for (m, p) in [("PUT", "/api/v1/organizations/acme/ldap"), ("GET", "/api/v1/organizations/acme/ldap/servers/corp:sync"), ("PUT", "/api/v1/organizations/acme/ldap/other")]:
      check needOf(m, p).permission == ""
  test "D-91 teams are the organisation\'s: an administrator of the organisation manages them, one of a group of it does not":
    var org, grp: Grants
    org.addRole("org:acme", builtinPermissions("admin"))
    grp.addRole("org:acme/ci", builtinPermissions("admin"))
    check org.allows(needOf("PUT", "/api/v1/organizations/acme/teams/qa")) and not grp.allows(needOf("PUT", "/api/v1/organizations/acme/teams/qa")) and not grp.allows(needOf("GET", "/api/v1/organizations/acme/teams"))
    check grp.allows(needOf("PUT", "/api/v1/organizations/acme/groups/ci/members/team:qa"))            # but a role of a team on the group's own node is the group\'s to give
  test "an administrator of an organisation maps groups and syncs but cannot add a directory; rw has none of it; admin of the shard has all":
    var org: Grants
    org.addRole("org:acme", builtinPermissions("admin"))
    check org.allows(needOf("GET", "/api/v1/organizations/acme/ldap")) and org.allows(needOf("POST", "/api/v1/organizations/acme/ldap/mappings")) and org.allows(needOf("POST", "/api/v1/organizations/acme/ldap/servers/corp:sync"))
    check not org.allows(needOf("PUT", "/api/v1/organizations/acme/ldap/servers/corp")) and not org.allows(needOf("POST", "/api/v1/organizations/acme/ldap/servers/corp:check"))
    check not org.allows(needOf("GET", "/api/v1/organizations/beta/ldap"))
    let rw = grantsOfRoles(["rw"])
    for (m, p) in [("GET", "/api/v1/organizations/acme/ldap"), ("POST", "/api/v1/organizations/acme/ldap/mappings"), ("PUT", "/api/v1/organizations/acme/ldap/servers/corp")]:
      check not rw.allows(needOf(m, p))
    check grantsOfRoles(["admin"]).allows(needOf("PUT", "/api/v1/organizations/acme/ldap/servers/corp"))

suite "D-84 groups and projects":
  test "the routes of a group name its path (variables, settings and hold are not part of it), the lists name only the organisation":
    for (m, p, want, grp, sc) in [("GET", "/api/v1/organizations/acme/groups/ci/cinim", "group.read", "ci/cinim", nsOrg), ("PUT", "/api/v1/organizations/acme/projects/ci/cinim", "group.write", "ci/cinim", nsOrg),
                                  ("DELETE", "/api/v1/organizations/acme/groups/ci", "group.write", "ci", nsOrg),
                                  ("GET", "/api/v1/organizations/acme/groups/ci/cinim/variables", "variable.read", "ci/cinim", nsOrg),
                                  ("PUT", "/api/v1/organizations/acme/groups/ci/variables/URL", "variable.write", "ci", nsOrg),
                                  ("PUT", "/api/v1/organizations/acme/groups/ci/cinim/hold", "hold.write", "ci/cinim", nsOrg), ("GET", "/api/v1/organizations/acme/projects/ci/cinim/hold", "hold.read", "ci/cinim", nsOrg),
                                  ("PUT", "/api/v1/organizations/acme/groups/ci/settings", "group.write", "ci", nsOrg),
                                  ("GET", "/api/v1/organizations/acme/projects/ci/cinim/secrets", "secret.read", "ci/cinim", nsOrg), ("PUT", "/api/v1/organizations/acme/groups/ci/secrets/TOKEN", "secret.write", "ci", nsOrg),
                                  ("DELETE", "/api/v1/organizations/acme/projects/ci/cinim/secrets/TOKEN", "secret.write", "ci/cinim", nsOrg),
                                  ("GET", "/api/v1/organizations/acme/groups/ci/cinim/members", "access.read", "ci/cinim", nsOrg), ("PUT", "/api/v1/organizations/acme/projects/ci/members/ann", "access.write", "ci", nsOrg),
                                  ("GET", "/api/v1/organizations/acme/groups", "group.read", "", nsInOrg), ("GET", "/api/v1/organizations/acme/projects", "group.read", "", nsInOrg),
                                  ("GET", "/api/v1/organizations/acme/holds", "hold.read", "", nsOrg), ("GET", "/api/v1/organizations/acme/triggers", "trigger.read", "", nsInOrg),
                                  ("POST", "/api/v1/organizations/acme/triggers/t1:fire", "trigger.fire", "", nsInOrg), ("DELETE", "/api/v1/organizations/acme/triggers/t1", "trigger.write", "", nsInOrg)]:
      let n = needOf(m, p)
      check n.permission == want and n.group == grp and n.scope == sc and n.org == "acme"
  test "a binding on a group holds for that group and everything under it, not for a sibling, a parent, or a group whose name only starts the same":
    let u = g(); var x = u
    x.addRole("org:acme/ci", builtinPermissions("dev"))
    for grp in ["ci", "ci/cinim", "ci/cinim/deep"]: check x.holds("run.start", "acme", grp)
    for grp in ["", "cinema", "ci2", "ci2/x", "team", "team/ci"]: check not x.holds("run.start", "acme", grp)
    check not x.holds("run.start", "beta", "ci") and not x.holds("run.start", "acme")
  test "on a group only what is about the tree of groups does anything: not the caches, the locks, the storage or the shard":
    var x: Grants
    x.addRole("org:acme/ci", builtinPermissions("admin"))
    for p in ["run.start", "run.abort", "trigger.write", "trigger.fire", "variable.write", "group.write", "hold.write", "log.read", "access.write", "access.read", "secret.read", "secret.write", "run.start.protected", "ref.protect", "profile.grant"]: check x.holds(p, "acme", "ci/app")
    for p in ["cache.delete", "lock.write", "storage.read", "user.manage", "shard.write"]:
      check not x.holds(p, "acme", "ci/app") and not x.holdsAnywhere(p)
  test "a role in the organisation holds for every group of it; a role on a group adds to it; the gate lets a list through for whoever holds the permission on some group of it":
    var x: Grants
    x.addRole("org:acme", builtinPermissions("ro"))
    x.addRole("org:acme/ci", builtinPermissions("dev"))
    check x.holds("run.read", "acme", "anything/at/all") and x.holds("run.start", "acme", "ci/app") and not x.holds("run.start", "acme", "other")
    check x.allows(needOf("GET", "/api/v1/organizations/acme/groups/ci/app")) and x.allows(needOf("POST", "/api/v1/organizations/acme/triggers/t:fire"))
    var y: Grants
    y.addRole("org:acme/ci", builtinPermissions("dev"))
    check y.allows(needOf("POST", "/api/v1/organizations/acme/triggers/t:fire")) and y.allows(needOf("GET", "/api/v1/organizations/acme/groups"))
    check not y.allows(needOf("POST", "/api/v1/organizations/acme/triggers")) and not y.allows(needOf("GET", "/api/v1/organizations/beta/groups"))
    check y.allows(needOf("PUT", "/api/v1/organizations/acme/groups/ci/variables/V")) == false         # dev does not write variables
    check y.allows(needOf("POST", "/api/v1/runs")) and y.allows(needOf("POST", "/api/v1/runs/x:abort")) and not y.allows(needOf("GET", "/api/v1/components"))
    check y.groupsWith("run.start") == @[("acme", "ci")] and y.orgsTouched == @["acme"] and y.orgsWith("run.start").len == 0
  test "a binding on a group with a path that is not one is nothing":
    var x: Grants
    x.addRole("org:acme/", builtinPermissions("dev"))
    x.addRole("org:/ci", builtinPermissions("dev"))
    check not x.holdsAnywhere("run.start")

suite "D-84 what a user holds":
  test "a role at the shard holds in every organisation, a role in an organisation in that one only":
    let dev = grantsOfRoles(["dev"])
    check dev.holds("run.start", "acme") and dev.holds("run.start", "beta") and dev.holds("run.start")
    let inAcme = g(orgs = {"acme": builtinPermissions("dev")})
    check inAcme.holds("run.start", "acme") and not inAcme.holds("run.start", "beta") and not inAcme.holds("run.start")
    check inAcme.holdsAnywhere("run.start") and not inAcme.holdsAnywhere("trigger.write")
  test "different roles in different organisations; the permissions of several roles in one add up":
    let u = g(orgs = {"acme": builtinPermissions("ro") & builtinPermissions("dev"), "beta": builtinPermissions("ro")})
    check u.holds("run.abort", "acme") and not u.holds("run.abort", "beta") and u.holds("run.read", "beta")
    check u.orgsWith("run.read").len == 2 and u.orgsWith("run.abort") == @["acme"]
  test "a permission of the shard's own does nothing in an organisation, whatever role it came with":
    let admin = g(orgs = {"acme": builtinPermissions("admin")})
    check admin.holds("run.start", "acme") and admin.holds("access.write", "acme") and admin.holds("trigger.write", "acme")
    for p in ["user.manage", "role.manage", "org.delete", "org.create", "shard.write", "storage.write", "audit.read"]:
      check not admin.holds(p, "acme") and not admin.holdsAnywhere(p)
  test "the gate: the need of the request against what is held; a shard need is not met by a role in an organisation":
    let inAcme = g(orgs = {"acme": builtinPermissions("admin")})
    check inAcme.allows(needOf("PUT", "/api/v1/organizations/acme/members/ann")) and not inAcme.allows(needOf("PUT", "/api/v1/organizations/beta/members/ann"))
    check inAcme.allows(needOf("GET", "/api/v1/runs")) and inAcme.allows(needOf("POST", "/api/v1/runs/x:abort")) and inAcme.allows(needOf("GET", "/api/v1/organizations"))
    check not inAcme.allows(needOf("GET", "/api/v1/components")) and not inAcme.allows(needOf("GET", "/api/v1/users")) and not inAcme.allows(needOf("GET", "/api/v1/variables"))
    check not inAcme.allows(needOf("DELETE", "/api/v1/organizations/acme")) and not inAcme.allows(needOf("PUT", "/api/v1/organizations/acme/storage"))
    let rw = grantsOfRoles(["rw"])
    check rw.allows(needOf("DELETE", "/api/v1/organizations/acme/caches")) and not rw.allows(needOf("PUT", "/api/v1/organizations/acme/members/ann"))
  test "a role of one's own is any set of permissions: start and stop, and nothing more":
    let u = g(orgs = {"acme": @["run.read", "run.start", "run.abort"]})
    check u.allows(needOf("POST", "/api/v1/runs")) and u.allows(needOf("POST", "/api/v1/runs/x:abort")) and u.allows(needOf("GET", "/api/v1/runs/x"))
    check not u.allows(needOf("POST", "/api/v1/runs/x:retry")) and not u.allows(needOf("GET", "/api/v1/runs/x/log")) and not u.allows(needOf("POST", "/api/v1/organizations/acme/triggers/t:fire"))

suite "D-92 what a binding is tied to":
  let dev = builtinPermissions("dev")
  test "own runs only: the run permissions hold for a run the caller started; the rest of the role holds as ever":
    var u: Grants
    u.addRole("org:acme", dev, BindingCondition(onlyOwn: true))
    check u.holdsRun("run.abort", "acme", "ci", RunFacts(own: true)) and not u.holdsRun("run.abort", "acme", "ci", RunFacts(own: false))
    check u.holdsRun("run.read", "acme", "ci/app", RunFacts(own: true)) and not u.holdsRun("run.read", "acme", "ci/app", RunFacts())
    check u.holds("trigger.fire", "acme") and u.holds("run.check", "acme")                  # not about one run
    check not u.holds("run.abort", "acme") and not u.holds("run.read", "acme", "ci")          # `holds` is the unconditional answer
    check u.holdsAnywhere("run.abort") and u.holdsWithin("run.abort", "acme") and not u.holdsWithin("run.abort", "beta")
    check u.allows(needOf("POST", "/api/v1/runs/x:abort"))                                  # the gate lets it through, the handler asks again with the run
    check not u.holdsRun("run.abort", "beta", "ci", RunFacts(own: true))
  test "refs: a run on a ref that matches one of the patterns; a run on none matches none":
    var u: Grants
    u.addRole("org:acme", dev, BindingCondition(refs: @["main", "release/*"]))
    for r in ["main", "release/1.2"]: check u.holdsRun("run.start", "acme", "ci", RunFacts(ref0: r))
    for r in ["", "main2", "feature/x", "release"]: check not u.holdsRun("run.start", "acme", "ci", RunFacts(ref0: r))
  test "own and refs together are both needed":
    var u: Grants
    u.addRole("org:acme", dev, BindingCondition(onlyOwn: true, refs: @["main"]))
    check u.holdsRun("run.retry", "acme", "ci", RunFacts(own: true, ref0: "main"))
    check not u.holdsRun("run.retry", "acme", "ci", RunFacts(own: true, ref0: "x")) and not u.holdsRun("run.retry", "acme", "ci", RunFacts(own: false, ref0: "main"))
  test "on a group the condition reaches that group and what is under it":
    var u: Grants
    u.addRole("org:acme/ci", dev, BindingCondition(onlyOwn: true))
    check u.holdsRun("run.abort", "acme", "ci/app", RunFacts(own: true)) and u.holdsRun("run.abort", "acme", "ci", RunFacts(own: true))
    check not u.holdsRun("run.abort", "acme", "cix", RunFacts(own: true)) and not u.holdsRun("run.abort", "acme", "ci", RunFacts())
    check u.limitedWith("run.abort") == @[(org: "acme", path: "ci", onlyOwn: true, refs: newSeq[string]())]
  test "a binding without a condition is as before, and a plain one next to a tied one wins":
    var u: Grants
    u.addRole("org:acme", dev, BindingCondition(onlyOwn: true))
    u.addRole("org:acme", builtinPermissions("ro"))
    check u.holdsRun("run.read", "acme", "ci", RunFacts()) and not u.holdsRun("run.abort", "acme", "ci", RunFacts())
    check u.limitedWith("run.read").len == 0 or u.limitedWith("run.read").len == 1
  test "at the shard a condition is not honoured: only admin is a right there, whole":
    var u: Grants
    u.addRole("shard", builtinPermissions("admin"), BindingCondition(onlyOwn: true))
    check u.holds("run.abort", "acme") and u.limited.len == 0
  test "a term ends the binding":
    check BindingCondition(expiresAt: 100).expired(100) and BindingCondition(expiresAt: 100).expired(101) and not BindingCondition(expiresAt: 100).expired(99)
    check not BindingCondition().expired(1_000_000_000) and not BindingCondition().limits and BindingCondition(onlyOwn: true).limits and BindingCondition(refs: @["a"]).limits

suite "D-93 approval":
  test "approving and rejecting a run need run.approve, held anywhere (the handler knows the run); dev and ro do not have it, rw and admin do":
    check needOf("POST", "/api/v1/runs/x:approve") == needOf("POST", "/api/v1/runs/x:reject") and needOf("POST", "/api/v1/runs/x:approve").permission == "run.approve"
    check "run.approve" in builtinPermissions("rw") and "run.approve" in builtinPermissions("admin")
    check "run.approve" notin builtinPermissions("dev") and "run.approve" notin builtinPermissions("ro")
    check isRunPermission("run.approve") and "approval.configure" in checkedByHandlers and "approval.configure" in builtinPermissions("rw")
