## The launch gate's poller and shared state (DAT-010, RUN-015). Every `pollInterval` it asks each VictoriaLogs node
## `/health` and vlagent `/health` + `/metrics` (per-destination queue size), feeds logcircuit.update and publishes the
## result; scheduler.nim reads it with `currentGate()` on every ControllerAttach poll. Poll results are not written to
## rqlite (DAT-010): the gate lives in memory and is fail-closed after a restart until the first round has finished.
import std/[atomics, httpclient, locks, tables, times, strutils, os]
import logcircuit

type
  Watch* = object
    nodes*: seq[string]       ## VictoriaLogs node base URLs, in the same order as vlagent's remoteWrite list
    agentUrl*: string         ## vlagent base URL, e.g. http://127.0.0.1:19429
    cfg*: Config
    disabled*: bool           ## CINIM_LAUNCH_GATE=off - test setups without a log circuit only, see main.nim

var
  lock: Lock
  shared {.guard: lock.}: Gate
  lastUpdate {.guard: lock.}: float
  sharedCfg {.guard: lock.}: Config
  sharedDisabled {.guard: lock.}: bool
  proxyFailedAt {.guard: lock.}: float      ## when the log proxy last failed to hand a block to vlagent (0 = never)

initLock(lock)
{.cast(gcsafe).}:
  withLock lock:
    shared = newGate()
    sharedCfg = defaultConfig()

proc initGate*(w: Watch) =
  {.cast(gcsafe).}:
    withLock lock:
      sharedCfg = w.cfg
      sharedDisabled = w.disabled
      shared = newGate()

proc currentGate*(now = epochTime()): Gate =
  ## What the scheduler may rely on right now; a poller that has fallen silent counts as "state unknown".
  {.cast(gcsafe).}:
    withLock lock:
      result = if sharedDisabled: Gate(state: gsOpen) else: shared.stale(lastUpdate, now, sharedCfg)

proc noteProxyFailure*(now = epochTime()) =
  ## The log proxy (logcollector.nim) could not hand a block to vlagent: close the gate now instead of waiting for the poller to
  ## notice (D-27, A.10). The poller keeps the closure until its own condition has held for the stabilisation time.
  {.cast(gcsafe).}:
    withLock lock:
      shared = shared.closeNow(now)
      proxyFailedAt = now

proc probe(url: string; timeoutMs = 1500): tuple[ok: bool, body: string] =
  var c = newHttpClient(timeout = timeoutMs)
  defer: c.close()
  try:
    let r = c.request(url, httpMethod = HttpGet)
    (r.code.is2xx, r.body)
  except CatchableError:
    (false, "")

proc pollRound*(w: Watch; nodes: var seq[NodeStatus]; agent: var AgentStatus) =
  for i, url in w.nodes:
    if probe(url & "/health").ok:
      nodes[i].failures = 0
      nodes[i].seen = true
    else:
      inc nodes[i].failures
  if probe(w.agentUrl & "/health").ok:
    agent.failures = 0
    agent.seen = true
    let (ok, body) = probe(w.agentUrl & "/metrics")
    let queues = if ok: parseQueues(body) else: initTable[int, PendingQueue]()
    for i in 0 ..< nodes.len:
      if (i + 1) in queues:
        nodes[i].pendingBytes = queues[i + 1].bytes
        nodes[i].blocked = queues[i + 1].blocked
      else:
        nodes[i].pendingBytes = -1
        nodes[i].blocked = false
  else:
    inc agent.failures

proc serveLogGate*(w: Watch; stop: ptr Atomic[bool]) {.thread.} =
  {.cast(gcsafe).}:
    var nodes = newSeq[NodeStatus](w.nodes.len)
    for i in 0 ..< nodes.len:
      nodes[i] = NodeStatus(name: w.nodes[i], pendingBytes: -1)
    var agent: AgentStatus
    var g = newGate()
    var seenFailure = 0.0
    while not stop[].load:
      pollRound(w, nodes, agent)
      let now = epochTime()
      var pf = 0.0
      withLock lock: pf = proxyFailedAt
      if pf > seenFailure:                     # the proxy failed since the last round: the poller's copy must not reopen over it
        seenFailure = pf
        g = g.closeNow(pf)
      let next = g.update(nodes, agent, now, w.cfg)
      if next.state != g.state:
        echo "core: launch gate ", g.state, " -> ", next.state, (if next.reason.len > 0: " (" & next.reason & ")" else: "")
      g = next
      withLock lock:
        shared = g
        lastUpdate = now
      var slept = 0.0
      while slept < w.cfg.pollInterval and not stop[].load:   # wake early on shutdown
        sleep 100
        slept += 0.1
