## STO-006 / docs/parallel.md section 11: how long the volume of a failed run is kept - 10 minutes by default; not before the core has been up that long (a core that
## comes back after a stop must not delete at once what it could not offer for a retry); a minute when the organisation's storage is short of space. Pure.
import std/[unittest, options]
import common/quantity
import core/runstorage

suite "STO-006 quantities of Kubernetes":
  test "binary and decimal suffixes":
    check parseQuantity("500Gi") == some(500'u64 * 1024 * 1024 * 1024)
    check parseQuantity("100Mi") == some(100'u64 * 1024 * 1024)
    check parseQuantity("1Ti") == some(1'u64 shl 40)
    check parseQuantity("2Ki") == some(2048'u64)
    check parseQuantity("1G") == some(1_000_000_000'u64)
    check parseQuantity("512M") == some(512_000_000'u64)
    check parseQuantity("3k") == some(3000'u64)
    check parseQuantity("1024") == some(1024'u64)
    check parseQuantity("0") == some(0'u64)
  test "what is not a quantity of bytes is none":
    for bad in ["", "Gi", "12 Gi", "-1Gi", "1.5Gi", "1x", "1e3", "5m"]:
      check parseQuantity(bad).isNone

suite "STO-006 pressure on the storage of an organisation":
  setup:
    resetPressure()
  test "the storage is under pressure when less than 15 % is free, and stays so until more than 20 % is free":
    notePressure("p", 80, 100)
    check not underPressure("p")                 # 20 % free: not yet
    notePressure("p", 86, 100)
    check underPressure("p")                     # 14 % free
    notePressure("p", 82, 100)
    check underPressure("p")                     # 18 % free: between the two thresholds, as it was
    notePressure("p", 79, 100)
    check not underPressure("p")                 # 21 % free
    notePressure("p", 82, 100)
    check not underPressure("p")                 # between the two thresholds, as it was
  test "an organisation's pressure is its own":
    notePressure("a", 95, 100)
    check underPressure("a") and not underPressure("b")
  test "a report without a quota (hard 0) says nothing":
    notePressure("p", 95, 100)
    notePressure("p", 0, 0)
    check underPressure("p")

suite "STO-006 when a volume may go":
  const keep = Retention(succeeded: 0, failed: 600, pressure: 60)
  test "a run that succeeded releases its volume at once":
    check volumeDue("SUCCEEDED", ended = 1000, now = 1000, coreStarted = 0, keep = keep, pressure = false)
  test "a failed run keeps it for the retention":
    check not volumeDue("FAILED", ended = 1000, now = 1599, coreStarted = 0, keep = keep, pressure = false)
    check volumeDue("FAILED", ended = 1000, now = 1600, coreStarted = 0, keep = keep, pressure = false)
  test "the core that has just started deletes nothing of a failed run until it has been up for the retention":
    # the run failed long ago, the core came back at 5000: the volume goes at 5600, not at once
    check not volumeDue("FAILED", ended = 1000, now = 5000, coreStarted = 5000, keep = keep, pressure = false)
    check not volumeDue("FAILED", ended = 1000, now = 5599, coreStarted = 5000, keep = keep, pressure = false)
    check volumeDue("FAILED", ended = 1000, now = 5600, coreStarted = 5000, keep = keep, pressure = false)
  test "that wait does not hold back a run that succeeded":
    check volumeDue("SUCCEEDED", ended = 4000, now = 5000, coreStarted = 5000, keep = keep, pressure = false)
  test "under pressure a failed run keeps its volume for a minute only, and the wait after a start does not apply":
    check not volumeDue("FAILED", ended = 4990, now = 5000, coreStarted = 5000, keep = keep, pressure = true)
    check volumeDue("FAILED", ended = 4940, now = 5000, coreStarted = 5000, keep = keep, pressure = true)
  test "a retention that is negative keeps the volume for good, pressure or not":
    let forever = Retention(succeeded: -1, failed: -1, pressure: 60)
    check not volumeDue("FAILED", ended = 0, now = 1_000_000, coreStarted = 0, keep = forever, pressure = true)
    check not volumeDue("SUCCEEDED", ended = 0, now = 1_000_000, coreStarted = 0, keep = forever, pressure = false)
  test "pressure never makes the keep longer than the retention":
    let short = Retention(succeeded: 0, failed: 30, pressure: 60)
    check volumeDue("FAILED", ended = 970, now = 1000, coreStarted = 0, keep = short, pressure = true)
  test "the defaults: 10 minutes for a failed run, a minute under pressure":
    check defaultKeepFailed == 600 and defaultKeepPressure == 60
