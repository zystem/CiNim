## The settings of a group that the groups below it inherit (the owner, 2026-11-10): the protected refs, the callers, the approvals, the default ref and the target of the status. The organisation, the
## root, lists none. A list is the union of the lists of the groups on the way down (a group below can add and cannot take away), the approvals are the most that any of them asks for, and the
## default ref and the target of the status are the nearest one that is set. Against a real rqlite; needs CINIM_RQLITE_URL.
import std/[unittest, json, os, times, strutils]
import common/rqlite
import core/[schema, groups, projectpolicy]

let url = getEnv("CINIM_RQLITE_URL")

suite "settings of a group are inherited down the tree":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let tenant = "gi" & newId()[^6 .. ^1].toLowerAscii
    let now = getTime().toUnix()
    check c.createGroup(tenant, "top", now).error.len == 0
    check c.createGroup(tenant, "top/mid", now).error.len == 0
    let p = c.createProject(tenant, "top/mid/p", "https://example.test/p.git", now)
    let q = c.createProject(tenant, "top/q", "https://example.test/q.git", now)
    let other = c.createProject(tenant, "elsewhere", "https://example.test/e.git", now)
    check p.error.len == 0 and q.error.len == 0 and other.error.len == 0
    let top = c.groupIdOf(tenant, "top").id
    let mid = c.groupIdOf(tenant, "top/mid").id

    test "nothing is set anywhere: the root's default is empty, one approval, the branch main":
      check c.protectedPatterns(p.id).len == 0 and c.allowedCallers(p.id).len == 0 and c.requiredApprovals(p.id) == 1
      check c.defaultRef(p.id) == "main" and c.nearestValue(p.id, "status_target") == ""
      check not c.isProtectedRef(p.id, "main")
    test "protected refs: the union down the tree, a group below adds and cannot take away; another branch of the tree is not touched":
      check c.setProtectedRefs(top, @["main"]) == ""
      check c.setProtectedRefs(p.id, @["release/*"]) == ""
      check c.protectedPatterns(p.id) == @["main", "release/*"]
      check c.ownProtectedPatterns(p.id) == @["release/*"] and c.ownProtectedPatterns(mid).len == 0
      check c.protectedPatterns(q.id) == @["main"] and c.protectedPatterns(other.id).len == 0
      check c.isProtectedRef(p.id, "main") and c.isProtectedRef(p.id, "release/1") and not c.isProtectedRef(p.id, "dev")
      check c.isProtectedRef(q.id, "main") and not c.isProtectedRef(q.id, "release/1") and not c.isProtectedRef(other.id, "main")
      check c.setProtectedRefs(p.id, @[]) == "" and c.protectedPatterns(p.id) == @["main"]                   # emptied: it inherits, it does not lose the group's
    test "allowed callers: the union down the tree":
      check c.setAllowedCallers(top, @["ci/a"]) == ""
      check c.setAllowedCallers(mid, @["ci/b"]) == ""
      check c.allowedCallers(p.id) == @["ci/a", "ci/b"] and c.ownAllowedCallers(p.id).len == 0
      check c.callerAllowed(p.id, "ci/a") and c.callerAllowed(p.id, "ci/b/sub") and not c.callerAllowed(p.id, "ci/c")
      check c.allowedCallers(q.id) == @["ci/a"] and not c.callerAllowed(q.id, "ci/b")
    test "required approvals: the most any group on the way asks for; a group below can ask for more and not for fewer":
      c.setRequiredApprovals(top, 2)
      check c.requiredApprovals(p.id) == 2 and c.requiredApprovals(q.id) == 2 and c.requiredApprovals(other.id) == 1
      c.setRequiredApprovals(p.id, 1)                                                                              # asking for 1 below a group that asks for 2 is still 2
      check c.requiredApprovals(p.id) == 2 and c.ownRequiredApprovals(p.id) == 1
      c.setRequiredApprovals(mid, 3)
      check c.requiredApprovals(p.id) == 3 and c.requiredApprovals(q.id) == 2
    test "the longest step: the nearest group that sets one, else the default of the shard; the own value is what the group wrote":
      check c.maxStepTimeout(p.id, 86400) == 86400 and c.ownMaxStepTimeout(p.id) == 0
      c.setMaxStepTimeout(top, 259200)                                                                              # 72 h for everything under top
      check c.maxStepTimeout(p.id, 86400) == 259200 and c.maxStepTimeout(q.id, 86400) == 259200 and c.maxStepTimeout(other.id, 86400) == 86400
      c.setMaxStepTimeout(p.id, 3600)                                                                               # a project below can say less (and more: it is a value, the nearest wins)
      check c.maxStepTimeout(p.id, 86400) == 3600 and c.ownMaxStepTimeout(p.id) == 3600 and c.maxStepTimeout(q.id, 86400) == 259200
      c.setMaxStepTimeout(p.id, 0)                                                                                  # 0 inherits again
      check c.maxStepTimeout(p.id, 86400) == 259200 and c.ownMaxStepTimeout(p.id) == 0
      check c.settingSources(p.id)["max_step_timeout"]["group"].getStr == "top"
    test "default ref and the status target: the nearest one that is set, the project's own first":
      c.setDefaultRef(top, "trunk")
      check c.defaultRef(p.id) == "trunk" and c.defaultRef(q.id) == "trunk" and c.defaultRef(other.id) == "main"
      c.setDefaultRef(p.id, "develop")
      check c.defaultRef(p.id) == "develop" and c.defaultRef(q.id) == "trunk"
      discard c.execute(%*[["UPDATE groups SET status_target = ? WHERE id = ?", """{"provider":"github"}""", top]])
      check c.nearestValue(p.id, "status_target") == """{"provider":"github"}""" and c.nearestValue(other.id, "status_target") == ""
      discard c.execute(%*[["UPDATE groups SET status_target = ? WHERE id = ?", """{"provider":"gitlab"}""", p.id]])
      check c.nearestValue(p.id, "status_target") == """{"provider":"gitlab"}""" and c.nearestValue(q.id, "status_target") == """{"provider":"github"}"""
    test "where a value comes from: the groups that set it, nearest last; the organisation sets none":
      let src = c.settingSources(p.id)
      check src["protected_refs"].len == 1 and src["protected_refs"][0]["group"].getStr == "top" and src["protected_refs"][0]["values"][0].getStr == "main"
      check src["allowed_callers"].len == 2 and src["allowed_callers"][1]["group"].getStr == "top/mid"
      check src["required_approvals"].len == 2 and src["required_approvals"][^1]["group"].getStr == "top/mid" and src["required_approvals"][^1]["value"].getInt == 3
      check src["default_ref"]["group"].getStr == "top/mid/p" and src["status_target"]["group"].getStr == "top/mid/p"
      check c.settingSources(other.id)["protected_refs"].len == 0 and c.settingSources(other.id)["default_ref"].kind == JNull
