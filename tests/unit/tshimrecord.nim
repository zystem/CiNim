## D-29: reconciling the shim's state from two sources (pure judgement; the SQL is exercised by the integration test).
import std/[unittest, options]
import common/shimstate
import core/shimrecord

proc st(n: int; ev: ShimEvent; attempt = 1): ShimState =
  ShimState(run: "s1_r", seq: 0, attempt: attempt, n: n, event: ev, phase: phaseAfter[ev], cmdStarted: ev != seStarted)

suite "judging a state against what is stored":
  test "the first state is applied":
    check judge(none(ShimState), st(1, seStarted), "s1_r", 0, 1) == jApply
  test "a later consistent event is applied":
    check judge(some st(1, seStarted), st(2, seCommandStarted), "s1_r", 0, 1) == jApply
    check judge(some st(2, seCommandStarted), st(6, seLogsDelivered), "s1_r", 0, 1) == jApply     # events in between were not seen
  test "repeats and old news change nothing - whichever path brings them":
    check judge(some st(4, seCommandExited), st(4, seCommandExited), "s1_r", 0, 1) == jStale
    check judge(some st(4, seCommandExited), st(2, seCommandStarted), "s1_r", 0, 1) == jStale
  test "an event that cannot follow the stored one is reported, not applied":
    check judge(some st(4, seCommandExited), st(5, seCommandStarted), "s1_r", 0, 1) == jInconsistent
    check judge(some st(8, seDone), st(9, seStarted), "s1_r", 0, 1) == jInconsistent
  test "a state about another attempt or step is ignored":
    check judge(none(ShimState), st(1, seStarted, attempt = 1), "s1_r", 0, 2) == jWrongAttempt
    check judge(none(ShimState), st(1, seStarted), "s1_other", 0, 1) == jWrongAttempt
    check judge(none(ShimState), st(1, seStarted), "s1_r", 3, 1) == jWrongAttempt
  test "two sources in any order converge on the same state":
    let a = st(2, seCommandStarted)
    let b = st(5, seCommandExited)
    for order in [@[a, b], @[b, a], @[a, b, a], @[b, b, a, b]]:
      var held = none(ShimState)
      for s in order:
        if judge(held, s, "s1_r", 0, 1) == jApply: held = some s
      check held.get.n == 5
