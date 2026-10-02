## RUN-015 / DAT-010: the launch gate rules of the log circuit (pure logic, no network).
import std/[unittest, tables]
import core/logcircuit
import common/states

let cfg = defaultConfig()

proc node(name: string; failures = 0; seen = true; pending = 0'i64; blocked = false): NodeStatus =
  NodeStatus(name: name, failures: failures, seen: seen, pendingBytes: pending, blocked: blocked)

let agentOk = AgentStatus(seen: true)

proc run(g: Gate; nodes: seq[NodeStatus]; agent: AgentStatus; t0: float; rounds: int): Gate =
  ## `rounds` polls, one per poll_interval, starting at t0
  result = g
  for i in 0 ..< rounds:
    result = result.update(nodes, agent, t0 + i.float * cfg.pollInterval, cfg)

suite "DAT-010: node classification":
  test "up, catching up, down and unknown":
    check classify(node("a"), cfg) == nsUp
    check classify(node("a", pending = 1), cfg) == nsCatchingUp
    check classify(node("a", failures = 3), cfg) == nsDown
    check classify(node("a", seen = false), cfg) == nsUnknown
  test "fewer than fail_threshold failed polls is not yet a verdict":
    check classify(node("a", failures = 2), cfg) == nsUp
    check nodeServes(node("a", failures = 2), cfg)
    check not nodeServes(node("a", failures = 3), cfg)

suite "RUN-015: the open condition":
  test "one healthy node and a working vlagent are enough":
    check conditionHolds(@[node("a"), node("b", failures = 3)], agentOk, cfg)
  test "no node up closes it":
    check not conditionHolds(@[node("a", failures = 3), node("b", failures = 5)], agentOk, cfg)
  test "vlagent not answering closes it even with healthy nodes":
    check not conditionHolds(@[node("a")], AgentStatus(seen: true, failures: 3), cfg)
    check not conditionHolds(@[node("a")], AgentStatus(), cfg)
  test "the queue limit is per node: a node over gate_max_pending does not count, another one does":
    let over = node("a", pending = cfg.maxPending + 1)
    check not conditionHolds(@[over], agentOk, cfg)
    check conditionHolds(@[over, node("b", pending = 1)], agentOk, cfg)
    check conditionHolds(@[node("a", pending = cfg.maxPending)], agentOk, cfg)   # at the limit is still allowed
  test "a blocked (full) queue does not count":
    check not conditionHolds(@[node("a", blocked = true)], agentOk, cfg)
  test "a node with no queue figure reported is judged by its health alone":
    check conditionHolds(@[node("a", pending = -1)], agentOk, cfg)

suite "RUN-015: the gate over time":
  test "starts closed and unknown (fail-closed after a scheduler restart)":
    let g = newGate()
    check g.state == gsClosedUnknown
    check not g.isOpen
    check g.reason == "logs_unavailable"
  test "a healthy circuit opens only after gate_stabilize of continuous health":
    var g = newGate().update(@[node("a")], agentOk, 100.0, cfg)
    check g.state == gsClosed                     # first state received, but not stable yet
    g = g.update(@[node("a")], agentOk, 105.0, cfg)
    check not g.isOpen
    g = g.update(@[node("a")], agentOk, 109.9, cfg)
    check not g.isOpen
    g = g.update(@[node("a")], agentOk, 110.0, cfg)
    check g.isOpen
    check g.reason == ""
  test "an unhealthy first state closes it right away":
    check newGate().update(@[node("a", failures = 3)], agentOk, 100.0, cfg).state == gsClosed
  test "it closes on the first round in which the condition fails":
    var g = newGate().run(@[node("a")], agentOk, 100.0, 7)    # 12 s of health -> open
    check g.isOpen
    g = g.update(@[node("a", pending = cfg.maxPending + 1)], agentOk, 114.0, cfg)
    check g.state == gsClosed
    check g.reason == "logs_unavailable"
  test "a node lost for fail_threshold polls closes the gate within the 10 s of RUN-015":
    var g = newGate().run(@[node("a")], agentOk, 100.0, 7)
    check g.isOpen
    var closedAt = -1.0
    for i in 1 .. 3:                                           # failures 1, 2, 3 at +2 s, +4 s, +6 s
      let t = 112.0 + i.float * cfg.pollInterval
      g = g.update(@[node("a", failures = i)], agentOk, t, cfg)
      if not g.isOpen and closedAt < 0: closedAt = t - 112.0
    check closedAt >= 0 and closedAt <= 10.0
  test "flapping restarts the stabilization period":
    var g = newGate().run(@[node("a")], agentOk, 100.0, 4)      # healthy for 6 s: not open yet
    check not g.isOpen
    g = g.update(@[node("a", failures = 3)], agentOk, 108.0, cfg)   # drops
    g = g.update(@[node("a")], agentOk, 110.0, cfg)                 # back: the clock starts over
    g = g.update(@[node("a")], agentOk, 119.0, cfg)
    check not g.isOpen
    g = g.update(@[node("a")], agentOk, 120.0, cfg)
    check g.isOpen
  test "a poller that stopped delivering is state unknown, not the last answer":
    let g = newGate().run(@[node("a")], agentOk, 100.0, 7)
    check g.isOpen
    check g.stale(112.0, 113.0, cfg).isOpen                    # fresh enough
    check g.stale(112.0, 200.0, cfg).state == gsClosedUnknown
  test "every transition the gate makes is one the state machine allows (docs/state-machines.md)":
    var g = newGate()
    var prev = g.state
    for step in 0 ..< 40:
      let healthy = (step div 8) mod 2 == 0
      g = g.update(@[node("a", failures = (if healthy: 0 else: 3))], agentOk, 100.0 + step.float * 2.0, cfg)
      if g.state != prev:
        check g.state in gateNext(prev)
        prev = g.state

suite "DAT-010: vlagent metrics":
  test "per-destination queue size and blocked flag, by position in remoteWrite":
    let text = """
# TYPE vlagent_remotewrite_pending_data_bytes gauge
vlagent_remotewrite_pending_data_bytes{path="/q/1_AA", url="1:secret-url"} 1024
vlagent_remotewrite_pending_data_bytes{path="/q/2_BB", url="2:secret-url"} 0
vlagent_remotewrite_queue_blocked{path="/q/2_BB", url="2:secret-url"} 1
vlagent_remotewrite_queue_blocked{path="/q/1_AA", url="1:secret-url"} 0
vlagent_remotewrite_queues{url="1:secret-url"} 8
vm_other{url="not-ours"} 5
"""
    let q = parseQueues(text)
    check q[1].bytes == 1024 and not q[1].blocked
    check q[2].bytes == 0 and q[2].blocked
    check q.len == 2
  test "nothing parsable gives nothing":
    check parseQueues("").len == 0
    check parseQueues("some_other_metric 1\n").len == 0

suite "D-27: the in-band signal from the log proxy":
  test "a failed write to vlagent closes an open gate at once, without waiting for a poll":
    var g = newGate().run(@[node("a")], agentOk, 100.0, 7)
    check g.isOpen
    g = g.closeNow(113.0)
    check g.state == gsClosed and g.reason == "logs_unavailable" and g.since == 113.0
  test "it opens again only after the polled condition has held for gate_stabilize, counted from the failure":
    var g = newGate().run(@[node("a")], agentOk, 100.0, 7).closeNow(113.0)
    g = g.update(@[node("a")], agentOk, 114.0, cfg)           # the circuit looks healthy again at the next poll ...
    check not g.isOpen                                         # ... but the stabilisation time starts over
    g = g.update(@[node("a")], agentOk, 123.9, cfg)
    check not g.isOpen
    g = g.update(@[node("a")], agentOk, 124.0, cfg)
    check g.isOpen
  test "a gate that is already closed or unknown stays as it is (and keeps its reason)":
    let unknown = newGate()
    check unknown.closeNow(5.0).state == gsClosedUnknown
    let closed = newGate().update(@[node("a", failures = 3)], agentOk, 100.0, cfg)
    check closed.closeNow(101.0).since == closed.since
