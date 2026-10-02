import std/[unittest, strutils]
import core/stepmetrics

suite "step metrics aggregation":
  test "gauges over the steps in flight, counters over the finished ones, the application's own metrics by source":
    update("r1/0/1", @[("cinim_step_memory_bytes", 100.0), ("cinim_step_cpu_seconds_total", 2.0),
                       ("app:jvm:jvm_threads_current", 10.0), ("scrape_up:jvm", 1.0)])
    update("r2/0/1", @[("cinim_step_memory_bytes", 300.0), ("cinim_step_cpu_seconds_total", 5.0),
                       ("app:jvm:jvm_threads_current", 32.0), ("scrape_up:jvm", 0.0)])
    let t = render()
    check "cinim_inflight_steps 2" in t
    check "cinim_inflight_memory_bytes_sum 400.0" in t and "cinim_inflight_memory_bytes_max 300.0" in t
    check "cinim_inflight_app_metric_sum{source=\"jvm\",metric=\"jvm_threads_current\"} 42.000" in t
    check "cinim_inflight_scrape_up{source=\"jvm\"} 0" in t               # one step's endpoint does not answer
    finish("r1/0/1")
    let t2 = render()
    check "cinim_inflight_steps 1" in t2
    check "cinim_step_cpu_seconds_total 2.000" in t2 and "cinim_finished_steps_total 1" in t2
    finish("r2/0/1")
    check "cinim_step_cpu_seconds_total 7.000" in render()
