## PIP-015 failed-only (docs/parallel.md section 11), against a real rqlite: a run that ended FAILED is run again with only the steps that failed, in the same run. The
## journal only grows (its chain holds), the old answer of a step is superseded by a record of kind `retry`, and the new result is written under `s<n>~<retries>`.
## Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times]
import common/rqlite
import core/[schema, scheduler, journaldb, journalchain, retrypolicy]

let url = getEnv("CINIM_RQLITE_URL")

suite "PIP-015 running again only what failed":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    proc now(): int64 = getTime().toUnix()
    proc addStep(run: string; ordinal: int; state: string; exit = 0) =
      let jobId = newId()
      discard c.execute(%*[["INSERT OR IGNORE INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, ?, 'RUNNING', ?)", jobId, run, "job-" & $(ordinal + 1), defaultProfile]])
      discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at, exit_code, finished_at) " &
        "VALUES (?, ?, (SELECT id FROM jobs WHERE run_id = ? AND key = ?), ?, 'sh', ?, ?, 'alpine', ?, '', '1', ?, '1')", newId(), run, run, "job-" & $(ordinal + 1), ordinal, state, defaultProfile, "cmd" & $ordinal, exit]])
    proc payloadOf(ordinal: int): string = "job-" & $(ordinal + 1) & "\talpine\t\t\tcmd" & $ordinal
    proc journalStep(run: string; ordinal: int; exit: int; key = "") =
      discard c.appendRow(run, (if key.len > 0: key else: "s" & $ordinal), "job_sh", payloadOf(ordinal), $exit & "\n")
    proc setState(run, state: string) = discard c.execute(%*[["UPDATE runs SET state = ?, fail_code = 'script_error', fail_message = 'step failed' WHERE id = ?", state, run]])
    proc runState(run: string): string = c.query(%*[["SELECT state FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getStr
    proc stepRow(run: string; ordinal: int): tuple[state: string, attempt, retries: int] =
      let v = c.query(%*[["SELECT state, attempt, retries FROM steps WHERE run_id = ? AND ordinal = ?", run, ordinal]])["results"][0]["values"][0]
      (v[0].getStr, v[1].getInt, v[2].getInt)
    proc keys(run: string): seq[string] =
      for r in c.readRows(run): result.add r.key
    proc failedRun(): string =
      ## a run whose first step succeeded and whose second failed, and which ended FAILED
      let r = co.createRun("return 1", "t1", defaultProfile)
      addStep(r, 0, "OK")
      addStep(r, 1, "FAILED", 1)
      journalStep(r, 0, 0)
      journalStep(r, 1, 1)
      setState(r, "FAILED")
      r

    test "the run is RUNNING again, the step that failed waits for a new attempt, the one that succeeded is not touched, and the failure is forgotten":
      let r = failedRun()
      let done = c.retryRun(r, now())
      check done.outcome == roRetried and done.state == "RUNNING" and done.steps == @[1]
      check runState(r) == "RUNNING"
      check stepRow(r, 1) == (state: "PENDING", attempt: 2, retries: 1)
      check stepRow(r, 0) == (state: "OK", attempt: 1, retries: 0)
      check c.query(%*[["SELECT fail_code, fail_message FROM runs WHERE id = ?", r]])["results"][0]["values"][0] == %*["", ""]
    test "the journal only grows: the old answers stay, a record of kind retry names the key it supersedes, and the chain holds":
      let r = failedRun()
      discard c.retryRun(r, now())
      check keys(r) == @["s0", "s1", "retry#0"]
      let rows = c.readRows(r)
      check rows[2].kind == "retry" and parseJson(rows[2].payload) == %*["s1"]
      check c.verifyJournal(r).check.verdict == cvOk
    test "the new result of the step is written under s1~1, and the chain holds":
      let r = failedRun()
      discard c.retryRun(r, now())
      let attempt = stepRow(r, 1).attempt
      applyTransition(c, defaultPolicy(), PodTransition(step: StepRef(run_id: r, seq: 1, attempt: uint32(attempt)), state: STEP_STATE_OK, exit_code: 0, termination_reason: "ok"))
      check keys(r) == @["s0", "s1", "retry#0", "s1~1"]
      check c.readRows(r)[3].result == "0\n"
      check stepRow(r, 1).state == "OK"
      check c.verifyJournal(r).check.verdict == cvOk
    test "it can be done again: the second failure is s1~1, the second retry supersedes it, the result is s1~2":
      let r = failedRun()
      discard c.retryRun(r, now())
      applyTransition(c, defaultPolicy(), PodTransition(step: StepRef(run_id: r, seq: 1, attempt: 2), state: STEP_STATE_FAILED, exit_code: 1, termination_reason: "ok"))
      setState(r, "FAILED")
      check keys(r) == @["s0", "s1", "retry#0", "s1~1"]
      let again = c.retryRun(r, now())
      check again.outcome == roRetried
      check stepRow(r, 1) == (state: "PENDING", attempt: 3, retries: 2)
      check parseJson(c.readRows(r)[^1].payload) == %*["s1~1"]
      applyTransition(c, defaultPolicy(), PodTransition(step: StepRef(run_id: r, seq: 1, attempt: 3), state: STEP_STATE_OK, exit_code: 0, termination_reason: "ok"))
      check keys(r) == @["s0", "s1", "retry#0", "s1~1", "retry#1", "s1~2"]
      check c.verifyJournal(r).check.verdict == cvOk
    test "a step that was lost (no record of its own) is run again too, and the keys still agree":
      let r = co.createRun("return 1", "t1", defaultProfile)
      addStep(r, 0, "LOST", -1)
      setState(r, "INFRASTRUCTURE_ERROR")
      check c.retryRun(r, now()).outcome == roRetried
      check stepRow(r, 0) == (state: "PENDING", attempt: 2, retries: 1)
      applyTransition(c, defaultPolicy(), PodTransition(step: StepRef(run_id: r, seq: 0, attempt: 2), state: STEP_STATE_OK, exit_code: 0, termination_reason: "ok"))
      check "s0~1" in keys(r)
    test "asked twice, it is done once; a run that is not failed, one with nothing failed, one whose volume is gone, and one that is not there are refused":
      let r = failedRun()
      check c.retryRun(r, now()).outcome == roRetried
      check c.retryRun(r, now()).outcome == roNotRetryable                 # it is RUNNING now
      check keys(r) == @["s0", "s1", "retry#0"]
      let ok = co.createRun("return 1", "t1", defaultProfile)
      check c.retryRun(ok, now()).outcome == roNotRetryable                 # RUNNING
      setState(ok, "OK")
      check c.retryRun(ok, now()).outcome == roNotRetryable
      setState(ok, "ABORTED")
      check c.retryRun(ok, now()).outcome == roNotRetryable                 # a run that was cancelled on purpose is not run again
      let noStep = co.createRun("return 1", "t1", defaultProfile)
      addStep(noStep, 0, "OK")
      setState(noStep, "FAILED")
      check c.retryRun(noStep, now()).outcome == roNothingToRetry            # the script itself ended it
      let gone = failedRun()
      discard c.execute(%*[["UPDATE runs SET storage_released = 1 WHERE id = ?", gone]])
      check c.retryRun(gone, now()).outcome == roVolumeGone
      check c.retryRun("no-such-run", now()).outcome == roNotFound
