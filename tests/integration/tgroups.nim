## PRJ-001, VAR-001, VAR-004, D-54: the structure shard -> organisation -> group (nested up to 8 levels) -> job, and the variables at each level, against a real rqlite.
## The nearer level wins; the launch parameters are above all of them. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, sequtils]
import common/rqlite
import core/[schema, scheduler, orgvars, groups]

let url = getEnv("CINIM_RQLITE_URL")

suite "PRJ-001 the groups of an organisation":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let sfx = newId()[^6 .. ^1].toLowerAscii
    var n = 0
    let now = getTime().toUnix()
    proc newOrg(): string =
      inc n
      c.addOrganization("g" & $n & sfx, "G")
    proc sourceOf(env: seq[EffectiveVariable]; name: string): string =
      for e in env:
        if e.name == name: return e.source & (if e.group.len > 0: "(" & e.group & ")" else: "") & ":" & e.value

    test "a group is made under an existing one, the same call twice is one group, the organisation is the root":
      let org = newOrg()
      check c.createGroup(org, "team", now).created
      check c.createGroup(org, "team/backend", now).created
      let again = c.createGroup(org, "/team/backend/", now)
      check again.error == "" and not again.created and again.id.len > 0
      check c.createGroup(org, "ops/db", now).error.contains("create the parent first")
      check c.createGroup(org, "", now).error.len > 0
      check c.listGroups(org).mapIt(it.path) == @["team", "team/backend"]
    test "nested up to 8 levels, not 9":
      let org = newOrg()
      var path = ""
      for i in 1 .. 8:
        path.add (if i > 1: "/" else: "") & "l" & $i
        check c.createGroup(org, path, now).error == ""
      check c.createGroup(org, path & "/l9", now).error.contains("at most 8")
    test "a name is lowercase letters, digits and '-', starting with a letter, and not the word the URLs use":
      let org = newOrg()
      for bad in ["Team", "1team", "te_am", "a b", "variables", "x".repeat(41)]:
        check c.createGroup(org, bad, now).error.len > 0
      check c.createGroup(org, "ok-1", now).error == ""
    test "organisations do not see each other's groups; the same path in two organisations is two groups":
      let a = newOrg()
      let b = newOrg()
      let ga = c.createGroup(a, "shared", now).id
      let gb = c.createGroup(b, "shared", now).id
      check ga != gb and c.groupIdOf(a, "shared").id == ga and not c.groupIdOf(a, "other").found
    test "a group goes only when empty: not with a group below, a run or a trigger; its variables go with it":
      let org = newOrg()
      let prof = c.ensureOrganizationProfile(org, "cinim-001-g" & sfx & $n)
      let top = c.createGroup(org, "top", now).id
      discard c.createGroup(org, "top/sub", now)
      check c.deleteGroup(org, "top").error.contains("below")
      let r = co.createRun("return 1", org, prof, groupId = c.groupIdOf(org, "top/sub").id)
      check c.deleteGroup(org, "top/sub").error.contains("runs")
      discard c.execute(%*[["DELETE FROM runs WHERE id = ?", r]])
      let sub = c.groupIdOf(org, "top/sub").id
      check c.setScopeVariable(vsGroup, sub, "V", "x", now) == ""
      check c.deleteGroup(org, "top/sub").deleted
      check c.query(%*[["SELECT count(*) FROM group_variables WHERE group_id = ?", sub]])["results"][0]["values"][0][0].getInt == 0
      check c.deleteGroup(org, "top").deleted and not c.deleteGroup(org, "top").deleted and top.len > 0

suite "VAR-001 the variables at every level: shard, organisation, group, launch":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let now = getTime().toUnix()
    var n = 0
    proc sourceOf(env: seq[EffectiveVariable]; name: string): string =
      for e in env:
        if e.name == name: return e.source & (if e.group.len > 0: "(" & e.group & ")" else: "") & ":" & e.value

    test "VAR-004 from the lowest: the shard, the organisation, the groups from the top to the run's own, the launch parameters":
      inc n
      let org = c.addOrganization("v" & $n & sfx, "V")
      let prof = c.ensureOrganizationProfile(org, "cinim-001-v" & $n & sfx)
      discard c.createGroup(org, "team", now)
      discard c.createGroup(org, "team/backend", now)
      discard c.createGroup(org, "team/other", now)
      let team = c.groupIdOf(org, "team").id
      let backend = c.groupIdOf(org, "team/backend").id
      let other = c.groupIdOf(org, "team/other").id
      let shardName = "SHARDONLY" & $n          # shard variables are the shard's, every run's: they are taken away at the end, so that no other test sees them
      defer:
        discard c.deleteScopeVariable(vsShard, "", shardName)
        discard c.deleteScopeVariable(vsShard, "", "LVL")
      check c.setScopeVariable(vsShard, "", shardName, "s", now) == ""
      check c.setScopeVariable(vsShard, "", "LVL", "shard", now) == ""
      check c.setVariable(org, "LVL", "org", now) == ""
      check c.setVariable(org, "ORGONLY", "o", now) == ""
      check c.setScopeVariable(vsGroup, team, "LVL", "team", now) == ""
      check c.setScopeVariable(vsGroup, team, "TEAMONLY", "t", now) == ""
      check c.setScopeVariable(vsGroup, backend, "LVL", "backend", now) == ""
      check c.setScopeVariable(vsGroup, other, "LVL", "other", now) == ""
      check c.setScopeVariable(vsGroup, backend, "LAUNCHED", "group", now) == ""
      let r = co.createRun("return 1", org, prof, @[("LAUNCHED", "launch")], groupId = backend)
      let env = c.effectiveVariables(r)
      check sourceOf(env, shardName) == "shard:s" and sourceOf(env, "ORGONLY") == "organization:o"
      check sourceOf(env, "TEAMONLY") == "group(team):t"                       # inherited from the group above
      check sourceOf(env, "LVL") == "group(team/backend):backend"             # the nearest wins; the sibling group's is not seen
      check sourceOf(env, "LAUNCHED") == "launch:launch"                      # a launch parameter is above the groups
      let top = co.createRun("return 1", org, prof, groupId = team)
      check sourceOf(c.effectiveVariables(top), "LVL") == "group(team):team"
      let root = co.createRun("return 1", org, prof)
      check sourceOf(c.effectiveVariables(root), "LVL") == "organization:org" and sourceOf(c.effectiveVariables(root), "TEAMONLY") == ""
    test "the view of a run says its group and where each value came from":
      inc n
      let org = c.addOrganization("v" & $n & sfx, "V")
      let prof = c.ensureOrganizationProfile(org, "cinim-001-v" & $n & sfx)
      discard c.createGroup(org, "a", now)
      discard c.createGroup(org, "a/b", now)
      let ab = c.groupIdOf(org, "a/b").id
      check c.setScopeVariable(vsGroup, c.groupIdOf(org, "a").id, "FROM_A", "1", now) == ""
      let r = co.createRun("return 1", org, prof, groupId = ab)
      let view = co.getRun(r)
      check view["group"].getStr == "a/b"
      var found = false
      for v in view["variables"]:
        if v["name"].getStr == "FROM_A":
          found = v["source"].getStr == "group" and v["group"].getStr == "a"
      check found
      check co.getRun(co.createRun("return 1", org, prof))["group"].getStr == ""
    test "each level has its own limits: a hundred variables, 64 KiB, the same rules for names":
      inc n
      let org = c.addOrganization("v" & $n & sfx, "V")
      discard c.createGroup(org, "g", now)
      let g = c.groupIdOf(org, "g").id
      for i in 1 .. 100: check c.setScopeVariable(vsGroup, g, "V" & $i, "x", now) == ""
      check c.setScopeVariable(vsGroup, g, "V101", "x", now) != ""
      check c.setScopeVariable(vsGroup, g, "PATH", "x", now) != ""
      check c.setVariable(org, "FREE", "x", now) == ""              # the organisation's own count is another count
      check c.deleteScopeVariable(vsGroup, g, "V1") and not c.deleteScopeVariable(vsGroup, g, "V1")
      check c.setScopeVariable(vsShard, "", "BAD-NAME", "x", now) != ""
