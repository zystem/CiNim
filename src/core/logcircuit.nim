## Log circuit rules (DAT-010, RUN-015): classify the VictoriaLogs nodes and vlagent's per-node delivery queues and decide
## the launch gate. Pure logic, no I/O (the poller is src/core/loggate.nim) - so every rule here is unit-tested.
##
## There is no master and no failover (D-21, A.7): VictoriaLogs nodes are independent, vlagent replicates to each
## with its own disk queue, vmauth fails reads over. The only decision left for core is "may new step Pods start?".
## See RUN-015 and A.10.

import std/[strutils, tables]
import ../common/states

export states.GateState

type
  NodeState* = enum
    nsUnknown       ## never answered yet
    nsUp            ## healthy, nothing waiting in vlagent's queue for it
    nsCatchingUp    ## healthy, vlagent still has undelivered data for it
    nsDown          ## `failThreshold` failed health polls in a row

  NodeStatus* = object
    name*: string
    failures*: int         ## consecutive failed /health polls
    seen*: bool            ## answered at least once
    pendingBytes*: int64   ## vlagent's undelivered data for this node, -1 = not reported
    blocked*: bool         ## vlagent's queue for this node is full (it refuses new data for it)

  AgentStatus* = object    ## vlagent itself: does it take writes at all
    failures*: int
    seen*: bool

  Config* = object
    failThreshold*: int    ## fail_threshold, default 3
    maxPending*: int64     ## gate_max_pending, default 256 MiB
    pollInterval*: float   ## poll_interval, default 2 s
    stabilize*: float      ## gate_stabilize, default 10 s

  Gate* = object
    state*: GateState
    reason*: string        ## "" when open, "logs_unavailable" otherwise (steps.wait_reason, API)
    since*: float          ## epoch seconds of the last state change
    okSince*: float        ## epoch seconds the open condition has held continuously, 0 = it does not hold now

const reasonUnavailable* = "logs_unavailable"

func defaultConfig*(): Config =
  Config(failThreshold: 3, maxPending: 256'i64 * 1024 * 1024, pollInterval: 2.0, stabilize: 10.0)

func classify*(n: NodeStatus; cfg: Config): NodeState =
  # fewer than failThreshold failed polls in a row is not yet a verdict, the node keeps its previous reading
  if n.failures >= cfg.failThreshold: nsDown
  elif not n.seen: nsUnknown
  elif n.pendingBytes > 0: nsCatchingUp
  else: nsUp

func nodeServes*(n: NodeStatus; cfg: Config): bool =
  ## RUN-015: a node counts for the gate when it is up (or catching up), vlagent's queue for it is below
  ## gate_max_pending and not blocked.
  n.failures < cfg.failThreshold and n.seen and not n.blocked and n.pendingBytes <= cfg.maxPending

func conditionHolds*(nodes: openArray[NodeStatus]; agent: AgentStatus; cfg: Config): bool =
  ## "at least one VictoriaLogs node is up, vlagent accepts writes and its queue for that node is within the limit"
  if not agent.seen or agent.failures >= cfg.failThreshold: return false
  for n in nodes:
    if nodeServes(n, cfg): return true
  false

func newGate*(): Gate =
  ## After a scheduler restart the gate is closed until the first state arrives (fail-closed, criterion 26).
  Gate(state: gsClosedUnknown, reason: reasonUnavailable)

func update*(g: Gate; nodes: openArray[NodeStatus]; agent: AgentStatus; now: float; cfg: Config): Gate =
  ## One poll round. Closes at once when the condition fails (the failure thresholds already bound the detection time:
  ## 3 polls x 2 s, inside the 10 s the spec allows); opens only after the condition held continuously for `stabilize`.
  result = g
  if result.state == gsClosedUnknown:          # a state was received: now it is known
    result.state = gsClosed
    result.since = now
  if conditionHolds(nodes, agent, cfg):
    if result.okSince == 0.0: result.okSince = now
    if result.state != gsOpen and now - result.okSince >= cfg.stabilize:
      result.state = gsOpen
      result.reason = ""
      result.since = now
  else:
    result.okSince = 0.0
    if result.state != gsClosed:
      result.state = gsClosed
      result.since = now
    result.reason = reasonUnavailable

func closeNow*(g: Gate; now: float): Gate =
  ## In-band signal (D-27, A.10): a write to vlagent just failed or was refused, which is proof of trouble that need not
  ## wait for the next poll. The gate closes at once; it opens again only after the polled condition has held for `stabilize`.
  result = g
  result.okSince = 0.0
  if result.state == gsOpen:
    result.state = gsClosed
    result.since = now
    result.reason = reasonUnavailable

func isOpen*(g: Gate): bool = g.state == gsOpen

func stale*(g: Gate; lastUpdate, now: float; cfg: Config): Gate =
  ## The poller itself stopped delivering state: that is "state unknown" again, never "keep the last answer".
  result = g
  if g.state != gsClosedUnknown and now - lastUpdate > cfg.pollInterval * 5:
    result.state = gsClosedUnknown
    result.reason = reasonUnavailable
    result.okSince = 0.0
    result.since = now

# ------------------------------------------------------------------ vlagent metrics

type PendingQueue* = object
  bytes*: int64
  blocked*: bool

proc urlIndex(line: string): int =
  ## vlagent labels each destination `url="<position in remoteWrite, 1-based>:secret-url"` (the real URL is hidden).
  let i = line.find("url=\"")
  if i < 0: return -1
  var j = i + 5
  var n = 0
  var digits = 0
  while j < line.len and line[j] in {'0'..'9'}:
    n = n * 10 + (ord(line[j]) - ord('0'))
    inc j
    inc digits
  if digits > 0 and j < line.len and line[j] == ':': n else: -1

proc metricValue(line: string): float =
  let k = line.rfind(' ')
  if k < 0: return 0.0
  try: parseFloat(line[k + 1 .. ^1]) except ValueError: 0.0

proc parseQueues*(metrics: string): Table[int, PendingQueue] =
  ## Per destination (by its 1-based position in vlagent's remoteWrite list, i.e. the node's position in our config):
  ## undelivered bytes and whether the queue is blocked.
  for line in metrics.splitLines:
    if line.startsWith("vlagent_remotewrite_pending_data_bytes{"):
      let ix = urlIndex(line)
      if ix > 0: result.mgetOrPut(ix, PendingQueue()).bytes += int64(metricValue(line))
    elif line.startsWith("vlagent_remotewrite_queue_blocked{"):
      let ix = urlIndex(line)
      if ix > 0 and metricValue(line) > 0: result.mgetOrPut(ix, PendingQueue()).blocked = true
