## RUN-006: cancelling a run (against a real rqlite). The run ends as CANCELED, its steps that have not ended are CANCELED, its lease is given back, the Pods of those
## steps are wanted no more (the controller removes them at its next poll), and a late report about such a step changes nothing. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, times]
import common/rqlite
import core/[schema, scheduler, retrypolicy]

let url = getEnv("CINIM_RQLITE_URL")

suite "RUN-006 cancelling a run":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    proc addStep(run: string; ordinal: int; state: string) =
      let jobId = newId()
      discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, ?, 'RUNNING', ?)", jobId, run, "j" & $ordinal, defaultProfile]])
      discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at) " &
        "VALUES (?, ?, ?, ?, 'sh', ?, ?, 'alpine', 'true', '', '1')", newId(), run, jobId, ordinal, state, defaultProfile]])
    proc stepState(run: string; ordinal: int): string =
      c.query(%*[["SELECT state FROM steps WHERE run_id = ? AND ordinal = ?", run, ordinal]])["results"][0]["values"][0][0].getStr
    proc runState(run: string): string =
      c.query(%*[["SELECT state FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getStr
    proc leaseUntil(run: string): int64 =
      c.query(%*[["SELECT lease_until FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getBiggestInt
    proc podOf(run: string; ordinal: int): PodInfo =
      PodInfo(step: StepRef(run_id: run, seq: uint32(ordinal), attempt: 1))

    test "the run and its steps that have not ended are cancelled, the lease is given back, a step that has ended stays as it was":
      let r = co.createRun("return 1")
      addStep(r, 0, "SUCCEEDED")
      addStep(r, 1, "RUNNING")
      addStep(r, 2, "STARTING")
      addStep(r, 3, "PENDING")
      discard c.execute(%*[["UPDATE runs SET lease_until = ? WHERE id = ?", getTime().toUnix() + 60, r]])
      let done = c.cancelRun(r, getTime().toUnix())
      check done.outcome == coCanceled and done.state == "CANCELED"
      check runState(r) == "CANCELED" and leaseUntil(r) == 0
      check stepState(r, 0) == "SUCCEEDED"
      for i in 1 .. 3: check stepState(r, i) == "CANCELED"
    test "another run is not touched":
      let a = co.createRun("return 1")
      let b = co.createRun("return 1")
      addStep(a, 0, "RUNNING")
      addStep(b, 0, "RUNNING")
      discard c.cancelRun(a, getTime().toUnix())
      check runState(b) == "RUNNING" and stepState(b, 0) == "RUNNING"
    test "a run that has ended is left as it is, a run that is not there is not found, and a second cancel says the run has ended":
      let r = co.createRun("return 1")
      discard c.execute(%*[["UPDATE runs SET state = 'SUCCEEDED' WHERE id = ?", r]])
      check c.cancelRun(r, getTime().toUnix()) == (coAlreadyFinished, "SUCCEEDED")
      check runState(r) == "SUCCEEDED"
      check c.cancelRun("no-such-run", getTime().toUnix()).outcome == coNotFound
      let q = co.createRun("return 1")
      check c.cancelRun(q, getTime().toUnix()).outcome == coCanceled
      check c.cancelRun(q, getTime().toUnix()) == (coAlreadyFinished, "CANCELED")
    test "the Pod of a cancelled step is wanted no more at once, the Pod of a step that is running is wanted":
      let r = co.createRun("return 1")
      addStep(r, 1, "RUNNING")
      addStep(r, 2, "RUNNING")
      discard c.cancelRun(r, getTime().toUnix())
      let other = co.createRun("return 1")
      addStep(other, 1, "RUNNING")
      let unwanted = c.unwantedPods(@[podOf(r, 1), podOf(r, 2), podOf(other, 1)])
      check unwanted.len == 2 and unwanted[0].run_id == r and unwanted[1].run_id == r
    test "a report about a cancelled step that arrives later (the Pod ended with a failure) changes neither the step nor the run":
      let r = co.createRun("return 1")
      addStep(r, 1, "RUNNING")
      discard c.cancelRun(r, getTime().toUnix())
      applyTransition(c, defaultPolicy(), PodTransition(step: StepRef(run_id: r, seq: 1, attempt: 1), state: STEP_STATE_FAILED, exit_code: 143, termination_reason: "ok"))
      check stepState(r, 1) == "CANCELED" and runState(r) == "CANCELED"
