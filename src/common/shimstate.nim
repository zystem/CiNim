## The shim's state, in one vocabulary used everywhere (D-29). Three places describe what the shim is doing, and they
## must never disagree:
##   1. the Pod log - one `CICD-SHIM {...}` line per transition (shimlog.nim writes, the job-controller reads);
##   2. ZeroMQ - the same state in LogBatch.status (heartbeat) and in StepReport (shim -> core);
##   3. rqlite - steps.shim_n / shim_phase / shim_json, and steps.state derived from it.
## All three carry the same `ShimState`, numbered by the event that produced it (`n`, +1 per event). A reader that sees a
## state with a higher `n` than it knows replaces its picture; a lower or equal `n` is old news and ignored - so the sources
## can arrive in any order, through any path, repeated, and still converge. This module is std-only: the event table, the
## allowed order of events, the mapping to step states and the merge rule are data + pure functions, unit-tested, and
## shared by the shim, the job-controller and core.
import std/[json, strutils, options, tables]
import states

type
  ShimEvent* = enum
    seStarted = "started"                   ## the shim is up, the command is not yet
    seCommandStarted = "command_started"
    seStopping = "stopping"                 ## timeout or SIGTERM: the build was asked to stop
    seKilling = "killing"                   ## ... and did not, after the grace period: SIGKILL
    seCommandExited = "command_exited"
    seLogsDelivering = "logs_delivering"    ## waiting (up to log_hold_timeout) for the log to reach vlagent
    seLogsDelivered = "logs_delivered"
    seLogsUndelivered = "logs_undelivered"
    seDone = "done"                         ## the verdict; the last line the shim writes

  ShimPhase* = enum
    spStarting = "starting", spRunning = "running", spStopping = "stopping", spDraining = "draining", spDone = "done"

  LogsState* = enum
    lsNone = "none", lsDraining = "draining", lsDelivered = "delivered", lsUndelivered = "undelivered"

  ShimState* = object
    run*: string
    seq*, attempt*: int
    n*: int                      ## number of the event that produced this state (0 = nothing yet)
    event*: ShimEvent
    phase*: ShimPhase
    cmdStarted*: bool
    cmdExit*: Option[int]        ## the command's exit code once it has exited
    logs*: LogsState
    lines*, blocks*, dropped*: int
    truncated*: bool             ## the step's log reached log_max_bytes and was cut (with a marker line)
    cpuSec*: float               ## CPU the step's container used so far (cgroup), seconds
    memPeak*: int64              ## its peak memory, bytes
    oomKills*: int               ## OOM kills in its cgroup
    reason*: string              ## once stopping/done: ok | failed | timeout | terminated | logs_undelivered | env_rejected | ...
    exitCode*: Option[int]       ## the shim's own exit code once done

  Outcome* = enum
    oNone                        ## not over
    oSucceeded
    oFailed                      ## the step's own failure (non-zero exit, env_rejected, ...)
    oTimedOut
    oUnknown                     ## the command was cut off from outside (SIGTERM): what it left behind is unknown

const
  marker* = "CICD-SHIM "

  # What each event leaves the shim in. The writer (shimlog.event) and every reader use this one table.
  phaseAfter*: array[ShimEvent, ShimPhase] = [
    seStarted: spStarting, seCommandStarted: spRunning, seStopping: spStopping, seKilling: spStopping,
    seCommandExited: spDraining, seLogsDelivering: spDraining, seLogsDelivered: spDraining,
    seLogsUndelivered: spDraining, seDone: spDone]

  logsAfter*: array[ShimEvent, Option[LogsState]] = [
    seStarted: none(LogsState), seCommandStarted: none(LogsState), seStopping: none(LogsState),
    seKilling: none(LogsState), seCommandExited: none(LogsState), seLogsDelivering: some(lsDraining),
    seLogsDelivered: some(lsDelivered), seLogsUndelivered: some(lsUndelivered), seDone: none(LogsState)]

func successors*(e: ShimEvent): set[ShimEvent] =
  ## The only orders in which the shim produces events. (Intermediate ones may be missing from what a reader sees - a Pod
  ## log is rotated, a heartbeat is a snapshot - but never out of order.)
  case e
  of seStarted: {seCommandStarted, seDone}               # done directly: the environment was rejected before the command
  of seCommandStarted: {seStopping, seCommandExited}
  of seStopping: {seKilling, seCommandExited}
  of seKilling: {seCommandExited}
  of seCommandExited: {seLogsDelivering}
  of seLogsDelivering: {seLogsDelivered, seLogsUndelivered}
  of seLogsDelivered, seLogsUndelivered: {seDone}
  of seDone: {}

func reachable*(a, b: ShimEvent): bool =
  ## Can `b` follow `a`, directly or through events a reader did not see?
  if a == b: return true
  var seen: set[ShimEvent] = {a}
  var frontier: set[ShimEvent] = {a}
  while frontier.card > 0:
    var next: set[ShimEvent]
    for e in frontier:
      for s in successors(e):
        if s notin seen:
          seen.incl s
          next.incl s
    if b in next: return true
    frontier = next
  false

func outcomeOf*(s: ShimState): Outcome =
  ## The step's result as far as the shim's state tells it. Only meaningful once the command has exited.
  if s.cmdExit.isNone and s.phase != spDone: return oNone
  case s.reason
  of "timeout": oTimedOut
  of "terminated": oUnknown
  of "ok": oSucceeded
  of "": (if s.cmdExit.isSome and s.phase == spDraining: (if s.cmdExit.get == 0: oSucceeded else: oFailed) else: oNone)
  of "logs_undelivered", "artifacts_undelivered": (if s.cmdExit.get(1) == 0: oSucceeded else: oFailed)    # the result stands, the log or the artifacts are incomplete
  else: oFailed

func stepStateOf*(s: ShimState): StepState =
  ## The state machine's step state this shim state implies (states.nim). Starting/running follow the shim's phase; the
  ## final states follow the outcome - and only once the shim is done, because until then core has not yet been told the
  ## verdict (the log may still be in flight).
  case s.phase
  of spStarting: ssStarting
  of spRunning, spStopping, spDraining: ssRunning
  of spDone:
    case outcomeOf(s)
    of oSucceeded: ssSucceeded
    of oTimedOut: ssTimedOut
    of oUnknown: ssLost
    else: ssFailed

func newer*(known, incoming: ShimState): bool =
  ## The merge rule: a state replaces the one we hold only when it is from a later event.
  incoming.n > known.n

# ------------------------------------------------------------------ wire form: the Pod-log line and the JSON stored in rqlite

proc toJson*(s: ShimState; t: int64): JsonNode =
  result = %*{"v": 1, "n": s.n, "t": t, "ev": $s.event, "run": s.run, "seq": s.seq, "at": s.attempt, "ph": $s.phase,
              "cmd": {"started": s.cmdStarted}, "logs": $s.logs, "lines": s.lines, "blocks": s.blocks, "dropped": s.dropped}
  if s.truncated: result["trunc"] = %true
  if s.cpuSec > 0 or s.memPeak > 0 or s.oomKills > 0:
    result["res"] = %*{"cpu_s": s.cpuSec, "mem_peak": s.memPeak, "oom": s.oomKills}
  if s.cmdExit.isSome: result["cmd"]["exit"] = %s.cmdExit.get
  if s.reason.len > 0: result["reason"] = %s.reason
  if s.exitCode.isSome: result["exit"] = %s.exitCode.get

proc fromJson*(j: JsonNode): Option[ShimState] =
  ## Anything that is not a well-formed state (an unknown event or phase included) is none, never an exception.
  try:
    if j.kind != JObject: return
    let ev = parseEnum[ShimEvent](j["ev"].getStr)
    var s = ShimState(run: j{"run"}.getStr, seq: j{"seq"}.getInt, attempt: j{"at"}.getInt, n: j["n"].getInt, event: ev,
                      phase: parseEnum[ShimPhase](j["ph"].getStr), cmdStarted: j{"cmd", "started"}.getBool,
                      logs: parseEnum[LogsState](j{"logs"}.getStr("none")), lines: j{"lines"}.getInt,
                      blocks: j{"blocks"}.getInt, dropped: j{"dropped"}.getInt, truncated: j{"trunc"}.getBool, reason: j{"reason"}.getStr,
                      cpuSec: j{"res", "cpu_s"}.getFloat, memPeak: j{"res", "mem_peak"}.getBiggestInt, oomKills: j{"res", "oom"}.getInt)
    if j{"cmd", "exit"} != nil: s.cmdExit = some j{"cmd", "exit"}.getInt
    if j{"exit"} != nil: s.exitCode = some j{"exit"}.getInt
    if s.n < 1: return
    result = some s
  except CatchableError:
    discard

proc parseLine*(line: string): Option[ShimState] =
  if not line.startsWith(marker): return
  try: fromJson(parseJson(line[marker.len .. ^1]))
  except CatchableError: none(ShimState)

proc lastState*(logTail: string): Option[ShimState] =
  ## The newest state in a Pod-log tail. (A step may print something that looks like one; the shim's own lines are the
  ## ones with the highest `n`, and the final ones are the last thing written.)
  for l in logTail.splitLines:
    let p = parseLine(l)
    if p.isSome and (result.isNone or p.get.n >= result.get.n): result = p
