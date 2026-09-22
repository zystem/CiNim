## Log circuit rules of the coordinator role in core (DAT-010, RUN-015): node classification, failover decision, launch gate and the
## compare-and-set cluster state. Ported from the reference pkg/coordinator of the ZincSearch fork (D-21); pure logic, no I/O except the store.

import std/[json, options, strutils, tables, algorithm]

type
  NodeState* = enum
    nsUnknown, nsUp, nsLagging, nsDegraded, nsSuspect, nsDown, nsNeedsRestore

  StreamStatus* = object
    connected*: bool
    lag*, lastApplied*: int
    lastError*: string

  NodeStatus* = object
    name*: string
    failures*: int          ## consecutive failed polls
    lastSeen*: float        ## epoch seconds of the last answer, 0 = never
    stream*: StreamStatus

  Config* = object
    failThreshold*, maxLag*, gateMaxLag*: int
    promoteCooldown*, pollInterval*: float

  Cluster* = object
    master*: string
    epoch*: int
    changedAt*: float
    reason*: string

  Promotion* = object
    epoch*: int
    frm*, to*: string
    at*: float
    reason*: string

  Gate* = object
    open*: bool
    reason*: string

const
  gapMessage = "does not reach back"
  aheadMessage = "is ahead of the stream"

func classify*(s: NodeStatus; cfg: Config): NodeState =
  if s.failures >= cfg.failThreshold: nsDown
  elif s.failures > 0: nsSuspect
  elif s.lastSeen == 0.0: nsUnknown
  elif gapMessage in s.stream.lastError or aheadMessage in s.stream.lastError: nsNeedsRestore
  elif not s.stream.connected: nsDegraded
  elif s.stream.lag > cfg.maxLag: nsLagging
  else: nsUp

func find(statuses: openArray[NodeStatus]; name: string): Option[NodeStatus] =
  for s in statuses:
    if s.name == name: return some(s)

func decideFailover*(cl: Cluster; statuses: openArray[NodeStatus]; now: float; cfg: Config): Option[Promotion] =
  ## Only a master that is down or needs a restore is replaced; the replacement is the freshest node that is up;
  ## a cooldown separates promotions; nothing changes when no replica qualifies.
  let m = statuses.find(cl.master)
  if m.isNone: return
  let st = classify(m.get, cfg)
  if st notin {nsDown, nsNeedsRestore}: return
  if now - cl.changedAt < cfg.promoteCooldown: return
  var candidate = ""
  var freshest = -1
  for s in statuses:
    if s.name == cl.master or classify(s, cfg) != nsUp: continue
    if candidate.len == 0 or s.stream.lastApplied > freshest:
      candidate = s.name
      freshest = s.stream.lastApplied
  if candidate.len == 0: return
  some(Promotion(epoch: cl.epoch + 1, frm: cl.master, to: candidate, at: now,
                 reason: "master " & cl.master & " is " & (if st == nsDown: "down" else: "needs_restore")))

func launchGate*(cl: Cluster; statuses: openArray[NodeStatus]; publishOk: bool; cfg: Config): Gate =
  ## RUN-015: new step Pods may start only with a serving master, working publication and bounded lag.
  ## (The spec says "master in state up" and also "lag up to gate_max_lag" (100 000) while `up` allows 1 000: a lagging master
  ## within gate_max_lag keeps the gate open, see ADR 0014.)
  let m = statuses.find(cl.master)
  if publishOk and m.isSome and classify(m.get, cfg) in {nsUp, nsLagging} and m.get.stream.lag <= cfg.gateMaxLag:
    Gate(open: true)
  else:
    Gate(open: false, reason: "logs_unavailable")

# ------------------------------------------------------------------ state store with compare-and-set

type
  StoreConflict* = object of CatchableError
  StoreNotFound* = object of CatchableError

  StateStore* = ref object of RootObj

  MemStore* = ref object of StateStore
    data: Table[string, (string, int)]

method get*(s: StateStore; key: string): (string, int) {.base.} = raiseAssert "abstract"
method create*(s: StateStore; key, value: string): int {.base.} = raiseAssert "abstract"
method update*(s: StateStore; key, value: string; rev: int): int {.base.} = raiseAssert "abstract"
method keys*(s: StateStore; prefix: string): seq[string] {.base.} = raiseAssert "abstract"

proc newMemStore*(): MemStore = MemStore()

method get*(s: MemStore; key: string): (string, int) =
  if key notin s.data: raise newException(StoreNotFound, key)
  s.data[key]

method create*(s: MemStore; key, value: string): int =
  if key in s.data: raise newException(StoreConflict, key)
  s.data[key] = (value, 1)
  1

method update*(s: MemStore; key, value: string; rev: int): int =
  if key notin s.data: raise newException(StoreNotFound, key)
  if s.data[key][1] != rev: raise newException(StoreConflict, key)
  s.data[key] = (value, rev + 1)
  rev + 1

method keys*(s: MemStore; prefix: string): seq[string] =
  for k in s.data.keys:
    if k.startsWith(prefix): result.add k

const clusterKey = "cluster"

proc toJson(c: Cluster): string = $(%*{"master": c.master, "epoch": c.epoch, "changed_at": c.changedAt, "reason": c.reason})

proc fromJson(s: string): Cluster =
  let j = parseJson(s)
  Cluster(master: j["master"].getStr, epoch: j["epoch"].getInt, changedAt: j["changed_at"].getFloat, reason: j["reason"].getStr)

proc loadCluster*(st: StateStore): (Cluster, int) =
  let (v, rev) = st.get(clusterKey)
  (fromJson(v), rev)

proc initCluster*(st: StateStore; firstNode: string; now: float): Cluster =
  ## The first configured node is master until the state says otherwise; another instance may have been first.
  try:
    return st.loadCluster()[0]
  except StoreNotFound:
    discard
  let c = Cluster(master: firstNode, epoch: 1, changedAt: now, reason: "initial")
  try:
    discard st.create(clusterKey, toJson(c))
    c
  except StoreConflict:
    st.loadCluster()[0]

proc tryPromote*(st: StateStore; cl: Cluster; rev: int; p: Promotion; now: float): bool =
  ## CAS on the revision read together with `cl`: of two coordinators deciding at once exactly one wins.
  let next = Cluster(master: p.to, epoch: cl.epoch + 1, changedAt: now, reason: p.reason)
  try:
    discard st.update(clusterKey, toJson(next), rev)
  except StoreConflict:
    return false
  try:
    discard st.create("history/" & align($next.epoch, 20, '0'),
                      $(%*{"epoch": next.epoch, "from": p.frm, "to": p.to, "at": now, "reason": p.reason}))
  except StoreConflict:
    discard        # history is best effort, as in the reference
  true

proc history*(st: StateStore): seq[JsonNode] =
  var ks = st.keys("history/")
  ks.sort()
  for k in ks: result.add parseJson(st.get(k)[0])
