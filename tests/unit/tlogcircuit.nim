## Log circuit rules of the coordinator role in core (DAT-010, RUN-015, D-21): ported from the reference pkg/coordinator of the ZincSearch fork.
import std/[unittest, options, json]
import core/logcircuit

const cfg = Config(failThreshold: 3, maxLag: 1000, promoteCooldown: 60.0, pollInterval: 2.0, gateMaxLag: 100_000)

func node(name: string; failures = 0; seen = 1.0; connected = true; lag = 0; applied = 100; err = ""): NodeStatus =
  NodeStatus(name: name, failures: failures, lastSeen: seen,
             stream: StreamStatus(connected: connected, lag: lag, lastApplied: applied, lastError: err))

suite "DAT-010 node classification":
  test "DAT-010 down after fail_threshold failed polls in a row, suspect before":
    check classify(node("a", failures = 3), cfg) == nsDown
    check classify(node("a", failures = 2), cfg) == nsSuspect
    check classify(node("a", failures = 1), cfg) == nsSuspect
  test "DAT-010 a node that was never reached is unknown":
    check classify(node("a", seen = 0.0), cfg) == nsUnknown
  test "DAT-010 a node that lost the stream needs a restore, and is not promotable":
    check classify(node("a", err = "stream does not reach back to the node's offset"), cfg) == nsNeedsRestore
    check classify(node("a", err = "position is ahead of the stream"), cfg) == nsNeedsRestore
  test "DAT-010 disconnected and lagging nodes are not up":
    check classify(node("a", connected = false), cfg) == nsDegraded
    check classify(node("a", lag = 1001), cfg) == nsLagging
    check classify(node("a", lag = 1000), cfg) == nsUp

suite "DAT-010 failover decision":
  let cl = Cluster(master: "a", epoch: 1, changedAt: 0.0, reason: "initial")
  test "DAT-010 a healthy master is never replaced":
    check decideFailover(cl, [node("a"), node("b")], 1000.0, cfg).isNone
  test "DAT-010 a down master is replaced by the replica that is up":
    let p = decideFailover(cl, [node("a", failures = 3), node("b")], 1000.0, cfg)
    check p.isSome and p.get.to == "b" and p.get.epoch == 2
  test "DAT-010 a master that needs a restore is replaced too":
    check decideFailover(cl, [node("a", err = "stream does not reach back"), node("b")], 1000.0, cfg).isSome
  test "DAT-010 a master that lost the stream but answers is not the same as down: only down or needs_restore count":
    check decideFailover(cl, [node("a", connected = false), node("b")], 1000.0, cfg).isNone
  test "DAT-010 the freshest replica wins":
    let p = decideFailover(cl, [node("a", failures = 3), node("b", applied = 90), node("c", applied = 99)], 1000.0, cfg)
    check p.get.to == "c"
  test "DAT-010 replicas that are lagging, suspect, down or unknown are not candidates; with none nothing changes":
    check decideFailover(cl, [node("a", failures = 3), node("b", lag = 5000), node("c", failures = 1), node("d", seen = 0.0)], 1000.0, cfg).isNone
  test "DAT-010 promote_cooldown: no second promotion within a minute of the last change":
    let recent = Cluster(master: "a", epoch: 2, changedAt: 990.0, reason: "promoted")
    check decideFailover(recent, [node("a", failures = 3), node("b")], 1000.0, cfg).isNone
    check decideFailover(recent, [node("a", failures = 3), node("b")], 1051.0, cfg).isSome
  test "DAT-010 the returned old master is a replica and nothing flips back":
    let after = Cluster(master: "b", epoch: 2, changedAt: 0.0, reason: "master a is down")
    check decideFailover(after, [node("a"), node("b")], 1000.0, cfg).isNone

suite "DAT-010 compare-and-set state":
  test "DAT-010 two coordinators deciding at once promote exactly once (epoch is fenced by the store revision)":
    let st = newMemStore()
    check st.initCluster("a", 0.0).master == "a"
    let statuses = [node("a", failures = 3), node("b")]
    var promoted = 0
    for _ in 0 ..< 2:                        # both read the same revision, both decide, the second CAS loses
      let (cl, rev) = st.loadCluster()
      let p = decideFailover(cl, statuses, 1000.0, cfg)
      if p.isSome and st.tryPromote(cl, rev, p.get, 1000.0): inc promoted
    check promoted == 1
    check st.loadCluster()[0].master == "b" and st.loadCluster()[0].epoch == 2
  test "DAT-010 the promotion history is appended":
    let st = newMemStore()
    discard st.initCluster("a", 0.0)
    let (cl, rev) = st.loadCluster()
    check st.tryPromote(cl, rev, decideFailover(cl, [node("a", failures = 3), node("b")], 1000.0, cfg).get, 1000.0)
    check st.history().len == 1 and st.history()[0]["to"].getStr == "b"

suite "NFR-015 failover time":
  test "NFR-015 detection takes between (threshold-1) and threshold poll intervals, at most 10 s with the defaults":
    # simulate the poll loop: the master dies at a random moment between two polls
    for phase in [0.01, 0.5, 1.0, 1.5, 1.99]:
      var t = 0.0
      var failures = 0
      var detected = -1.0
      let diedAt = 10.0 + phase
      while detected < 0:
        t += cfg.pollInterval
        if t > diedAt: inc failures
        if failures >= cfg.failThreshold: detected = t - diedAt
      check detected >= (cfg.failThreshold.float - 1) * cfg.pollInterval - 1e-9
      check detected <= cfg.failThreshold.float * cfg.pollInterval + 1e-9
      check detected <= 10.0

suite "RUN-015 launch gate":
  test "RUN-015 the gate is open only with a serving master, working publication and bounded lag":
    let cl = Cluster(master: "a", epoch: 1)
    check launchGate(cl, [node("a"), node("b")], publishOk = true, cfg).open
    check not launchGate(cl, [node("a", failures = 3), node("b")], true, cfg).open
    check not launchGate(cl, [node("a"), node("b")], false, cfg).open
    check not launchGate(cl, [node("a", lag = 100_001)], true, cfg).open
    check launchGate(cl, [node("a", lag = 50_000)], true, cfg).open        # lagging but within gate_max_lag
    check launchGate(cl, [node("a", failures = 3)], true, cfg).reason == "logs_unavailable"
