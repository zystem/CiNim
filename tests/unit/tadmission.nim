## RUN-004 (limits of an organisation's profile), docs/conductors.md section 4: which pending steps of an organisation may be handed
## to its controller now. Pure: the limits of the organisation and of a run, and the order (the run with the fewest steps in flight
## first, then the oldest step). The queries and the claim are in core/scheduler.nim.
import std/[unittest, tables, sequtils, strutils]
import core/[admission, retrypolicy]

proc cand(id, run: string; queued: int64; priority = 0): Candidate =
  Candidate(id: id, runId: run, priority: priority, queuedAt: queued)

suite "RUN-004 job_pod_limit":
  test "20 percent of the organisation's limit, rounded up, at least 1, never above the limit":
    check jobPodLimit(20, 20) == 4
    check jobPodLimit(21, 20) == 5          # 4.2 rounds up
    check jobPodLimit(3, 20) == 1           # 0.6 rounds up to 1
    check jobPodLimit(1, 20) == 1
    check jobPodLimit(20, 100) == 20
    check jobPodLimit(20, 0) == 1           # a run always gets at least one place
    check jobPodLimit(20, 300) == 20        # a percentage above 100 does not exceed the organisation's limit
  test "the settings are checked: the limit 1..10000, the percentage 1..100":
    check validateLimits(20, 20) == ""
    check validateLimits(0, 20) != ""
    check validateLimits(10001, 20) != ""
    check validateLimits(20, 0) != ""
    check validateLimits(20, 101) != ""

suite "RUN-004 admission of steps":
  test "nothing is admitted without free slots or with the organisation at its limit":
    let pending = @[cand("a", "r1", 1)]
    check admit(pending, initTable[string, int](), 5, 20, 4, 0).len == 0           # the controller has no free slot
    check admit(pending, initTable[string, int](), 20, 20, 4, 5).len == 0          # 20 of 20 in flight
  test "at most the organisation's limit is in flight after the admission":
    var pending: seq[Candidate]
    for i in 0 ..< 30: pending.add cand("s" & $i, "r" & $(i mod 10), int64(i))     # ten runs, three steps each
    check admit(pending, initTable[string, int](), 15, 20, 20, 100).len == 5       # 15 in flight, room for 5
  test "a run does not exceed its own limit, whatever the organisation allows":
    var pending: seq[Candidate]
    for i in 0 ..< 10: pending.add cand("s" & $i, "r1", int64(i))
    let got = admit(pending, initTable[string, int](), 0, 20, 4, 100)
    check got.len == 4
    check got == @["s0", "s1", "s2", "s3"]
  test "steps of a run that is at its limit are skipped, the others go on":
    let pending = @[cand("a", "r1", 1), cand("b", "r1", 2), cand("c", "r2", 3)]
    let inflight = {"r1": 4}.toTable
    check admit(pending, inflight, 4, 20, 4, 10) == @["c"]
  test "the run with the fewest steps in flight goes first, then the oldest step":
    let pending = @[cand("old-busy", "r1", 1), cand("new-idle", "r2", 9), cand("mid-idle", "r3", 5)]
    let inflight = {"r1": 3, "r2": 0, "r3": 1}.toTable
    check admit(pending, inflight, 4, 20, 10, 3) == @["new-idle", "mid-idle", "old-busy"]
  test "the places are spread across the runs, not given to the run that asked first":
    var pending: seq[Candidate]
    for i in 0 ..< 6: pending.add cand("a" & $i, "ra", int64(i))        # an old run with six steps
    for i in 0 ..< 6: pending.add cand("b" & $i, "rb", int64(10 + i))   # a newer run with six steps
    let got = admit(pending, initTable[string, int](), 0, 20, 10, 4)
    check got.len == 4
    check got.count("a0") + got.count("a1") == 2                         # two places each, in turn
    check got[0] == "a0" and got[1] == "b0"
  test "a higher priority goes before the fairness rule":
    let pending = @[cand("normal", "r1", 1), cand("urgent", "r2", 9, priority = 5)]
    check admit(pending, initTable[string, int](), 0, 20, 10, 1) == @["urgent"]
  test "the same candidates give the same order every time":
    var pending: seq[Candidate]
    for i in 0 ..< 12: pending.add cand("s" & $i, "r" & $(i mod 3), int64(i))
    check admit(pending, initTable[string, int](), 0, 20, 10, 8) == admit(pending, initTable[string, int](), 0, 20, 10, 8)

suite "RUN-004 the limits are settings of the profile":
  test "the defaults are 20 Pods for the organisation and 20 percent for a run, and are valid":
    let d = defaultSettings()
    check d.podLimit == 20
    check d.jobPodLimitPercent == 20
    check validate(d) == ""
  test "values out of range are refused with the field's name":
    var s = defaultSettings()
    s.podLimit = 0
    check "pod_limit" in validate(s)
    s = defaultSettings()
    s.jobPodLimitPercent = 101
    check "job_pod_limit_percent" in validate(s)
