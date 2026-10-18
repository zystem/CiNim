## RUN-013: the liveness of the core sees a thread that is alive and not moving.
import std/[unittest, json]
import core/health

suite "RUN-013 the threads of the core are watched":
  setup: resetBeats()
  test "nothing has started: nothing is stuck, and the probe says ok":
    check stuck(1000.0).len == 0
    check livenessJson(1000.0).ok
  test "a thread that goes round is not stuck, however long ago it started":
    beatAt(bLogIngest, 1000.0)
    check stuck(1050.0).len == 0
    beatAt(bLogIngest, 1100.0)
    check stuck(1200.0).len == 0
  test "a thread that stopped going round is found when its limit is passed, by name, and the others are not":
    beatAt(bLogIngest, 1000.0)
    beatAt(bWatchdog, 1000.0)
    let s = stuck(1000.0 + 130.0)
    check s.len == 1 and s[0].name == "log-ingest" and s[0].ageSeconds > 120.0         # the watchdog has 300 s
    let live = livenessJson(1000.0 + 130.0)
    check not live.ok and live.body["status"].getStr == "stuck" and live.body["threads"][0]["thread"].getStr == "log-ingest"
  test "the limit of a thread that does slow work is longer: a reconciler pass of ten minutes is not a stuck thread":
    beatAt(bReconciler, 1000.0)
    check stuck(1000.0 + 600.0).len == 0
    check stuck(1000.0 + 1000.0).len == 1
  test "a round after the stop is a thread that moves again":
    beatAt(bStepReport, 1000.0)
    check stuck(1200.0).len == 1
    beatAt(bStepReport, 1200.0)
    check stuck(1210.0).len == 0
