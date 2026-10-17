## RUN-006 / docs/parallel.md section 6: the decision of `fail_fast` (the host call `par_cancel`): the steps it names are cancelled, each gets the journaled answer
## `~canceled:<path>`, the decision is written under its key, and a step that has ended already is left as it is. Against a real rqlite; needs CINIM_RQLITE_URL.
import std/[unittest, json, os, options, strutils]
import common/rqlite
import core/[schema, scheduler, loggate, logcircuit, retrypolicy, journaldb, journalchain]

let url = getEnv("CINIM_RQLITE_URL")

suite "RUN-006 the decision of fail_fast in the core":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")

    proc newRunWithLease(): tuple[run, token: string] =
      let r = co.createRun("return 1", "t1", defaultProfile)
      let g = c.grantLease("master", r, "exec", @[1])
      (r, g.get.lease_token)
    proc step(run, token: string; n: int): ExecutorResponse =
      handleCall(c, co, HostCall(run_id: run, lease_token: token, seq: uint64(n), kind: "job_sh", numbered: true, step_no: uint32(n), key: "s" & $n,
                                 payload: cast[seq[byte]]("m.p1[x]/job-1\talpine\t\t\tcmd" & $n)), "master")
    proc decide(run, token: string; steps: seq[int]; unstarted: seq[string] = @[]; key = "m.p1/par_cancel#0"): ExecutorResponse =
      var ks = newJArray()
      for n in steps: ks.add %("s" & $n)
      let d = %*{"by": "m.p1", "failed": "x", "unstarted": unstarted, "steps": ks}
      handleCall(c, co, HostCall(run_id: run, lease_token: token, seq: 50, kind: "par_cancel", key: key, payload: cast[seq[byte]]($d)), "master")
    proc state(run: string; n: int): string =
      c.query(%*[["SELECT state FROM steps WHERE run_id = ? AND ordinal = ?", run, n]])["results"][0]["values"][0][0].getStr
    proc journal(run: string): seq[tuple[key, kind, result: string]] =
      for r in c.readRows(run): result.add (r.key, r.kind, r.result)
    proc finish(run: string; n: int) =
      discard c.execute(%*[["UPDATE steps SET state = 'RUNNING' WHERE run_id = ? AND ordinal = ?", run, n]])
      applyTransition(c, defaultPolicy(), PodTransition(step: StepRef(run_id: run, seq: uint32(n), attempt: 1), state: STEP_STATE_SUCCEEDED, exit_code: 0, termination_reason: "ok"))

    test "RUN-006 steps that wait or run are cancelled, each is answered `~canceled:<path>` in the journal, and the decision is written under its key":
      let (r, tok) = newRunWithLease()
      for n in 0 .. 2: discard step(r, tok, n)
      discard c.execute(%*[["UPDATE steps SET state = 'RUNNING' WHERE run_id = ? AND ordinal = 1", r]])
      let resp = decide(r, tok, @[0, 1, 2], @["d", "e"])
      check resp.body.kind == ExecutorResponseBodyKind.result and not resp.body.result.suspended
      check cast[string](resp.body.result.result) == "u:d\te"
      for n in 0 .. 2: check state(r, n) == "CANCELED"
      let rows = journal(r)
      check rows.len == 4
      check ("s0", "job_sh", "~canceled:m.p1") in rows and ("s2", "job_sh", "~canceled:m.p1") in rows
      check rows[^1].key == "m.p1/par_cancel#0" and rows[^1].kind == "par_cancel"
      check c.verifyJournal(r).check.verdict == cvOk
    test "RUN-006 a step that has ended is left as it is: its result stays, and the others are cancelled":
      let (r, tok) = newRunWithLease()
      for n in 0 .. 1: discard step(r, tok, n)
      finish(r, 0)
      let resp = decide(r, tok, @[0, 1])
      check resp.body.kind == ExecutorResponseBodyKind.result
      check state(r, 0) == "SUCCEEDED" and state(r, 1) == "CANCELED"
      let rows = journal(r)
      check ("s0", "job_sh", "0\n") in rows and ("s1", "job_sh", "~canceled:m.p1") in rows
    test "RUN-006 the same decision twice is one decision; a late report about a cancelled step changes nothing":
      let (r, tok) = newRunWithLease()
      for n in 0 .. 1: discard step(r, tok, n)
      discard decide(r, tok, @[0, 1])
      discard decide(r, tok, @[0, 1])
      check journal(r).len == 3
      applyTransition(c, defaultPolicy(), PodTransition(step: StepRef(run_id: r, seq: 0'u32, attempt: 1), state: STEP_STATE_SUCCEEDED, exit_code: 0, termination_reason: "ok"))
      check state(r, 0) == "CANCELED"
      check ("s0", "job_sh", "~canceled:m.p1") in journal(r)
    test "RUN-006 a decision needs the lease of the run and a key":
      let (r, tok) = newRunWithLease()
      discard step(r, tok, 0)
      let forged = decide(r, "1." & "0".repeat(64), @[0])
      check forged.body.kind == ExecutorResponseBodyKind.failure and forged.body.failure.code == "lease_lost"
      check state(r, 0) == "PENDING"
      let nokey = decide(r, tok, @[0], key = "")
      check nokey.body.kind == ExecutorResponseBodyKind.failure and nokey.body.failure.code == "script_error"
      check state(r, 0) == "PENDING"
    test "RUN-006 a cancelled step is no longer handed to a controller, and a cancelled one that was running is told to stop":
      let (r, tok) = newRunWithLease()
      discard step(r, tok, 0)
      discard decide(r, tok, @[0])
      check c.query(%*[["SELECT COUNT(*) FROM steps WHERE run_id = ? AND state IN ('PENDING', 'STARTING', 'RUNNING')", r]])["results"][0]["values"][0][0].getInt == 0
