## T-03: the core writes the run journal with a hash chain, keeps the newest hash with the run, and checks the chain before a run goes to an
## executor (against a real rqlite). Needs CINIM_RQLITE_URL (a scratch rqlite); otherwise the suite is skipped.
import std/[unittest, json, os, strutils, sequtils, options]
import common/rqlite
import core/[schema, scheduler, runlease, journalchain, journaldb, retrypolicy]

let url = getEnv("CINIM_RQLITE_URL")
const master = "master"

suite "T-03 the hash chain of the journal":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    proc stateOf(run: string): string =
      c.query(%*[["SELECT state FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getStr
    proc failCode(run: string): string =
      c.query(%*[["SELECT fail_code FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getStr
    proc leaseIt(run: string): Option[LeaseGranted] =
      grantLease(c, master, run, "exec-t", @[1])
    proc finishStep(run: string; ordinal: int) =
      ## what the controller's report does for a step that ended with code 0
      applyTransition(c, defaultPolicy(), PodTransition(step: StepRef(run_id: run, seq: uint32(ordinal), attempt: 1),
        state: STEP_STATE_SUCCEEDED, exit_code: 0, termination_reason: "ok"))
    proc runWithSteps(n: int): string =
      ## a run whose script has asked for `n` steps in turn, each answered: params at 0, then job_sh at 1..n
      let r = co.createRun("p", "return 1")
      var tok = c.takeRunLease(master, r, "exec-t")
      discard handleCall(c, co, HostCall(run_id: r, lease_token: tok, seq: 0, kind: "params", payload: cast[seq[byte]]("{}")), master)
      for i in 1 .. n:
        discard handleCall(c, co, HostCall(run_id: r, lease_token: tok, seq: uint64(i), kind: "job_sh", numbered: true, step_no: uint32(i),
          payload: cast[seq[byte]]("job-" & $i & "\talpine\t\t\techo " & $i)), master)
        discard c.execute(%*[["UPDATE steps SET state = 'RUNNING' WHERE run_id = ? AND ordinal = ?", r, i]])
        finishStep(r, i)
        tok = c.takeRunLease(master, r, "exec-t")
      r

    test "the records the core writes are chained, and the run keeps the newest hash":
      let r = runWithSteps(3)
      let rows = c.readRows(r)
      check rows.len == 4                                  # params and three steps
      check rows.allIt(it.hash.len == 64)
      check checkChain(rows, c.readTip(r)).verdict == cvOk
      check c.readTip(r) == rows[^1].hash
    test "the lease sends the records with their hashes":
      let r = runWithSteps(2)
      discard c.execute(%*[["UPDATE runs SET lease_until = 0 WHERE id = ?", r]])
      let resp = leaseIt(r)
      check resp.isSome
      let g = resp.get
      check g.journal.len == 3
      check g.journal.allIt(it.hash.len == 64)
    test "the same record twice is one record":
      let r = runWithSteps(1)
      check not c.appendRow(r, 1, "job_sh", "again", "0\n")
      check c.readRows(r).len == 2
      check checkChain(c.readRows(r), c.readTip(r)).verdict == cvOk
    test "a result changed in the database: the run does not go to an executor and ends with journal_corrupt":
      let r = runWithSteps(3)
      discard c.execute(%*[["UPDATE run_journal SET result = '0' || char(10) || 'x' WHERE run_id = ? AND seq = 2", r]])
      discard c.execute(%*[["UPDATE runs SET lease_until = 0 WHERE id = ?", r]])
      check leaseIt(r).isNone
      check stateOf(r) == "INFRASTRUCTURE_ERROR" and failCode(r) == "journal_corrupt"
    test "the newest records taken away (so that a step would be done again): found by the tip":
      let r = runWithSteps(3)
      discard c.execute(%*[["DELETE FROM run_journal WHERE run_id = ? AND seq = 3", r]])
      discard c.execute(%*[["UPDATE runs SET lease_until = 0 WHERE id = ?", r]])
      check leaseIt(r).isNone
      check failCode(r) == "journal_corrupt"
    test "a record forged into the journal is found":
      let r = runWithSteps(2)
      discard c.execute(%*[["INSERT INTO run_journal (run_id, seq, kind, fingerprint, payload, result, created_at, hash) VALUES (?, 3, 'job_sh', '', 'x', '0', '1', ?)",
        r, "a".repeat(64)]])
      discard c.execute(%*[["UPDATE runs SET lease_until = 0 WHERE id = ?", r]])
      check leaseIt(r).isNone
      check failCode(r) == "journal_corrupt"
    test "a journal without hashes is not adopted: the run does not go to an executor and ends with journal_corrupt":
      let r = co.createRun("p", "return 1")
      for i in 0 .. 2:
        discard c.execute(%*[["INSERT INTO run_journal (run_id, seq, kind, fingerprint, payload, result, created_at) VALUES (?, ?, 'job_sh', '', ?, '0', '1')",
          r, i, "p" & $i]])
      check leaseIt(r).isNone
      check stateOf(r) == "INFRASTRUCTURE_ERROR" and failCode(r) == "journal_corrupt"
