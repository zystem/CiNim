## PIP-014: the lock of a job (core/joblocks.nim), against a real rqlite: one holder at a time, a list in the order of coming, the hand-over with the record in the journal,
## the depth of a job in a job, the release when a run ends or is cancelled, the sweep that heals what a crash cut short, the suspended run that is not led while it waits,
## and the limit on the runs of an organisation that have not ended. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, options, strutils, times]
import common/rqlite
import core/[schema, scheduler, joblocks, journaldb, runlease]

let url = getEnv("CINIM_RQLITE_URL")
const master = "master"

suite "PIP-014 locks of jobs":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let sfx = newId()[^8 .. ^1]
    var n = 0
    proc lockName(): string =
      inc n
      "stand-" & sfx & "-" & $n
    proc newRun(): string = co.createRun("return 1", "t1", defaultProfile)
    proc rowsOf(run: string): seq[string] =
      for r in c.readRows(run): result.add r.key & ":" & r.kind & ":" & r.payload
    proc now(): int64 = getTime().toUnix()
    proc leaseUntil(run: string): int64 =
      c.query(%*[["SELECT lease_until FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getBiggestInt
    proc setState(run, state: string) = discard c.execute(%*[["UPDATE runs SET state = ? WHERE id = ?", state, run]])
    proc waiters(name: string): int =
      c.query(%*[["SELECT count(*) FROM lock_waiters WHERE name = ?", name]])["results"][0]["values"][0][0].getInt

    test "a free lock is the run's at once, and the record of the call is in its journal":
      let a = newRun()
      let l = lockName()
      check c.acquire(a, defaultProfile, l, "lock#0", l, now())
      check c.holderOf(defaultProfile, l) == a
      check rowsOf(a) == @["lock#0:lock:" & l]
    test "a lock that is held makes the run wait: it is on the list, the lock stays with the holder, and the run's view says who holds it":
      let a = newRun()
      let b = newRun()
      let l = lockName()
      check c.acquire(a, defaultProfile, l, "lock#0", l, now())
      check not c.acquire(b, defaultProfile, l, "lock#0", l, now())
      check c.holderOf(defaultProfile, l) == a and waiters(l) == 1
      check rowsOf(b).len == 0
      let w = c.waitingFor(b)
      check w.waiting and w.name == l and w.heldBy == a
      check not c.waitingFor(a).waiting
    test "when the holder lets go the first waiter gets it, its record is written, and it leaves the list; the next waits on":
      let a = newRun()
      let b = newRun()
      let d = newRun()
      let l = lockName()
      discard c.acquire(a, defaultProfile, l, "lock#0", l, now())
      check not c.acquire(b, defaultProfile, l, "lock#0", l, now())
      check not c.acquire(d, defaultProfile, l, "lock#0", l, now())
      c.release(a, defaultProfile, l, now())
      check c.holderOf(defaultProfile, l) == b and waiters(l) == 1
      check rowsOf(b) == @["lock#0:lock:" & l] and rowsOf(d).len == 0
      c.release(b, defaultProfile, l, now())
      check c.holderOf(defaultProfile, l) == d and waiters(l) == 0
      check rowsOf(d) == @["lock#0:lock:" & l]
      c.release(d, defaultProfile, l, now())
      check c.holderOf(defaultProfile, l) == ""
    test "the list keeps the order of coming for many waiters":
      let l = lockName()
      let holder = newRun()
      discard c.acquire(holder, defaultProfile, l, "lock#0", l, now())
      var line: seq[string]
      for i in 1 .. 6:
        let r = newRun()
        line.add r
        check not c.acquire(r, defaultProfile, l, "lock#0", l, now())
      var cur = holder
      for next in line:
        c.release(cur, defaultProfile, l, now())
        check c.holderOf(defaultProfile, l) == next
        cur = next
    test "a job in a job of the same run does not wait for itself: it is held twice and let go twice":
      let a = newRun()
      let b = newRun()
      let l = lockName()
      check c.acquire(a, defaultProfile, l, "lock#0", l, now())
      check c.acquire(a, defaultProfile, l, "lock#1", l, now())
      check not c.acquire(b, defaultProfile, l, "lock#0", l, now())
      c.release(a, defaultProfile, l, now())
      check c.holderOf(defaultProfile, l) == a and waiters(l) == 1        # one level is still held
      c.release(a, defaultProfile, l, now())
      check c.holderOf(defaultProfile, l) == b
    test "the same call twice is one hold: the record exists already":
      let a = newRun()
      let l = lockName()
      check c.acquire(a, defaultProfile, l, "lock#0", l, now())
      c.release(a, defaultProfile, l, now())
      check c.acquire(a, defaultProfile, l, "lock#0", l, now())          # asked again (a replay that was cut): granted, no second record
      check rowsOf(a) == @["lock#0:lock:" & l]
    test "locks of other names and of other organisations are independent":
      let a = newRun()
      let b = newRun()
      let l1 = lockName()
      let l2 = lockName()
      check c.acquire(a, defaultProfile, l1, "lock#0", l1, now())
      check c.acquire(b, defaultProfile, l2, "lock#0", l2, now())
      check c.acquire(b, "another-organisation-profile", l1, "lock#1", l1, now())
    test "a run that ends gives back what it held and leaves the list; the next waiter gets the lock":
      let a = newRun()
      let b = newRun()
      let d = newRun()
      let l = lockName()
      discard c.acquire(a, defaultProfile, l, "lock#0", l, now())
      discard c.acquire(b, defaultProfile, l, "lock#0", l, now())
      discard c.acquire(d, defaultProfile, l, "lock#0", l, now())
      c.releaseRun(b, now())                                             # b was waiting: it is off the list
      check waiters(l) == 1 and c.holderOf(defaultProfile, l) == a
      c.releaseRun(a, now())
      check c.holderOf(defaultProfile, l) == d
    test "cancelling a run lets go of its lock and hands it on":
      let a = newRun()
      let b = newRun()
      let l = lockName()
      discard c.acquire(a, defaultProfile, l, "lock#0", l, now())
      discard c.acquire(b, defaultProfile, l, "lock#0", l, now())
      check c.cancelRun(a, now()).outcome == coCanceled
      check c.holderOf(defaultProfile, l) == b
    test "the sweep: a holder that has ended without saying so (lost, infrastructure error) is let go, a waiter that has ended leaves the list":
      let a = newRun()
      let b = newRun()
      let d = newRun()
      let l = lockName()
      discard c.acquire(a, defaultProfile, l, "lock#0", l, now())
      discard c.acquire(b, defaultProfile, l, "lock#0", l, now())
      discard c.acquire(d, defaultProfile, l, "lock#0", l, now())
      setState(b, "INFRASTRUCTURE_ERROR")
      setState(a, "FAILED")
      c.settle(now())
      check c.holderOf(defaultProfile, l) == d and waiters(l) == 0
      check rowsOf(d) == @["lock#0:lock:" & l]
    test "the sweep completes a hand-over that a crash cut short: the lock is the waiter's but its record and its place on the list are still there":
      let a = newRun()
      let b = newRun()
      let l = lockName()
      discard c.acquire(a, defaultProfile, l, "lock#0", l, now())
      discard c.acquire(b, defaultProfile, l, "lock#0", l, now())
      discard c.execute(%*[["UPDATE run_locks SET run_id = ? WHERE profile_id = ? AND name = ?", b, defaultProfile, l]])      # the swap was done, the rest not
      c.settle(now())
      check c.holderOf(defaultProfile, l) == b and waiters(l) == 0
      check rowsOf(b) == @["lock#0:lock:" & l]
    test "the sweep gives a lock that has no holder to the first waiter":
      let a = newRun()
      let b = newRun()
      let l = lockName()
      discard c.acquire(a, defaultProfile, l, "lock#0", l, now())
      discard c.acquire(b, defaultProfile, l, "lock#0", l, now())
      discard c.execute(%*[["DELETE FROM run_locks WHERE profile_id = ? AND name = ?", defaultProfile, l]])
      c.settle(now())
      check c.holderOf(defaultProfile, l) == b

    # ---- the host calls
    proc leased(run: string): tuple[token: string, call: proc (kind, payload, key: string): ExecutorResponse] =
      let tok = c.takeRunLease(master, run, "exec")
      (tok, proc (kind, payload, key: string): ExecutorResponse =
        handleCall(c, co, HostCall(run_id: run, lease_token: tok, seq: 0, kind: kind, key: key, payload: cast[seq[byte]](payload)), master))
    proc suspended(r: ExecutorResponse): bool =
      r.body.kind == ExecutorResponseBodyKind.result and r.body.result.suspended
    proc answered(r: ExecutorResponse): bool =
      r.body.kind == ExecutorResponseBodyKind.result and not r.body.result.suspended

    test "the host call lock answers at once for a free lock, suspends the run for a held one (its lease is given back), and unlock hands it on":
      let a = newRun()
      let b = newRun()
      let l = lockName()
      let ha = leased(a)
      check answered(ha.call("lock", l, "lock#0"))
      let hb = leased(b)
      let waitAnswer = hb.call("lock", l, "lock#0")
      check suspended(waitAnswer)
      check leaseUntil(b) > 0                           # pending: the executor gives the lease back itself when no branch can go on
      check answered(hb.call("park", "", ""))
      check leaseUntil(b) == 0
      check answered(ha.call("unlock", l, "unlock#0"))
      check c.holderOf(defaultProfile, l) == b
      check rowsOf(b) == @["lock#0:lock:" & l]
      check rowsOf(a) == @["lock#0:lock:" & l, "unlock#0:unlock:" & l]
    test "a run that waits for a lock is not given to a conductor; when the lock is its turn it is":
      let a = newRun()
      let b = newRun()
      let l = lockName()
      let ha = leased(a)
      discard ha.call("lock", l, "lock#0")
      let hb = leased(b)
      check suspended(hb.call("lock", l, "lock#0"))
      discard hb.call("park", "", "")
      var got: seq[string]
      for g in c.leaseForConductor(defaultProfile, master, "cond-t", @[1], 50): got.add g.run_id
      check b notin got
      discard ha.call("unlock", l, "unlock#0")
      got.setLen 0
      for g in c.leaseForConductor(defaultProfile, master, "cond-t", @[1], 50): got.add g.run_id
      check b in got
    test "a lock without a name that is one, or a call without its key, is refused":
      let a = newRun()
      let h = leased(a)
      for bad in ["", "a b", "x/y", "n".repeat(65)]:
        let r = h.call("lock", bad, "lock#0")
        check r.body.kind == ExecutorResponseBodyKind.failure and r.body.failure.code == "script_error"
      let nokey = h.call("lock", "stand", "")
      check nokey.body.kind == ExecutorResponseBodyKind.failure
    test "finishing a run lets go of its lock":
      let a = newRun()
      let b = newRun()
      let l = lockName()
      let ha = leased(a)
      discard ha.call("lock", l, "lock#0")
      discard c.acquire(b, defaultProfile, l, "lock#0", l, now())
      discard handleFinish(c, FinishRun(run_id: a, state: RUN_STATE_SUCCEEDED, lease_token: ha.token), master)
      check c.holderOf(defaultProfile, l) == b

    # ---- who is in the locks
    test "the view of a lock names the job that holds it (the run and the job in it) and the jobs that wait, in the order they will get it":
      let a = newRun()
      let b = newRun()
      let d = newRun()
      let l = lockName()
      let ha = leased(a)
      check answered(ha.call("lock", l & "\tjob-2", "lock#0"))
      let hb = leased(b)
      check suspended(hb.call("lock", l & "\tjob-1", "lock#0"))
      let hd = leased(d)
      check suspended(hd.call("lock", l & "\tjob-3", "lock#0"))
      let v = c.lockView(defaultProfile, l)
      check v.len == 1 and v[0]["name"].getStr == l
      check v[0]["holder"]["run_id"].getStr == a and v[0]["holder"]["job"].getStr == "job-2" and v[0]["holder"]["depth"].getInt == 1
      check v[0]["holder"]["run_state"].getStr == "RUNNING"
      check v[0]["waiting"].len == 2
      check v[0]["waiting"][0]["run_id"].getStr == b and v[0]["waiting"][0]["job"].getStr == "job-1" and v[0]["waiting"][0]["place"].getInt == 1
      check v[0]["waiting"][1]["run_id"].getStr == d and v[0]["waiting"][1]["job"].getStr == "job-3" and v[0]["waiting"][1]["place"].getInt == 2
      discard ha.call("unlock", l, "unlock#0")
      let after = c.lockView(defaultProfile, l)
      check after[0]["holder"]["run_id"].getStr == b and after[0]["holder"]["job"].getStr == "job-1"      # the job travels with the hand-over
      check after[0]["waiting"].len == 1 and after[0]["waiting"][0]["place"].getInt == 1
    test "the view without a name lists every lock that is held or waited for, and not a lock that nobody has":
      let a = newRun()
      let l1 = lockName()
      let l2 = lockName()
      discard c.acquire(a, defaultProfile, l1, "lock#0", l1 & "\tjob-1", now(), "job-1")
      discard c.acquire(a, defaultProfile, l2, "lock#1", l2 & "\tjob-1", now(), "job-1")
      var names: seq[string]
      for e in c.lockView(defaultProfile): names.add e["name"].getStr
      check l1 in names and l2 in names
      c.release(a, defaultProfile, l1, now())
      names.setLen 0
      for e in c.lockView(defaultProfile): names.add e["name"].getStr
      check l1 notin names and l2 in names
      check c.lockView(defaultProfile, l1).len == 0
      check c.lockView("another-organisation-profile-" & sfx).len == 0

    # ---- the limit
    test "an organisation with the most runs that have not ended already has no room for another; the ended ones do not count, nor other organisations":
      let was = maxUnfinishedRuns
      defer: maxUnfinishedRuns = was
      let profile = "limit-profile-" & sfx
      maxUnfinishedRuns = 3
      check not c.queueIsFull(profile)
      var runs: seq[string]
      for i in 1 .. 3: runs.add co.createRun("return 1", "t1", profile)
      check c.queueIsFull(profile)
      check not c.queueIsFull("limit-profile-other-" & sfx)
      setState(runs[0], "SUCCEEDED")
      check not c.queueIsFull(profile)
      let again = co.createRun("return 1", "t1", profile)
      check c.queueIsFull(profile)
      setState(again, "CANCELED")
      check not c.queueIsFull(profile)
    test "the limit is 65000 unless the environment says otherwise":
      check maxUnfinishedRuns == 65000
