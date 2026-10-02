## D-29: core always knows the state of every component - the registry, its ageing, and the reconciliation with the cluster.
import std/[unittest, strutils]
import core/components

let lim = defaultLimits()

suite "registry: sign of life and silence":
  test "a component is unknown until it is seen, then up; the first sight is a state change":
    var r: Registry
    check r.snapshot().len == 0
    let ch = r.touch("job-controller", "jc-1", 100.0)
    check ch.len == 1 and ch[0].frm == csUnknown and ch[0].to == csUp
    check r.touch("job-controller", "jc-1", 101.0).len == 0           # a repeat is not news
    check r.snapshot()[0].lastSeen == 101.0
  test "a controller that goes quiet is down after its limit, not before":
    var r: Registry
    discard r.touch("job-controller", "jc-1", 100.0)
    check r.age(100.0 + lim.controllerDown, lim).len == 0             # exactly at the limit: still up
    let ch = r.age(100.0 + lim.controllerDown + 0.1, lim)
    check ch.len == 1 and ch[0].to == csDown
    check r.age(200.0, lim).len == 0                                  # already down: said once
  test "a component that talks again comes back up, and that is reported":
    var r: Registry
    discard r.touch("executor", "ex-1", 100.0)
    discard r.age(200.0, lim)
    check r.snapshot()[0].state == csDown
    let ch = r.touch("executor", "ex-1", 210.0)
    check ch.len == 1 and ch[0].frm == csDown and ch[0].to == csUp
  test "each kind has its own silence limit":
    var r: Registry
    discard r.touch("job-controller", "jc", 0.0)
    discard r.touch("executor", "ex", 0.0)
    discard r.touch("shim", "s1/0/1", 0.0)
    let ch = r.age(20.0, lim)                                         # 20 s: only the controller's 15 s has passed
    check ch.len == 1 and ch[0].kind == "job-controller"
  test "components that core probes itself are judged by their poller, never by silence":
    var r: Registry
    discard r.setState("vlagent", "vlagent", csUp, 0.0, @[("queue_bytes", "0")])
    check r.age(100000.0, lim).len == 0
    check r.snapshot()[0].state == csUp
    let ch = r.setState("vlagent", "vlagent", csDown, 5.0)
    check ch.len == 1 and ch[0].to == csDown
    check r.setState("vlagent", "vlagent", csDown, 6.0).len == 0
  test "info is kept and replaced; a touch without info keeps the previous facts":
    var r: Registry
    discard r.touch("shim", "x", 1.0, @[("spool_bytes", "10")])
    discard r.touch("shim", "x", 2.0)
    check r.snapshot()[0].info == @[("spool_bytes", "10")]
    discard r.touch("shim", "x", 3.0, @[("spool_bytes", "0")])
    check r.snapshot()[0].info == @[("spool_bytes", "0")]
  test "a component down for a long time is forgotten, a finished shim can be removed":
    var r: Registry
    discard r.touch("shim", "old", 0.0)
    discard r.age(100.0, lim)
    check r.snapshot().len == 1
    discard r.age(100.0 + lim.pruneDown + 1.0, lim)
    check r.snapshot().len == 0
    discard r.touch("shim", "done", 0.0)
    r.remove("shim", "done")
    check r.snapshot().len == 0

suite "registry: what the operator sees":
  test "Prometheus text carries up, last-seen and the counts, with labels escaped":
    var r: Registry
    discard r.touch("job-controller", "jc-\"1\"", 100.0)
    discard r.touch("executor", "ex-1", 100.0)
    discard r.age(160.0, lim)
    let m = r.renderMetrics(161.0)
    check "cinim_component_up{kind=\"job-controller\",id=\"jc-\\\"1\\\"\"} 0" in m
    check "cinim_component_up{kind=\"executor\",id=\"ex-1\"} 0" in m
    check "cinim_component_last_seen_seconds{kind=\"executor\",id=\"ex-1\"} 61.0" in m
    check "cinim_components{state=\"down\"} 2" in m
    check "cinim_components{state=\"up\"} 0" in m

proc step(run: string; seq, attempt: int; state: string; claimed: int64): StepRow =
  StepRow(run: run, seq: seq, attempt: attempt, state: state, claimedAt: claimed)

proc pod(run: string; seq, attempt: int; phase = "Running"): PodRef =
  PodRef(run: run, seq: seq, attempt: attempt, name: "ci-" & run & "-" & $seq & "-" & $attempt, phase: phase)

suite "reconciliation with the cluster":
  test "everything matches: nothing to do":
    let r = reconcile([step("r1", 0, 1, "STARTING", 100)], [pod("r1", 0, 1)], true, 200, 30)
    check r.lost.len == 0 and r.orphans.len == 0
  test "a step core expects a Pod for, with no Pod in the cluster, is lost - once the grace period is over":
    let steps = [step("r1", 0, 1, "STARTING", 100)]
    check reconcile(steps, [], true, 125, 30).lost.len == 0           # just handed over: the Pod is still being created
    let r = reconcile(steps, [], true, 131, 30)
    check r.lost.len == 1 and r.lost[0].run == "r1"
  test "an incomplete inventory proves nothing: a failed list call must never look like 'no Pods exist'":
    let r = reconcile([step("r1", 0, 1, "STARTING", 100)], [], false, 10_000, 30)
    check r.lost.len == 0 and r.orphans.len == 0
  test "a complete but empty inventory does prove it":
    check reconcile([step("r1", 0, 1, "STARTING", 100)], [], true, 10_000, 30).lost.len == 1
  test "queued and finished steps expect no Pod":
    let steps = [step("a", 0, 1, "PENDING", 0), step("b", 0, 1, "SUCCEEDED", 0), step("c", 0, 1, "LOST", 0)]
    check reconcile(steps, [], true, 10_000, 30).lost.len == 0
  test "the Pod of an attempt core moved on from is an orphan - the zombie of Jenkins and TeamCity - and must be deleted":
    let r = reconcile([step("r1", 0, 2, "STARTING", 100)], [pod("r1", 0, 1), pod("r1", 0, 2)], true, 200, 30)
    check r.orphans.len == 1 and r.orphans[0].attempt == 1
    check r.lost.len == 0
  test "a Pod of a step core has never heard of is an orphan too":
    let r = reconcile([], [pod("ghost", 3, 1)], true, 200, 30)
    check r.orphans.len == 1
  test "a finished step's own Pod is left alone (its logs and result may still be wanted)":
    let r = reconcile([step("r1", 0, 1, "SUCCEEDED", 100)], [pod("r1", 0, 1, "Succeeded")], true, 200, 30)
    check r.orphans.len == 0 and r.lost.len == 0
  test "several steps are judged independently":
    let steps = [step("a", 0, 1, "STARTING", 0), step("b", 0, 1, "STARTING", 0), step("c", 1, 3, "STARTING", 0)]
    let r = reconcile(steps, [pod("a", 0, 1), pod("c", 1, 2)], true, 100, 30)
    check r.lost.len == 2                                             # b has no Pod; c's attempt 3 has none (only attempt 2)
    check r.orphans.len == 1 and r.orphans[0].run == "c"
