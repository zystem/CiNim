## What the push channel of the core says about itself (docs/metrics.md): how many controllers are connected, how many frames go each way, how long
## a report or a push takes, how long a kick waits before the hub looks at it, and how much of its time the hub is busy. Counters, gauges and
## histograms with fixed buckets, in fixed arrays under one lock, so that every thread of the hub may update them and nothing is allocated across threads.
import std/[locks, strutils]

const buckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]

type
  Hist* = enum
    hReport      ## a report: from the frame read to its answer sent and the push after it
    hPush        ## a look at one controller for work (the database queries and the claim)
    hKickWait    ## from a kick (a step made, a limit changed) to a worker starting to look at it
    hFrameWait   ## from a frame being read from the socket to a worker starting on it (the queue of the pool)
  Metric* = enum
    mFramesIn, mFramesOut
    mSendFailures, mResent, mRequeuedSteps, mPushedSteps
    mDroppedPeers
    mBusyMicros  ## time the hub spent handling frames and kicks, in microseconds
  Gauge* = enum
    gPeers, gUnacked, gQueued, gWorkers

const
  maxSlots = 64                                                 # the most workers; a gauge of the pool is the sum of the workers' own
  histNames: array[Hist, string] = ["cinim_stream_report_seconds", "cinim_stream_push_seconds", "cinim_stream_kick_wait_seconds",
                                    "cinim_stream_frame_wait_seconds"]
  histHelp: array[Hist, string] = ["time to take in a report and answer it", "time to look at one controller for work",
                                   "time from a kick to a worker looking at it", "time from a frame being read to a worker starting on it"]
  gaugeNames: array[Gauge, string] = ["cinim_stream_peers", "cinim_stream_unacked_frames", "cinim_stream_queued_messages", "cinim_stream_workers"]
  gaugeHelp: array[Gauge, string] = ["controllers connected to the push channel", "numbered frames sent to controllers and not acknowledged yet",
                                     "messages waiting in the queues of the workers", "workers of the push channel"]
  kinds = ["report", "ping", "work", "resync", "other"]        # the label of the frame counters
  reasons = ["replaced", "silent"]                              # the label of the dropped peers

var
  lock: Lock
  hCounts: array[Hist, array[buckets.len + 1, int64]]
  hSums: array[Hist, float]
  framesIn, framesOut: array[kinds.len, int64]
  dropped: array[reasons.len, int64]
  singles: array[Metric, int64]
  gauges: array[Gauge, array[maxSlots, float]]
initLock(lock)

func kindIndex(kind: string): int =
  for i, k in kinds:
    if k == kind: return i
  kinds.len - 1

proc resetHubMetrics*() =
  {.cast(gcsafe).}:
    withLock lock:
      for h in Hist:
        for i in 0 .. buckets.len: hCounts[h][i] = 0
        hSums[h] = 0
      for i in 0 ..< kinds.len:
        framesIn[i] = 0
        framesOut[i] = 0
      for i in 0 ..< reasons.len: dropped[i] = 0
      for m in Metric: singles[m] = 0
      for g in Gauge:
        for i in 0 ..< maxSlots: gauges[g][i] = 0

proc observe*(h: Hist; seconds: float) =
  {.cast(gcsafe).}:
    withLock lock:
      var placed = false
      for i, b in buckets:
        if seconds <= b:
          inc hCounts[h][i]
          placed = true
          break
      if not placed: inc hCounts[h][buckets.len]
      hSums[h] += seconds

proc count*(m: Metric; label = ""; n = 1) =
  ## `label`: the kind of frame for mFramesIn / mFramesOut, the reason for mDroppedPeers
  {.cast(gcsafe).}:
    withLock lock:
      case m
      of mFramesIn: framesIn[kindIndex(label)] += n
      of mFramesOut: framesOut[kindIndex(label)] += n
      of mDroppedPeers:
        for i, r in reasons:
          if r == label: dropped[i] += n
      else: singles[m] += n

proc setGauge*(g: Gauge; v: float; slot = 0) =
  ## `slot`: the worker that sets it; the gauge shown is the sum over the slots
  {.cast(gcsafe).}:
    withLock lock: gauges[g][min(max(slot, 0), maxSlots - 1)] = v

func fmt(v: float): string =
  if v == v.int.float: $v.int else: formatFloat(v, ffDecimal, 6).strip(chars = {'0'}, leading = false).strip(chars = {'.'}, leading = false)

proc renderHubMetrics*(): string =
  {.cast(gcsafe).}:
    withLock lock:
      for g in Gauge:
        var total = 0.0
        for i in 0 ..< maxSlots: total += gauges[g][i]
        result.add "# HELP " & gaugeNames[g] & " " & gaugeHelp[g] & "\n# TYPE " & gaugeNames[g] & " gauge\n" & gaugeNames[g] & " " & fmt(total) & "\n"
      result.add "# HELP cinim_stream_frames_total frames of the push channel\n# TYPE cinim_stream_frames_total counter\n"
      for i, k in kinds:
        result.add "cinim_stream_frames_total{direction=\"in\",kind=\"" & k & "\"} " & $framesIn[i] & "\n"
      for i, k in kinds:
        result.add "cinim_stream_frames_total{direction=\"out\",kind=\"" & k & "\"} " & $framesOut[i] & "\n"
      const singleNames: array[Metric, string] = ["", "", "cinim_stream_send_failures_total", "cinim_stream_resent_frames_total",
        "cinim_stream_requeued_steps_total", "cinim_stream_pushed_steps_total", "", "cinim_stream_busy_seconds_total"]
      for m in [mSendFailures, mResent, mRequeuedSteps, mPushedSteps]:
        result.add "# TYPE " & singleNames[m] & " counter\n" & singleNames[m] & " " & $singles[m] & "\n"
      result.add "# TYPE cinim_stream_dropped_peers_total counter\n"
      for i, r in reasons:
        result.add "cinim_stream_dropped_peers_total{reason=\"" & r & "\"} " & $dropped[i] & "\n"
      result.add "# TYPE cinim_stream_busy_seconds_total counter\ncinim_stream_busy_seconds_total " & fmt(singles[mBusyMicros].float / 1e6) & "\n"
      for h in Hist:
        result.add "# HELP " & histNames[h] & " " & histHelp[h] & "\n# TYPE " & histNames[h] & " histogram\n"
        var cum = 0'i64
        for i, b in buckets:
          cum += hCounts[h][i]
          result.add histNames[h] & "_bucket{le=\"" & fmt(b) & "\"} " & $cum & "\n"
        cum += hCounts[h][buckets.len]
        result.add histNames[h] & "_bucket{le=\"+Inf\"} " & $cum & "\n"
        result.add histNames[h] & "_sum " & fmt(hSums[h]) & "\n"
        result.add histNames[h] & "_count " & $cum & "\n"
