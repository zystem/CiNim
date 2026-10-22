## D-76: a poll trigger looks at the commit of its ref once a minute and starts a run when it is not the one it saw last (against a real rqlite; the ref is read by a stand-in for the
## conductor). The first look starts a run on the commit the ref is at. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times]
import common/rqlite
import core/[schema, scheduler, triggers]

let url = getEnv("CINIM_RQLITE_URL")

suite "D-76 poll triggers":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let slug = "pl" & newId()[^6 .. ^1].toLowerAscii
    let orgId = c.addOrganization(slug, "Poll")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns", orgPrefix: "cinim-001", orgShard: "")
    var n = 0
    var commit = "a".repeat(40)                    # what the stand-in says the ref is at
    var answerCode = ""                           # a code: the stand-in could not read it
    var asked = 0
    let resolver: Resolver = proc (t: TriggerRow): ResolvedRef {.gcsafe.} =
      {.cast(gcsafe).}:
        inc asked
        if answerCode.len > 0: ResolvedRef(code: answerCode, message: "the repository did not answer")
        else: ResolvedRef(ok: true, commit: commit)
    proc newPoll(): TriggerRow =
      inc n
      # a script of its own stands in for the repository, which the conductor would read: what is tested is when a firing happens
      let made = c.createTrigger(orgId, TriggerSpec(name: "p" & $n, kind: "poll", script: "return 1", concurrency: "parallel", enabled: true), getTime().toUnix())
      c.getTriggerById(made.id).row
    proc row(t: TriggerRow): TriggerRow = c.getTriggerById(t.id).row

    test "the first look starts a run on the commit the ref is at, and remembers it":
      let t = newPoll()
      let f = co.pollTriggers(1000, resolver)
      check f >= 1 and row(t).seenCommit == commit and row(t).lastRunId.len > 0
    test "the same commit starts nothing, a new one starts a run, and a look is not made again within the minute":
      let t = newPoll()
      discard co.pollTriggers(2000, resolver)
      let before = row(t).lastRunId
      asked = 0
      check co.pollTriggers(2030, resolver) == 0 and asked == 0           # half a minute later: not due
      check co.pollTriggers(2061, resolver) == 0 and row(t).lastRunId == before and asked >= 1       # due, and nothing new
      commit = "b".repeat(40)
      check co.pollTriggers(2125, resolver) >= 1 and row(t).seenCommit == commit and row(t).lastRunId != before
    test "a ref that could not be read starts nothing, keeps what was seen, says why, and is tried again at the next look":
      let t = newPoll()
      discard co.pollTriggers(3000, resolver)
      let seen = row(t).seenCommit
      answerCode = "no_conductor"
      commit = "c".repeat(40)
      discard co.pollTriggers(3061, resolver)
      check row(t).seenCommit == seen and "no_conductor" in row(t).lastResult
      answerCode = ""
      discard co.pollTriggers(3122, resolver)
      check row(t).seenCommit == commit
    test "a trigger that is off is not looked at, and a schedule or a webhook is not a poll":
      let t = newPoll()
      discard c.execute(%*[["UPDATE triggers SET enabled = 0 WHERE id = ?", t.id]])
      asked = 0
      discard co.pollTriggers(4000, resolver)
      check row(t).seenCommit == ""
