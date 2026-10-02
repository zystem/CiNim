## Resource use of the steps in flight, as the shims report it with every heartbeat (D-29, docs/metrics.md). Pods are
## short-lived and numerous, so Prometheus never scrapes them and there is no series per Pod: core keeps each step's latest
## numbers in memory and exposes aggregates - gauges over the steps running now, counters that grow by each finished step.
import std/[tables, locks, strutils, algorithm]

type
  Sample = tuple[name: string, value: float]

var
  lock: Lock
  inflight {.guard: lock.}: Table[string, seq[Sample]]
  totals {.guard: lock.}: Table[string, float]      ## counters over finished steps (reset when core restarts, as counters may)
  finished {.guard: lock.}: int
initLock(lock)

proc update*(key: string; metrics: seq[Sample]) =
  {.cast(gcsafe).}:
    withLock lock: inflight[key] = metrics

proc finish*(key: string) =
  ## the step is over: its final numbers join the counters
  {.cast(gcsafe).}:
    withLock lock:
      if key in inflight:
        for (n, v) in inflight[key]:
          if n.endsWith("_total"): totals[n] = totals.getOrDefault(n) + v
        inflight.del key
        inc finished

proc render*(): string =
  {.cast(gcsafe).}:
    withLock lock:
      var sums, maxes: Table[string, float]
      var upMin: Table[string, float]                              # per scrape source: 1 only if every step's scrape works
      for _, ms in inflight:
        for (n, v) in ms:
          if n.startsWith("scrape_up:"):
            upMin[n["scrape_up:".len .. ^1]] = min(upMin.getOrDefault(n["scrape_up:".len .. ^1], 1.0), v)
          else:
            sums[n] = sums.getOrDefault(n) + v
            maxes[n] = max(maxes.getOrDefault(n), v)
      result = "# HELP cinim_inflight_steps Steps whose shim is reporting resource use now.\n# TYPE cinim_inflight_steps gauge\n" &
               "cinim_inflight_steps " & $inflight.len & "\n"
      var names: seq[string]
      for n in sums.keys: names.add n
      names.sort()
      for n in names:
        if n.startsWith("app:"):
          # the application's own metrics (Lua metrics.scrape): "app:<source>:<metric>", summed over the steps running now
          let parts = n.split(':', 2)
          if parts.len == 3:
            result.add "cinim_inflight_app_metric_sum{source=\"" & parts[1] & "\",metric=\"" & parts[2] & "\"} " &
                       formatFloat(sums[n], ffDecimal, 3) & "\n"
          continue
        if n.endsWith("_total"): continue                         # monotonic per step: summed as gauges below under an in-flight name
        result.add "cinim_inflight_" & n["cinim_step_".len .. ^1] & "_sum " & formatFloat(sums[n], ffDecimal, 1) & "\n"
        result.add "cinim_inflight_" & n["cinim_step_".len .. ^1] & "_max " & formatFloat(maxes[n], ffDecimal, 1) & "\n"
      var sources: seq[string]
      for s in upMin.keys: sources.add s
      sources.sort()
      if sources.len > 0: result.add "# HELP cinim_inflight_scrape_up 1 if every running step's metrics endpoint answers.\n# TYPE cinim_inflight_scrape_up gauge\n"
      for s in sources: result.add "cinim_inflight_scrape_up{source=\"" & s & "\"} " & formatFloat(upMin[s], ffDecimal, 0) & "\n"
      var tnames: seq[string]
      for n in totals.keys: tnames.add n
      tnames.sort()
      result.add "# TYPE cinim_finished_steps_total counter\ncinim_finished_steps_total " & $finished & "\n"
      for n in tnames:
        result.add "# TYPE " & n & " counter\n" & n & " " & formatFloat(totals[n], ffDecimal, 3) & "\n"
