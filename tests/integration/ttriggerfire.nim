## TRG-004: what a firing does when an earlier run of the trigger has not ended (against a real rqlite). `parallel` starts a run anyway, `abort_newest` cancels the new firing (starts none) while an earlier run
## has not ended in any state that is not final, `abort_previous` cancels the earlier runs of the same trigger and starts the new one. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times]
import common/rqlite
import core/[schema, scheduler, triggers, groups]

let url = getEnv("CINIM_RQLITE_URL")

suite "TRG-004 concurrency of a trigger":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let slug = "tf" & sfx
    let orgId = c.addOrganization(slug, "Trigger fire")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns", orgPrefix: "cinim-001", orgShard: "")
    var n = 0
    proc newTrigger(concurrency: string): TriggerRow =
      inc n
      let made = c.createTrigger(orgId, TriggerSpec(name: "t" & $n, kind: "webhook", script: "return 1", concurrency: concurrency, enabled: true), getTime().toUnix())
      c.getTriggerById(made.id).row
    proc stateOf(run: string): string =
      c.query(%*[["SELECT state FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getStr
    proc setState(run, state: string) =
      discard c.execute(%*[["UPDATE runs SET state = ? WHERE id = ?", state, run]])
    proc resultOf(t: TriggerRow): string =
      c.getTriggerById(t.id).row.lastResult

    test "parallel starts a run for every firing, whatever the earlier ones are doing":
      let t = newTrigger("parallel")
      let a = co.fire(t, @[], getTime().toUnix())
      let b = co.fire(t, @[], getTime().toUnix())
      check a.started and b.started and a.runId != b.runId
      check stateOf(a.runId) == "RUNNING" and stateOf(b.runId) == "RUNNING"
    test "abort_newest starts none while an earlier run of the trigger has not ended, in any state that is not final":
      let t = newTrigger("abort_newest")
      let a = co.fire(t, @[], getTime().toUnix())
      check a.started
      for state in ["CREATED", "COMPILING", "QUEUED", "RUNNING", "WAITING"]:
        setState(a.runId, state)
        let f = co.fire(t, @[], getTime().toUnix())
        check not f.started and f.reason == "still_running"
      check resultOf(t) == "aborted the new firing: the previous run has not ended"
    test "abort_newest starts the next one when the earlier one has ended, in any final state":
      for state in ["OK", "FAILED", "ABORTED", "SKIPPED", "TIMED_OUT", "INFRASTRUCTURE_ERROR"]:
        let t = newTrigger("abort_newest")
        let a = co.fire(t, @[], getTime().toUnix())
        setState(a.runId, state)
        check co.fire(t, @[], getTime().toUnix()).started
    test "abort_newest looks at the runs of its own trigger only":
      let t1 = newTrigger("abort_newest")
      let t2 = newTrigger("abort_newest")
      check co.fire(t1, @[], getTime().toUnix()).started
      check co.fire(t2, @[], getTime().toUnix()).started
    test "abort_previous with no earlier run just starts":
      let t = newTrigger("abort_previous")
      let f = co.fire(t, @[], getTime().toUnix())
      check f.started and resultOf(t) == "started"
    test "abort_previous cancels the earlier run and starts the new one; the result says which":
      let t = newTrigger("abort_previous")
      let a = co.fire(t, @[], getTime().toUnix())
      let b = co.fire(t, @[], getTime().toUnix())
      check b.started and stateOf(a.runId) == "ABORTED" and stateOf(b.runId) == "RUNNING"
      check resultOf(t) == "started; aborted the earlier run " & a.runId
    test "abort_previous cancels every earlier run that has not ended, and leaves the ended ones and the runs of other triggers as they are":
      let t = newTrigger("abort_previous")
      let other = newTrigger("parallel")
      let o = co.fire(other, @[], getTime().toUnix())
      let a = co.fire(t, @[], getTime().toUnix())
      let done = co.fire(t, @[], getTime().toUnix())             # cancels a; done is the newest
      setState(done.runId, "OK")
      let w = co.fire(t, @[], getTime().toUnix())                # nothing to cancel: done ended
      setState(w.runId, "WAITING")
      let q = co.fire(t, @[], getTime().toUnix())                # cancels the waiting one
      check stateOf(a.runId) == "ABORTED" and stateOf(done.runId) == "OK" and stateOf(w.runId) == "ABORTED" and stateOf(q.runId) == "RUNNING"
      check stateOf(o.runId) == "RUNNING"

    test "D-63, D-68 a trigger of a project starts no run when the script cannot be had, and says why in its last result":
      inc n
      discard c.createGroup(orgId, "ci", getTime().toUnix())               # the folder the projects are in
      let pg = c.createProject(orgId, "ci/p" & $n, "https://example.test/r.git", getTime().toUnix())
      check pg.error == ""
      let made = c.createTrigger(orgId, TriggerSpec(name: "repo" & $n, kind: "webhook", groupPath: "ci/p" & $n, ref0: "main", concurrency: "parallel", enabled: true), getTime().toUnix(), pg.id)
      let t = c.getTriggerById(made.id).row
      check t.repository == "https://example.test/r.git" and t.ref0 == "main" and t.script == "" and t.groupPath == "ci/p" & $n      # the repository is the project's
      let before = c.query(%*[["SELECT COUNT(*) FROM runs WHERE trigger_id = ?", t.id]])["results"][0]["values"][0][0].getInt
      let f = co.fire(t, @[], getTime().toUnix(), commit = "abc123")       # there is no hub in this process: nobody can read the script
      check not f.started and f.status == 503 and f.reason == "script_unavailable"
      check resultOf(t).startsWith("not started: ")
      check c.query(%*[["SELECT COUNT(*) FROM runs WHERE trigger_id = ?", t.id]])["results"][0]["values"][0][0].getInt == before
    test "D-68 a project that has lost its repository gives its triggers nothing to read: they start nothing and say so":
      inc n
      discard c.createGroup(orgId, "ci", getTime().toUnix())
      let pg = c.createProject(orgId, "ci/q" & $n, "https://example.test/r.git", getTime().toUnix())
      let made = c.createTrigger(orgId, TriggerSpec(name: "lost" & $n, kind: "webhook", groupPath: "ci/q" & $n, concurrency: "parallel", enabled: true), getTime().toUnix(), pg.id)
      check c.setRepository(orgId, "ci/q" & $n, "") == ""
      let t = c.getTriggerById(made.id).row
      let f = co.fire(t, @[], getTime().toUnix())
      check not f.started and f.reason == "project_has_no_repository" and f.status == 409
      check "no repository" in resultOf(t)
