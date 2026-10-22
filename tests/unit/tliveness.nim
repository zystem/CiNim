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
    for st in [ssPending, ssSucceeded, ssFailed, ssLost, ssAborted, ssTimedOut]:
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

suite "DAT-006 the artifact settings of an organisation":
  test "the quota is 0 (no limit) or 1 MiB..1 PiB, the retention 0 (the shard's) to 3650 days; the defaults are no quota and the shard's retention":
    check defaultSettings().artifactQuotaBytes == 0 and defaultSettings().artifactRetentionDays == 0
    var s = defaultSettings()
    for ok in [0'i64, 1024 * 1024, 50'i64 shl 30, 1'i64 shl 50]:
      s.artifactQuotaBytes = ok
      check validate(s) == ""
    for bad in [-1'i64, 1, 1024 * 1024 - 1, (1'i64 shl 50) + 1]:
      s.artifactQuotaBytes = bad
      check validate(s) != ""
    s = defaultSettings()
    for ok in [0, 1, 30, 3650]:
      s.artifactRetentionDays = ok
      check validate(s) == ""
    for bad in [-1, 3651]:
      s.artifactRetentionDays = bad
      check validate(s) != ""

suite "DAT-004 the cache settings of an organisation":
  test "the quota is 0 (the shard's), -1 (no limit) or 1 MiB..1 PiB, the retention 0 (the shard's), -1 (for ever) or 1..3650 days; the defaults are the shard's":
    check defaultSettings().cacheQuotaBytes == 0 and defaultSettings().cacheRetentionDays == 0
    var s = defaultSettings()
    for ok in [0'i64, -1, 1024 * 1024, 50'i64 shl 30, 1'i64 shl 50]:
      s.cacheQuotaBytes = ok
      check validate(s) == ""
    for bad in [-2'i64, 1, 1024 * 1024 - 1, (1'i64 shl 50) + 1]:
      s.cacheQuotaBytes = bad
      check validate(s) != ""
    s = defaultSettings()
    for ok in [0, -1, 1, 7, 3650]:
      s.cacheRetentionDays = ok
      check validate(s) == ""
    for bad in [-2, 3651]:
      s.cacheRetentionDays = bad
      check validate(s) != ""
