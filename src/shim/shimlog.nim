## The shim's account of itself in the Pod's own log (D-29) - and the only thing in it: the build's output never goes to the
## Pod log (it is masked, spooled and delivered by the log pipeline). Every transition is one short line
##   CICD-SHIM {"v":1,"n":<event number>,"t":<epoch ms>,"ev":"<event>", ...cumulative state...}
## and every line carries the whole state accumulated so far (common/shimstate.nim is the single definition of the vocabulary,
## the order of events and the wire form), so any surviving line restores everything up to that point and the last one
## restores everything - except the build log itself, which has its own path. Kubernetes keeps only a bounded, rotating
## tail of a container's log; the lines are few (a handful per step) and short, the final ones are written after the command
## has ended, and `n` shows whether the head was rotated away. The same state goes to core over ZeroMQ (heartbeat, StepReport)
## and into rqlite; the three are reconciled by `n`.
import std/[json, locks, times, options, tables]
import ../common/shimstate

export shimstate

var
  lock: Lock
  cur {.guard: lock.}: ShimState
  sink*: proc (s: string) {.gcsafe.}        ## where lines go; stdout unless a test replaces it
initLock(lock)

proc defaultSink(s: string) {.gcsafe.} =
  stdout.write s
  stdout.flushFile()

sink = defaultSink

proc initShimLog*(run: string; seq, attempt: int) =
  {.cast(gcsafe).}:
    withLock lock:
      cur = ShimState(run: run, seq: seq, attempt: attempt, phase: spStarting, logs: lsNone)

const noValue* = low(int)           ## "not set" for the integer fields of an update

proc event*(ev: ShimEvent; cmdExit = noValue; reason = ""; exitCode = noValue; lines = noValue; blocks = noValue;
            dropped = noValue) =
  ## Record a transition and write its line. The phase and the log state follow from the event (shimstate's tables);
  ## only what the event brings with it is passed.
  {.cast(gcsafe).}:
    withLock lock:
      inc cur.n
      cur.event = ev
      cur.phase = phaseAfter[ev]
      if logsAfter[ev].isSome: cur.logs = logsAfter[ev].get
      if ev == seCommandStarted: cur.cmdStarted = true
      if cmdExit != noValue: cur.cmdExit = some cmdExit
      if reason.len > 0: cur.reason = reason
      if exitCode != noValue: cur.exitCode = some exitCode
      if lines != noValue: cur.lines = lines
      if blocks != noValue: cur.blocks = blocks
      if dropped != noValue: cur.dropped = dropped
      sink(marker & $toJson(cur, int64(epochTime() * 1000)) & "\n")

var
  latestMetrics {.guard: lock.}: seq[(string, float)]
  appSamples {.guard: lock.}: Table[string, seq[(string, float)]]   ## per scrape source: what the application's endpoint last returned

proc setAppSamples*(source: string; samples: seq[(string, float)]; up: bool) =
  ## What the step's own endpoint (Lua `metrics.scrape`) returned, under the source's name; `up` says whether the last
  ## attempt worked. Reported to core as "app:<source>:<metric>" and "scrape_up:<source>".
  {.cast(gcsafe).}:
    withLock lock:
      var all = @[("scrape_up:" & source, if up: 1.0 else: 0.0)]
      for (n, v) in samples: all.add ("app:" & source & ":" & n, v)
      appSamples[source] = all

proc setResources*(cpuSec: float; memPeak: int64; oomKills: int; metrics: seq[(string, float)]) =
  ## the container's resource use (resmetrics.nim): the totals ride along with the next Pod-log line and the verdict, the full
  ## list goes to core with every heartbeat
  {.cast(gcsafe).}:
    withLock lock:
      cur.cpuSec = cpuSec
      cur.memPeak = memPeak
      cur.oomKills = oomKills
      latestMetrics = metrics

proc currentMetrics*(): seq[(string, float)] =
  {.cast(gcsafe).}:
    withLock lock:
      result = latestMetrics
      for _, all in appSamples: result.add all

proc currentState*(): ShimState =
  {.cast(gcsafe).}:
    withLock lock: result = cur

proc setCounters*(lines, blocks, dropped: int; truncated = false) =
  ## Delivery counters change without a transition; they ride along with the next line and with every heartbeat.
  {.cast(gcsafe).}:
    withLock lock:
      cur.lines = lines
      cur.blocks = blocks
      cur.dropped = dropped
      cur.truncated = truncated
