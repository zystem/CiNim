## The liveness of the core from the inside (`GET /healthz`). A thread of the core that has not gone round its loop for much longer than the loop takes is stuck, and a core with a stuck
## thread is alive to the probe and useless to everything else: the log is not taken, the reports are not answered. Each long-lived thread calls `beat` once per round; the probe asks
## which have not for longer than their limit and answers 503, so that Kubernetes restarts the Pod. A thread that has not started is not judged. The process itself ends if a thread dies
## (an exception nobody caught), so only a thread that is alive and not moving is found here.
import std/[atomics, json, times]

type Beat* = enum
  bStream = "stream", bLogIngest = "log-ingest", bStepReport = "step-report", bArtifactIngest = "artifact-ingest", bWatchdog = "watchdog", bTriggers = "triggers",
  bReconciler = "reconciler", bLogGate = "log-gate", bStatus = "status", bLogBook = "log-bookkeeping"

const limits: array[Beat, float] = [
  60.0,    # stream: the I/O thread goes round in milliseconds
  120.0,   # log ingest: a round waits 200 ms for a message; one message may take a few database calls of 15 s
  120.0,   # step report
  180.0,   # artifact ingest: the calls to the storage module wait longer
  300.0,   # watchdog: a pass is rqlite and the Kubernetes API, every five seconds
  300.0,   # triggers
  900.0,   # reconciler: a pass is the Kubernetes API for every organisation
  120.0,   # log gate: a poll of the log store
  120.0,   # status: the state of the shims (D-75), a round waits for a message and may take a few database calls
  120.0]   # log bookkeeping (D-75): the rows of log_streams, written apart from the log

var seen: array[Beat, Atomic[int64]]       ## milliseconds since the epoch of the last round of each thread; 0: not started

proc beatAt*(b: Beat; now: float) = seen[b].store(int64(now * 1000))
proc beat*(b: Beat) = beatAt(b, epochTime())

proc stuck*(now: float): seq[tuple[name: string, ageSeconds: float]] =
  ## the threads whose last round is older than their limit
  for b in Beat:
    let at = seen[b].load
    if at == 0: continue
    let age = now - float(at) / 1000.0
    if age > limits[b]: result.add (name: $b, ageSeconds: age)

proc livenessJson*(now: float): tuple[ok: bool, body: JsonNode] =
  let s = stuck(now)
  if s.len == 0: return (true, %*{"status": "ok"})
  var threads = newJArray()
  for (n, a) in s: threads.add %*{"thread": n, "silent_seconds": int(a)}
  (false, %*{"status": "stuck", "threads": threads})

proc resetBeats*() =
  ## for tests
  for b in Beat: seen[b].store(0)
