## RUN-009 / docs/conductors.md section 5: how many conductors an organisation needs, which one is which, and which idle ones the core drains. Pure.
import std/[unittest, options, strutils]
import common/conductorplan
import core/retrypolicy

suite "RUN-009 the number of conductors":
  test "at least conductor_min, even with nothing to do":
    check desiredConductors(0, 0, 10, 1, 20) == 1
    check desiredConductors(0, 0, 10, 0, 20) == 0          # scale to zero
    check desiredConductors(0, 0, 10, 2, 20) == 2
  test "one conductor per runs_per_conductor runs, rounded up":
    check desiredConductors(1, 0, 10, 0, 20) == 1
    check desiredConductors(10, 0, 10, 0, 20) == 1
    check desiredConductors(11, 0, 10, 0, 20) == 2
    check desiredConductors(5, 0, 2, 0, 20) == 3
  test "runs that wait count too, but never more than pod_limit runs are active, so never more than ceil(pod_limit / per) conductors":
    check desiredConductors(8, 8, 10, 0, 20) == 2
    check desiredConductors(0, 500, 10, 0, 20) == 2         # 500 waiting runs, 20 may be active: 2 conductors
    check desiredConductors(0, 500, 10, 0, 25) == 3
  test "conductor_min above the maximum is cut to the maximum":
    check desiredConductors(0, 0, 10, 9, 20) == 2
  test "a degenerate runs_per_conductor does not divide by zero":
    check desiredConductors(5, 0, 0, 0, 20) >= 1

suite "RUN-009 conductor names":
  test "cond-<n> and back":
    check conductorId(3) == "cond-3"
    check conductorNumber("cond-3") == some(3)
    check conductorNumber("cond-0").isNone
    check conductorNumber("cond-x").isNone
    check conductorNumber("c-hand").isNone
    check conductorNumber("cond-").isNone

suite "RUN-009 draining idle conductors":
  proc cs(n: int; idleSince: float; draining = false): CondState = CondState(id: conductorId(n), idleSince: idleSince, draining: draining)
  test "a conductor above the wanted number that has had no run for the idle time is drained":
    check drainTargets(@[cs(1, 0.0), cs(2, 100.0), cs(3, 100.0)], desired = 2, now = 500.0, idleSeconds = 300.0) == @["cond-3"]
  test "not before the idle time, not while it holds a run, not twice":
    check drainTargets(@[cs(3, 400.0)], 2, 500.0, 300.0).len == 0
    check drainTargets(@[cs(3, 0.0)], 2, 500.0, 300.0).len == 0        # idleSince 0: it holds a run
    check drainTargets(@[cs(3, 100.0, draining = true)], 2, 500.0, 300.0).len == 0
  test "a conductor that is not one of ours by name is left alone":
    check drainTargets(@[CondState(id: "c-hand", idleSince: 1.0)], 0, 1000.0, 300.0).len == 0
  test "conductors up to the wanted number are never drained":
    check drainTargets(@[cs(1, 1.0), cs(2, 1.0)], 2, 1000.0, 300.0).len == 0

suite "RUN-009 the settings of the conductors":
  test "defaults: 10 runs per conductor, one warm conductor":
    let d = defaultSettings()
    check d.runsPerConductor == 10 and d.conductorMin == 1
    check validate(d) == ""
  test "runs_per_conductor 1..100 and conductor_min 0..the most conductors the pod_limit can need":
    var s = defaultSettings()
    s.runsPerConductor = 0
    check "runs_per_conductor" in validate(s)
    s.runsPerConductor = 101
    check "runs_per_conductor" in validate(s)
    s = defaultSettings()
    s.conductorMin = -1
    check "conductor_min" in validate(s)
    s.conductorMin = 3                    # pod_limit 20, 10 per conductor: at most 2
    check "conductor_min" in validate(s)
    s.conductorMin = 2
    check validate(s) == ""
