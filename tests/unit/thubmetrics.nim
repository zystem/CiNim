## RUN-016 / docs/metrics.md: what the push channel of the core exposes about itself - counters, gauges and histograms with fixed buckets -
## safe to update from many threads. Pure, no sockets.
import std/[unittest, strutils]
import core/hubmetrics

proc has(text, line: string): bool = line in text.splitLines

suite "RUN-016 hub metrics: counters and gauges":
  test "a counter counts, a gauge is set":
    resetHubMetrics()
    count(mFramesIn, "report")
    count(mFramesIn, "report")
    count(mFramesIn, "ping")
    count(mSendFailures)
    setGauge(gPeers, 3)
    let t = renderHubMetrics()
    check t.has("cinim_stream_frames_total{direction=\"in\",kind=\"report\"} 2")
    check t.has("cinim_stream_frames_total{direction=\"in\",kind=\"ping\"} 1")
    check t.has("cinim_stream_send_failures_total 1")
    check t.has("cinim_stream_peers 3")
  test "a gauge of the pool is the sum of what the workers set":
    resetHubMetrics()
    setGauge(gPeers, 2, slot = 0)
    setGauge(gPeers, 5, slot = 3)
    setGauge(gPeers, 1, slot = 3)        # a worker sets its own again: replaces its old value
    check renderHubMetrics().has("cinim_stream_peers 3")
  test "every metric has a type line, and a family that was not touched is still shown with zero":
    resetHubMetrics()
    let t = renderHubMetrics()
    check "# TYPE cinim_stream_peers gauge" in t
    check "# TYPE cinim_stream_frames_total counter" in t
    check "# TYPE cinim_stream_report_seconds histogram" in t
    check t.has("cinim_stream_send_failures_total 0")

suite "RUN-016 hub metrics: histograms":
  test "an observation goes into its bucket and every bucket above it (cumulative), the sum and the count":
    resetHubMetrics()
    observe(hReport, 0.003)        # below the first bucket
    observe(hReport, 0.04)         # 0.05
    observe(hReport, 0.04)
    observe(hReport, 30.0)         # above every bucket: only +Inf
    let t = renderHubMetrics()
    check t.has("cinim_stream_report_seconds_bucket{le=\"0.005\"} 1")
    check t.has("cinim_stream_report_seconds_bucket{le=\"0.025\"} 1")
    check t.has("cinim_stream_report_seconds_bucket{le=\"0.05\"} 3")
    check t.has("cinim_stream_report_seconds_bucket{le=\"10\"} 3")
    check t.has("cinim_stream_report_seconds_bucket{le=\"+Inf\"} 4")
    check t.has("cinim_stream_report_seconds_count 4")
    check "cinim_stream_report_seconds_sum 30.083" in t
  test "a histogram that has seen nothing shows zero counts":
    resetHubMetrics()
    let t = renderHubMetrics()
    check t.has("cinim_stream_kick_wait_seconds_count 0")
    check t.has("cinim_stream_kick_wait_seconds_bucket{le=\"+Inf\"} 0")

suite "RUN-016 hub metrics: threads":
  test "many threads updating at once lose nothing":
    resetHubMetrics()
    var ths: array[4, Thread[int]]
    proc worker(n: int) {.thread.} =
      for i in 0 ..< 500:
        count(mFramesOut, "work")
        observe(hPush, 0.01)
    for i in 0 ..< 4: createThread(ths[i], worker, i)
    joinThreads(ths)
    let t = renderHubMetrics()
    check t.has("cinim_stream_frames_total{direction=\"out\",kind=\"work\"} 2000")
    check t.has("cinim_stream_push_seconds_count 2000")
