## TRG-004: what a firing does when an earlier run of the trigger has not ended (against a real rqlite). `parallel` starts a run anyway, `cancel_newest` cancels the new firing (starts none) while an earlier run
## has not ended in any state that is not final, `cancel_previous` cancels the earlier runs of the same trigger and starts the new one. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times]
import common/rqlite
import core/[schema, scheduler, triggers]

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
      let made = c.createTrigger(orgId, TriggerSpec(name: "t" & $n, kind: "webhook", projectId: "p", script: "return 1", concurrency: concurrency, enabled: true), getTime().toUnix())
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
    test "cancel_newest starts none while an earlier run of the trigger has not ended, in any state that is not final":
      let t = newTrigger("cancel_newest")
      let a = co.fire(t, @[], getTime().toUnix())
      check a.started
      for state in ["CREATED", "COMPILING", "QUEUED", "RUNNING", "WAITING"]:
        setState(a.runId, state)
        let f = co.fire(t, @[], getTime().toUnix())
        check not f.started and f.reason == "still_running"
      check resultOf(t) == "cancelled the new firing: the previous run has not ended"
    test "cancel_newest starts the next one when the earlier one has ended, in any final state":
      for state in ["SUCCEEDED", "FAILED", "CANCELED", "SKIPPED", "TIMED_OUT", "INFRASTRUCTURE_ERROR"]:
        let t = newTrigger("cancel_newest")
        let a = co.fire(t, @[], getTime().toUnix())
        setState(a.runId, state)
        check co.fire(t, @[], getTime().toUnix()).started
    test "cancel_newest looks at the runs of its own trigger only":
      let t1 = newTrigger("cancel_newest")
      let t2 = newTrigger("cancel_newest")
      check co.fire(t1, @[], getTime().toUnix()).started
      check co.fire(t2, @[], getTime().toUnix()).started
    test "cancel_previous with no earlier run just starts":
      let t = newTrigger("cancel_previous")
      let f = co.fire(t, @[], getTime().toUnix())
      check f.started and resultOf(t) == "started"
    test "cancel_previous cancels the earlier run and starts the new one; the result says which":
      let t = newTrigger("cancel_previous")
      let a = co.fire(t, @[], getTime().toUnix())
      let b = co.fire(t, @[], getTime().toUnix())
      check b.started and stateOf(a.runId) == "CANCELED" and stateOf(b.runId) == "RUNNING"
      check resultOf(t) == "started; cancelled the earlier run " & a.runId
    test "cancel_previous cancels every earlier run that has not ended, and leaves the ended ones and the runs of other triggers as they are":
      let t = newTrigger("cancel_previous")
      let other = newTrigger("parallel")
      let o = co.fire(other, @[], getTime().toUnix())
      let a = co.fire(t, @[], getTime().toUnix())
      let done = co.fire(t, @[], getTime().toUnix())             # cancels a; done is the newest
      setState(done.runId, "SUCCEEDED")
      let w = co.fire(t, @[], getTime().toUnix())                # nothing to cancel: done ended
      setState(w.runId, "WAITING")
      let q = co.fire(t, @[], getTime().toUnix())                # cancels the waiting one
      check stateOf(a.runId) == "CANCELED" and stateOf(done.runId) == "SUCCEEDED" and stateOf(w.runId) == "CANCELED" and stateOf(q.runId) == "RUNNING"
      check stateOf(o.runId) == "RUNNING"
