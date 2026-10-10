## RUN-008 (docs/conductors.md section 6): a run is leased to one executor at a time with a token and an attempt number; every call carries the token
## and the core refuses a call of an older attempt, so an executor that was believed lost and comes back cannot act. Pure.
import std/[unittest, strutils]
import core/runlease

const master = "core-secret-key"

suite "RUN-008 the lease token":
  test "it carries the attempt and is made again from the same inputs":
    let t = leaseToken(master, "run-1", 3)
    check t.startsWith("3.")
    check leaseToken(master, "run-1", 3) == t
    check leaseAttempt(t) == 3
  test "it differs by run, attempt and key, so a token cannot be used for another run or another time":
    let t = leaseToken(master, "run-1", 3)
    check leaseToken(master, "run-2", 3) != t
    check leaseToken(master, "run-1", 4) != t
    check leaseToken("other-key", "run-1", 3) != t
  test "what is not a token has no attempt":
    check leaseAttempt("") == 0
    check leaseAttempt("t-run-1") == 0           # the old placeholder of the executor
    check leaseAttempt("x.abc") == 0
    check leaseAttempt("0." & "a".repeat(64)) == 0

suite "RUN-008 who may take a run":
  test "a run is free when it was never leased, was released, or its lease ran out":
    check canTake(LeaseState(attempt: 0, until: 0), now = 1000)
    check canTake(LeaseState(attempt: 2, until: 0), now = 1000)            # released
    check canTake(LeaseState(attempt: 2, until: 999), now = 1000)          # ran out
    check not canTake(LeaseState(attempt: 2, until: 1000), now = 1000)     # exactly at the limit it is still held
    check not canTake(LeaseState(attempt: 2, until: 1060), now = 1000)

suite "RUN-008 who may call":
  let held = LeaseState(attempt: 2, until: 1060)
  test "the holder, with the token of the current attempt":
    check checkLease(master, "run-1", leaseToken(master, "run-1", 2), held, now = 1000) == lvOk
  test "the holder whose lease ran out, if nobody has taken the run since":
    check checkLease(master, "run-1", leaseToken(master, "run-1", 2), held, now = 5000) == lvOk
  test "an older attempt is stale, a made-up token is forged":
    check checkLease(master, "run-1", leaseToken(master, "run-1", 1), held, now = 1000) == lvStale
    check checkLease(master, "run-1", "2." & "0".repeat(64), held, now = 1000) == lvForged
    check checkLease(master, "run-1", "", held, now = 1000) == lvForged
    check checkLease(master, "run-2", leaseToken(master, "run-1", 2), held, now = 1000) == lvForged   # another run's token
  test "after the lease was given back the token is worth nothing":
    check checkLease(master, "run-1", leaseToken(master, "run-1", 2), LeaseState(attempt: 2, until: 0), now = 1000) == lvReleased
  test "an executor that was lost and comes back after another took the run is refused":
    var s = LeaseState(attempt: 1, until: 1060)
    let a = leaseToken(master, "run-1", 1)
    check checkLease(master, "run-1", a, s, now = 1000) == lvOk
    check canTake(s, now = 1100)                                         # A went quiet; its lease ran out
    s = LeaseState(attempt: 2, until: 1160)                              # B took the run
    let b = leaseToken(master, "run-1", 2)
    check checkLease(master, "run-1", a, s, now = 1110) == lvStale       # A comes back
    check checkLease(master, "run-1", b, s, now = 1110) == lvOk

suite "RUN-008 renewing":
  test "the lease is written again only when half of it is gone, so that traffic is not a write to the database each time":
    check not renewDue(LeaseState(attempt: 1, until: 1060), now = 1000)     # 60 s left
    check not renewDue(LeaseState(attempt: 1, until: 1060), now = 1030)     # 30 s left: exactly half
    check renewDue(LeaseState(attempt: 1, until: 1060), now = 1031)
    check renewDue(LeaseState(attempt: 1, until: 900), now = 1000)          # ran out: renewed by the next call of the holder
