## PIP-003 / docs/parallel.md section 3: a step has the number the executor gives it (from the table), which need not be its place in the journal; the result of the
## step is written at its place, and the table is kept with the run. Against a real rqlite; needs CINIM_RQLITE_URL (a scratch rqlite), otherwise the suite is skipped.
import std/[unittest, json, os, options, strutils]
import common/rqlite
import core/[schema, scheduler, loggate, logcircuit, retrypolicy, journaldb, journalchain]

let url = getEnv("CINIM_RQLITE_URL")

suite "PIP-003 the number of a step and its place in the journal":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")

    proc newRunWithLease(): tuple[run, token: string] =
      let r = co.createRun("p", "return 1", "t1", defaultProfile)
      let g = c.grantLease("master", r, "exec", @[1])
      (r, g.get.lease_token)

    proc jobSh(run, token: string; seq: int; numbered: bool; stepNo = 0; key = "job-1"): HostCall =
      HostCall(run_id: run, lease_token: token, seq: uint64(seq), kind: "job_sh", numbered: numbered, step_no: uint32(stepNo),
               payload: cast[seq[byte]](key & "\talpine\t\t\techo hi"))

    proc stepRow(run: string; ordinal: int): JsonNode =
      let v = c.query(%*[["SELECT ordinal, journal_seq, state FROM steps WHERE run_id = ? AND ordinal = ?", run, ordinal]])["results"][0]{"values"}
      if v == nil: newJArray() else: v

    proc finish(run: string; ordinal: int) =
      discard c.execute(%*[["UPDATE steps SET state = 'RUNNING' WHERE run_id = ? AND ordinal = ?", run, ordinal]])
      applyTransition(c, defaultPolicy(), PodTransition(step: StepRef(run_id: run, seq: uint32(ordinal), attempt: 1),
                                                         state: STEP_STATE_SUCCEEDED, exit_code: 0, termination_reason: "ok"))

    test "a numbered step has the number it was given, and remembers its place in the journal":
      let (r, tok) = newRunWithLease()
      let resp = handleCall(c, co, jobSh(r, tok, 3, true, stepNo = 10), "master")
      check resp.body.kind == ExecutorResponseBodyKind.result and resp.body.result.suspended
      let row = stepRow(r, 10)
      check row.len == 1 and row[0][0].getInt == 10 and row[0][1].getInt == 3
      check stepRow(r, 3).len == 0                     # nothing at the place number
    test "the result of a numbered step is written at its place in the journal, and the chain holds":
      let (r, tok) = newRunWithLease()
      discard handleCall(c, co, jobSh(r, tok, 0, true, stepNo = 0, key = "job-1"), "master")
      finish(r, 0)
      let tok2 = c.takeRunLease("master", r, "exec")
      discard handleCall(c, co, jobSh(r, tok2, 1, true, stepNo = 10, key = "job-2"), "master")
      finish(r, 10)
      let rows = c.readRows(r)
      check rows.len == 2 and rows[0].seq == 0 and rows[1].seq == 1          # positions, not numbers
      check c.verifyJournal(r).check.verdict == cvOk
    test "a step without a number is refused: an executor from before the tables is too old, and nothing is made":
      let (r, tok) = newRunWithLease()
      let resp = handleCall(c, co, jobSh(r, tok, 4, false), "master")
      check resp.body.kind == ExecutorResponseBodyKind.failure and resp.body.failure.code == "executor_too_old"
      check c.query(%*[["SELECT COUNT(*) FROM steps WHERE run_id = ?", r]])["results"][0]["values"][0][0].getInt == 0
      check c.query(%*[["SELECT COUNT(*) FROM jobs WHERE run_id = ?", r]])["results"][0]["values"][0][0].getInt == 0
    test "the same numbered call twice is one step":
      let (r, tok) = newRunWithLease()
      discard handleCall(c, co, jobSh(r, tok, 0, true, stepNo = 7), "master")
      discard handleCall(c, co, jobSh(r, tok, 0, true, stepNo = 7), "master")
      check c.query(%*[["SELECT COUNT(*) FROM steps WHERE run_id = ?", r]])["results"][0]["values"][0][0].getInt == 1

suite "PIP-003 the table is kept with the run":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    proc tableCall(run, token, text: string): HostCall =
      HostCall(run_id: run, lease_token: token, seq: 0, kind: "table", payload: cast[seq[byte]](text))

    test "the table sent by the executor is stored once and goes with every lease of the run":
      let r = co.createRun("p", "return 1", "t1", defaultProfile)
      let g = c.grantLease("master", r, "exec", @[1]).get
      check g.step_table == ""                          # nothing yet: the executor makes it
      let resp = handleCall(c, co, tableCall(r, g.lease_token, "{\"v\":1,\"b\":[[3,0,1,1]]}"), "master")
      check resp.body.kind == ExecutorResponseBodyKind.result and not resp.body.result.suspended
      discard c.execute(%*[["UPDATE runs SET lease_until = 0 WHERE id = ?", r]])
      let again = c.grantLease("master", r, "exec", @[1]).get
      check again.step_table == "{\"v\":1,\"b\":[[3,0,1,1]]}"
    test "the first table stays: a second one is answered and ignored":
      let r = co.createRun("p", "return 1", "t1", defaultProfile)
      let g = c.grantLease("master", r, "exec", @[1]).get
      discard handleCall(c, co, tableCall(r, g.lease_token, "FIRST"), "master")
      discard handleCall(c, co, tableCall(r, g.lease_token, "SECOND"), "master")
      discard c.execute(%*[["UPDATE runs SET lease_until = 0 WHERE id = ?", r]])
      check c.grantLease("master", r, "exec", @[1]).get.step_table == "FIRST"
    test "only the holder of the lease may send it":
      let r = co.createRun("p", "return 1", "t1", defaultProfile)
      discard c.grantLease("master", r, "exec", @[1])
      let resp = handleCall(c, co, tableCall(r, "forged", "X"), "master")
      check resp.body.kind == ExecutorResponseBodyKind.failure and resp.body.failure.code == "lease_lost"
    test "a table that is too large is refused":
      let r = co.createRun("p", "return 1", "t1", defaultProfile)
      let g = c.grantLease("master", r, "exec", @[1]).get
      let resp = handleCall(c, co, tableCall(r, g.lease_token, 'x'.repeat(70_000)), "master")
      check resp.body.kind == ExecutorResponseBodyKind.failure
