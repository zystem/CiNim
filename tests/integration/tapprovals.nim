## D-93, against a real rqlite: a run that waits for approval is WAITING, holds nothing, and starts when enough people other than its author, who hold run.approve for its project, have approved;
## one rejection aborts it, the deadline times it out, and a run with nobody to approve it is aborted. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, tables, sequtils]
import common/[rqlite, scriptsource]
import core/[schema, scheduler, apiauth, groups, projectpolicy, approvals, loggate, logcircuit, runlease, teams]

let url = getEnv("CINIM_RQLITE_URL")

suite "D-93 runs that wait for approval":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let slug = "ap" & sfx
    let org = c.addOrganization(slug, "A")
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let prof = c.ensureOrganizationProfile(org, "cinim-001-" & slug)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let now = getTime().toUnix()
    check c.createGroup(org, "ci", now).error.len == 0
    check c.createProject(org, "ci/app", "https://example.test/app.git", now).error.len == 0
    let gid = c.groupIdOf(org, "ci/app").id
    var n = 0
    proc person(role: string; scope = ""): string =
      inc n
      let name = "u" & sfx & $n
      check c.createUser(name, role, "a-long-password-of-" & name, now, (if scope.len == 0: "org:" & slug else: scope))
      name
    proc startRun(author: string; required = 1; secs = 3600'i64; ref0 = ""): string =
      co.createRun("return 1", org, prof, @[], groupId = gid, source = Source(repository: "https://example.test/app.git", commit: "a".repeat(40), path: ".ci/pipeline.lua", refName: ref0),
                   actor = "user:" & author, approval = ApprovalSpec(required: required, timeoutSeconds: secs))
    proc stateOf(id: string): string = co.getRun(id)["state"].getStr
    c.setRequiredApprovals(gid, 1)
    proc reset() =
      ## each test has the organisation to itself: the roles of the people the earlier ones made are gone
      discard c.execute(%*[["DELETE FROM role_bindings WHERE scope = ? OR scope LIKE ?", "org:" & slug, "org:" & slug & "/%"], ["DELETE FROM team_members WHERE team_id IN (SELECT id FROM teams WHERE tenant_id = ?)", org]])

    test "nobody besides the author could approve: the run is ABORTED at once, and says why":
      reset()
      let author = person("rw")
      let id = startRun(author)
      let r = co.getRun(id)
      check r["state"].getStr == "ABORTED" and r["failure"]["code"].getStr == "no_approvers" and "nobody" in r["failure"]["message"].getStr
    test "a person with run.approve other than the author: the run waits; the author cannot answer; one approval starts it":
      reset()
      let author = person("rw")
      let boss = person("rw")
      let id = startRun(author)
      check stateOf(id) == "WAITING"
      let r = co.getRun(id)
      check r["approval"]["required"].getInt == 1 and r["approval"]["waiting"].getBool and r["approval"]["approved_by"].len == 0 and r["approval"]["deadline"].getBiggestInt > now
      check c.answerApproval(id, author, "approve", "", now).outcome == aoOwnRun and stateOf(id) == "WAITING"
      let a = c.answerApproval(id, boss, "approve", "looks fine", now)
      check a.outcome == aoApproved and a.state == "QUEUED" and stateOf(id) == "QUEUED"          # approved: queued for a conductor like any run
      check co.getRun(id)["approval"]["approved_by"] == %*[boss] and not co.getRun(id)["approval"]["waiting"].getBool
      check c.answerApproval(id, boss, "approve", "", now).outcome == aoNotWaiting
    test "a role without run.approve (dev, ro) is nobody to ask: with only them the run is aborted":
      reset()
      let author = person("rw")
      discard person("dev"); discard person("ro")
      check stateOf(startRun(author)) == "ABORTED"
    test "two approvals: the first leaves the run waiting, the same person cannot answer twice, the second starts it":
      reset()
      let author = person("dev")
      let a = person("rw"); let b = person("admin", "org:" & slug)
      let id = startRun(author, required = 2)
      check stateOf(id) == "WAITING"
      let first = c.answerApproval(id, a, "approve", "", now)
      check first.outcome == aoGiven and first.have == 1 and first.required == 2 and stateOf(id) == "WAITING"
      check c.answerApproval(id, a, "approve", "", now).outcome == aoAlreadyAnswered
      check c.answerApproval(id, b, "approve", "", now).outcome == aoApproved and stateOf(id) == "QUEUED"
    test "needing more approvals than there are people who could give them aborts the run":
      reset()
      let author = person("dev")
      discard person("rw")
      check stateOf(startRun(author, required = 2)) == "ABORTED"
    test "one rejection aborts the run, with the reason":
      reset()
      let author = person("dev")
      let boss = person("rw")
      let id = startRun(author)
      let r = c.answerApproval(id, boss, "reject", "not now", now)
      check r.outcome == aoRejected and stateOf(id) == "ABORTED"
      let run = co.getRun(id)
      check run["failure"]["code"].getStr == "rejected" and "not now" in run["failure"]["message"].getStr and run["approval"]["rejected_by"] == %*[boss]
    test "the deadline times the run out; before it nothing happens":
      reset()
      let author = person("dev")
      discard person("rw")
      let id = startRun(author, secs = 120)
      check c.sweepApprovals(now + 60) == 0 or stateOf(id) == "WAITING"
      check stateOf(id) == "WAITING"
      discard c.sweepApprovals(now + 3600)
      let run = co.getRun(id)
      check run["state"].getStr == "TIMED_OUT" and run["failure"]["code"].getStr == "approval_timeout"
    test "when the last person who could approve is taken away, the sweep aborts the run":
      reset()
      let author = person("dev")
      let boss = person("rw")
      let id = startRun(author)
      discard c.sweepApprovals(now)
      check stateOf(id) == "WAITING"
      check c.setMember("org:" & slug, boss, @[]) == ""
      discard c.sweepApprovals(now)
      check co.getRun(id)["failure"]["code"].getStr == "no_approvers" and stateOf(id) == "ABORTED"
    test "a member of a team that holds run.approve counts; a binding tied to other refs or to own runs does not":
      reset()
      let author = person("dev")
      let viaTeam = person("ro")
      check c.putTeam(org, "release", %*{"description": "the releasers"}, now).error == ""
      check c.addTeamMember(org, "release", viaTeam).error == ""
      check c.setMember("org:" & slug, "team:" & slug & "/release", @["rw"]) == ""
      let tiedRef = person("dev")
      check c.setMember("org:" & slug, tiedRef, @["rw"], {"rw": BindingCondition(refs: @["release/*"])}.toTable) == ""
      let tiedOwn = person("dev")
      check c.setMember("org:" & slug, tiedOwn, @["rw"], {"rw": BindingCondition(onlyOwn: true)}.toTable) == ""
      check tiedRef notin c.approverNames(slug, "ci/app", "main", "user:" & author, now) and tiedRef in c.approverNames(slug, "ci/app", "release/1", "user:" & author, now)
      check tiedOwn notin c.approverNames(slug, "ci/app", "release/1", "user:" & author, now)
      check viaTeam in c.approverNames(slug, "ci/app", "main", "user:" & author, now)
    test "a run that asks for no approval is RUNNING as ever, and the project's number is kept":
      reset()
      let id = co.createRun("return 1", org, prof, @[], groupId = gid, actor = "user:x")
      check stateOf(id) == "QUEUED" and not co.getRun(id).hasKey("approval") and co.getRun(id)["queue"]["reason"].getStr.len > 0
      c.setRequiredApprovals(gid, 3)
      check c.requiredApprovals(gid) == 3 and c.requiredApprovals("") == 1
      c.setRequiredApprovals(gid, 1)
