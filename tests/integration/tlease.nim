## RUN-008: a run is leased to one executor at a time with a token and an attempt; a call of an executor that does not hold the lease is refused
## (against a real rqlite). Needs CINIM_RQLITE_URL (a scratch rqlite); otherwise the suite is skipped.
import std/[unittest, json, os, times, strutils]
import common/rqlite
import core/[schema, scheduler, runlease]

let url = getEnv("CINIM_RQLITE_URL")
const master = "master"

suite "RUN-008 the lease of a run":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    proc attemptOf(run: string): int =
      c.query(%*[["SELECT lease_attempt FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getInt
    proc untilOf(run: string): int64 =
      c.query(%*[["SELECT lease_until FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getBiggestInt
    proc params(run, token: string): ExecutorResponse =
      handleCall(c, co, HostCall(run_id: run, lease_token: token, seq: 0, kind: "params", payload: cast[seq[byte]]("{}")), master)
    proc jobSh(run, token: string; seq = 1'u64): ExecutorResponse =
      handleCall(c, co, HostCall(run_id: run, lease_token: token, seq: seq, kind: "job_sh", numbered: true, step_no: uint32(seq),
        payload: cast[seq[byte]]("job-1\talpine\t\t\techo hi")), master)
    proc refused(r: ExecutorResponse): bool =
      r.body.kind == ExecutorResponseBodyKind.failure and r.body.failure.code == "lease_lost"
    proc answered(r: ExecutorResponse): bool = r.body.kind == ExecutorResponseBodyKind.result

    test "a run is leased to one executor; the second is told it is taken":
      let r = co.createRun("p", "return 1")
      let a = c.takeRunLease(master, r, "exec-a")
      check a.len > 0 and a.startsWith("1.")
      check c.takeRunLease(master, r, "exec-b") == ""
      check attemptOf(r) == 1 and untilOf(r) > getTime().toUnix()
    test "a run that is not RUNNING cannot be leased":
      let r = co.createRun("p", "return 1")
      discard c.execute(%*[["UPDATE runs SET state = 'SUCCEEDED' WHERE id = ?", r]])
      check c.takeRunLease(master, r, "exec-a") == ""
    test "the holder's calls are answered; a made-up token and the token of another run are refused":
      let r = co.createRun("p", "return 1")
      let other = co.createRun("p", "return 1")
      let tok = c.takeRunLease(master, r, "exec-a")
      let otherTok = c.takeRunLease(master, other, "exec-a")
      check params(r, tok).answered
      check params(r, "").refused
      check params(r, "1." & "0".repeat(64)).refused
      check params(r, otherTok).refused
      check params(r, tok).answered                       # the refusals did not harm the holder
    test "suspending the run gives the lease back, and the old token is worth nothing":
      let r = co.createRun("p", "return 1")
      let tok = c.takeRunLease(master, r, "exec-a")
      let resp = jobSh(r, tok)
      check resp.answered and resp.body.result.suspended
      check untilOf(r) == 0
      check params(r, tok).refused                         # given back
      check r notin c.leaseCandidates(r)                    # a step is in flight: not offered again until it is done
      discard c.execute(%*[["UPDATE steps SET state = 'SUCCEEDED' WHERE run_id = ?", r]])
      check r in c.leaseCandidates(r)                       # the step is done: the next executor may take it
      let b = c.takeRunLease(master, r, "exec-b")
      check b.startsWith("2.")
      check params(r, tok).refused                         # the first token is of attempt 1
      check params(r, b).answered
    test "a lease that ran out is taken by another executor, and the first one is refused when it comes back":
      let r = co.createRun("p", "return 1")
      let a = c.takeRunLease(master, r, "exec-a")
      discard c.execute(%*[["UPDATE runs SET lease_until = ? WHERE id = ?", getTime().toUnix() - 5, r]])
      check r in c.leaseCandidates(r)
      let b = c.takeRunLease(master, r, "exec-b")
      check b.startsWith("2.")
      check params(r, a).refused
      check params(r, b).answered
    test "a lease that ran out and was not taken goes on for its holder, and is renewed":
      let r = co.createRun("p", "return 1")
      let a = c.takeRunLease(master, r, "exec-a")
      discard c.execute(%*[["UPDATE runs SET lease_until = ? WHERE id = ?", getTime().toUnix() - 5, r]])
      check params(r, a).answered
      check untilOf(r) > getTime().toUnix() + 30
    test "the lease is written again only when half of it is gone":
      let r = co.createRun("p", "return 1")
      let a = c.takeRunLease(master, r, "exec-a")
      let first = untilOf(r)
      discard params(r, a)
      check untilOf(r) == first                            # no write for a call right after the grant
      discard c.execute(%*[["UPDATE runs SET lease_until = ? WHERE id = ?", getTime().toUnix() + 10, r]])
      discard params(r, a)
      check untilOf(r) > getTime().toUnix() + 50
    test "only the holder can end the run":
      let r = co.createRun("p", "return 1")
      let a = c.takeRunLease(master, r, "exec-a")
      let fin = proc (token: string): ExecutorResponse =
        handleFinish(c, FinishRun(run_id: r, state: RUN_STATE_SUCCEEDED, lease_token: token), master)
      check fin("").refused
      check fin("1." & "0".repeat(64)).refused
      check c.query(%*[["SELECT state FROM runs WHERE id = ?", r]])["results"][0]["values"][0][0].getStr == "RUNNING"
      check fin(a).answered
      check c.query(%*[["SELECT state FROM runs WHERE id = ?", r]])["results"][0]["values"][0][0].getStr == "SUCCEEDED"
      check untilOf(r) == 0
