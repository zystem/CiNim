import std/unittest
import common/states
import core/[liveness, retrypolicy]

suite "liveness_timeout":
  let T = 300
  test "a step handed out recently, not yet heard from, is fine; after the timeout the Pod is deemed not started":
    let s = StepLiveness(state: ssStarting, claimedAt: 1000, shimN: 0)
    check judge(s, 1100, 0, T) == lOk
    check judge(s, 1300, 0, T) == lOk                       # exactly the timeout: not yet
    check judge(s, 1301, 0, T) == lStartTimeout
  test "a heard-from shim is fine while it keeps talking and silent after the timeout":
    let s = StepLiveness(state: ssRunning, claimedAt: 1000, shimN: 2, shimSeenAt: 2000)
    check judge(s, 2100, 0, T) == lOk
    check judge(s, 2301, 0, T) == lSilent
  test "a restart of core gives everyone a fresh timeout":
    let s = StepLiveness(state: ssRunning, claimedAt: 1000, shimN: 2, shimSeenAt: 2000)
    check judge(s, 5000, 4900, T) == lOk                    # core came back 100 s ago
    check judge(s, 5201, 4900, T) == lSilent
    let q = StepLiveness(state: ssStarting, claimedAt: 1000, shimN: 0)
    check judge(q, 5000, 4900, T) == lOk
    check judge(q, 5201, 4900, T) == lStartTimeout
  test "steps that are not in flight are never judged":
    for st in [ssPending, ssSucceeded, ssFailed, ssLost, ssCanceled, ssTimedOut]:
      check judge(StepLiveness(state: st, claimedAt: 1, shimN: 0), 99999, 0, T) == lOk
  test "a running step with no shim record is not a start timeout (the shim was heard from through another route)":
    check judge(StepLiveness(state: ssRunning, claimedAt: 1, shimN: 0), 99999, 0, T) == lOk

suite "profile settings":
  test "defaults are valid; ranges are enforced":
    check validate(defaultSettings()) == ""
    var s = defaultSettings()
    s.infraRetries = 21
    check validate(s) != ""
    s = defaultSettings()
    s.logMaxBytes = 1000
    check validate(s) != ""
    s.logMaxBytes = 0                                       # unlimited is allowed
    check validate(s) == ""
    s = defaultSettings()
    s.livenessTimeout = 10
    check validate(s) != ""
    s.livenessTimeout = 3600
    check validate(s) == ""
  test "spool and hold timeout have ranges too":
    var s = defaultSettings()
    s.logSpoolBytes = 1000
    check validate(s) != ""
    s.logSpoolBytes = 2'i64 shl 30
    check validate(s) != ""
    s = defaultSettings()
    s.logHoldTimeout = 5
    check validate(s) != ""
    s.logHoldTimeout = 20
    check validate(s) == ""
  test "the documented defaults":
    let d = defaultSettings()
    check d.infraRetries == 3 and d.logMaxBytes == 1073741824 and d.livenessTimeout == 300
    check d.logSpoolBytes == 10 * 1024 * 1024 and d.logHoldTimeout == 600
