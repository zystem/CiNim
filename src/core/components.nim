## Component registry and reconciliation (D-29): core must always know the state of every other component.
##
## Two independent sources feed it, so one component's silence or lie is never the only evidence:
##   - the component's own traffic: every ControllerAttach poll, executor lease and shim log batch is its heartbeat and
##     carries a ComponentStatus; core ages them (`age`) and calls a component that stops talking `down`;
##   - core's own verification: the job-controller's Pod inventory (read from the Kubernetes API by label) is compared
##     with core's table of steps (`reconcile`), and core's pollers report vlagent/VictoriaLogs/rqlite here too.
## Pure logic plus one global instance behind a lock; `reconcile` and `age` are unit-tested without any I/O.
import std/[tables, locks, strutils, algorithm]

type
  CompState* = enum
    csUnknown, csUp, csDown

  Component* = object
    kind*, id*: string
    state*: CompState
    lastSeen*: float          ## epoch seconds of the last sign of life
    since*: float             ## epoch seconds of the last state change
    info*: seq[(string, string)]

  Registry* = object
    items: Table[string, Component]

  Limits* = object
    controllerDown*, executorDown*, shimDown*: float    ## silence after which a component of that kind is `down`
    pruneDown*: float                                    ## a component that stayed down this long is forgotten

  Change* = object
    kind*, id*: string
    frm*, to*: CompState

func defaultLimits*(): Limits =
  Limits(controllerDown: 15.0, executorDown: 30.0, shimDown: 30.0, pruneDown: 3600.0)

func key(kind, id: string): string = kind & "/" & id

proc touch*(r: var Registry; kind, id: string; now: float; info: seq[(string, string)] = @[]): seq[Change] =
  ## A sign of life. Returns the state change it caused (a component that comes back from `down` or is seen the first time).
  let k = key(kind, id)
  var c = r.items.getOrDefault(k, Component(kind: kind, id: id, state: csUnknown, since: now))
  if c.state != csUp:
    result.add Change(kind: kind, id: id, frm: c.state, to: csUp)
    c.state = csUp
    c.since = now
  c.lastSeen = now
  if info.len > 0: c.info = info
  r.items[k] = c

proc setState*(r: var Registry; kind, id: string; state: CompState; now: float;
               info: seq[(string, string)] = @[]): seq[Change] =
  ## For components core probes itself (vlagent, VictoriaLogs, rqlite): the poller states the verdict directly.
  let k = key(kind, id)
  var c = r.items.getOrDefault(k, Component(kind: kind, id: id, state: csUnknown, since: now))
  if c.state != state:
    result.add Change(kind: kind, id: id, frm: c.state, to: state)
    c.state = state
    c.since = now
  if state == csUp: c.lastSeen = now
  if info.len > 0: c.info = info
  r.items[k] = c

proc remove*(r: var Registry; kind, id: string) = r.items.del(key(kind, id))

proc silenceLimit(kind: string; lim: Limits): float =
  case kind
  of "job-controller": lim.controllerDown
  of "executor", "conductor": lim.executorDown
  of "shim": lim.shimDown
  else: 0.0                 # probed kinds are judged by their poller, not by silence

proc age*(r: var Registry; now: float; lim: Limits): seq[Change] =
  ## Mark components that went quiet as down; forget the ones that have been down for a long time.
  var forget: seq[string]
  for k, c in r.items.mpairs:
    let limit = silenceLimit(c.kind, lim)
    if limit > 0 and c.state == csUp and now - c.lastSeen > limit:
      result.add Change(kind: c.kind, id: c.id, frm: csUp, to: csDown)
      c.state = csDown
      c.since = now
    elif c.state == csDown and now - c.since > lim.pruneDown:
      forget.add k
  for k in forget: r.items.del(k)

proc snapshot*(r: Registry): seq[Component] =
  for c in r.items.values: result.add c
  result.sort(proc (a, b: Component): int = cmp(key(a.kind, a.id), key(b.kind, b.id)))

func escapeLabel(s: string): string =
  s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")

proc renderMetrics*(r: Registry; now: float): string =
  ## Prometheus text exposition: what an operator needs to alert on "a component went quiet".
  let comps = r.snapshot()
  result = "# HELP cinim_component_up 1 if core considers the component up, 0 if down, -1 if not yet known.\n" &
           "# TYPE cinim_component_up gauge\n"
  for c in comps:
    let v = (if c.state == csUp: 1 elif c.state == csDown: 0 else: -1)
    result.add "cinim_component_up{kind=\"" & escapeLabel(c.kind) & "\",id=\"" & escapeLabel(c.id) & "\"} " & $v & "\n"
  result.add "# HELP cinim_component_last_seen_seconds Seconds since the component last showed a sign of life.\n" &
             "# TYPE cinim_component_last_seen_seconds gauge\n"
  for c in comps:
    result.add "cinim_component_last_seen_seconds{kind=\"" & escapeLabel(c.kind) & "\",id=\"" & escapeLabel(c.id) & "\"} " &
               formatFloat(max(now - c.lastSeen, 0.0), ffDecimal, 1) & "\n"
  var counts: array[CompState, int]
  for c in comps: inc counts[c.state]
  result.add "# TYPE cinim_components gauge\n"
  for s in CompState:
    result.add "cinim_components{state=\"" & ["unknown", "up", "down"][ord(s)] & "\"} " & $counts[s] & "\n"

# ------------------------------------------------------------------ the process-wide instance

var
  lock: Lock
  global {.guard: lock.}: Registry
initLock(lock)

proc registryTouch*(kind, id: string; now: float; info: seq[(string, string)] = @[]): seq[Change] =
  {.cast(gcsafe).}:
    withLock lock: result = global.touch(kind, id, now, info)

proc registryLastSeen*(kind, id: string): float =
  ## the time of the component's last sign of life (epoch seconds), 0 if the registry does not hold it
  {.cast(gcsafe).}:
    withLock lock: result = global.items.getOrDefault(key(kind, id)).lastSeen

proc registrySet*(kind, id: string; state: CompState; now: float; info: seq[(string, string)] = @[]): seq[Change] =
  {.cast(gcsafe).}:
    withLock lock: result = global.setState(kind, id, state, now, info)

proc registryRemove*(kind, id: string) =
  {.cast(gcsafe).}:
    withLock lock: global.remove(kind, id)

proc registryAge*(now: float; lim = defaultLimits()): seq[Change] =
  {.cast(gcsafe).}:
    withLock lock: result = global.age(now, lim)

proc registrySnapshot*(): seq[Component] =
  {.cast(gcsafe).}:
    withLock lock: result = global.snapshot()

proc registryMetrics*(now: float): string =
  {.cast(gcsafe).}:
    withLock lock: result = global.renderMetrics(now)

# ------------------------------------------------------------------ reconciliation with the cluster

type
  StepRow* = object          ## what core's own table says about a step
    run*: string
    seq*, attempt*: int
    state*: string           ## PENDING | STARTING | ... (steps.state)
    claimedAt*: int64        ## epoch seconds the step was handed to a controller

  PodRef* = object           ## what the controller reports it found in the cluster
    run*: string
    seq*, attempt*: int
    name*, phase*: string

  Reconciliation* = object
    lost*: seq[StepRow]      ## core thinks a Pod exists, the cluster has none: the step is lost
    orphans*: seq[PodRef]    ## a Pod of an attempt core no longer wants: it must be deleted

func reconcile*(steps: openArray[StepRow]; pods: openArray[PodRef]; complete: bool; now, grace: int64): Reconciliation =
  ## `steps` = the steps core handed to this controller and expects Pods for, plus the step rows of the Pods it reported.
  ## Nothing is concluded from an incomplete inventory (a failed list call must never look like "no Pods exist").
  if not complete: return
  var present = initTable[(string, int, int), bool]()
  for p in pods: present[(p.run, p.seq, p.attempt)] = true
  var current = initTable[(string, int), int]()
  for s in steps: current[(s.run, s.seq)] = s.attempt
  for s in steps:
    if s.state in ["STARTING", "RUNNING"] and now - s.claimedAt > grace and not present.getOrDefault((s.run, s.seq, s.attempt)):
      result.lost.add s
  for p in pods:
    if (p.run, p.seq) notin current or p.attempt < current[(p.run, p.seq)]:
      result.orphans.add p
