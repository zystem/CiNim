## Scraping the application's own metrics endpoint from inside the step's Pod (Lua `metrics.scrape`, docs/metrics.md).
## One thread cycles over the declared sources (at most 4, loopback only - the Lua sandbox checked the URLs). A source that does
## not answer is reported as not up, never as an error: metrics must not be able to hurt the step.
import std/[httpclient, times, os, atomics, strutils]
import appmetrics, shimlog, hsperf

var stopScraping*: Atomic[bool]

type ScrapeArgs* = tuple[decl: Declaration, pid: int]    ## pid: the build's process (to find its JVM's counters)

proc scrapeOnce(sc: Scrape): tuple[ok: bool, samples: seq[(string, float)]] =
  var http = newHttpClient(timeout = sc.timeout * 1000)
  defer: http.close()
  try:
    let body = http.getContent(sc.url)
    let parsed = if sc.format == "expvar": parseExpvar(body, sc.patterns) else: parsePrometheus(body, sc.patterns)
    result.ok = true
    for s in parsed: result.samples.add (s.name, s.value)
  except CatchableError:
    result.ok = false

proc scrapeLoop*(a: ScrapeArgs) {.thread.} =
  {.cast(gcsafe).}:
    var nextRuntime = 0.0
    var next = newSeq[float](a.decl.scrapes.len)       # when each source is due (epoch seconds); 0 = now
    while not stopScraping.load:
      let now = epochTime()
      if a.decl.runtime in ["jvm", "auto"] and now >= nextRuntime:
        # HotSpot's own counters (docs/metrics.md): no agent, no JMX; "auto" says nothing when there is no JVM
        let f = findFile(a.pid)
        if f.len > 0:
          try: setAppSamples("jvm", jvmMetrics(parsePerfData(readFile(f))), true)
          except CatchableError: setAppSamples("jvm", @[], false)
        elif a.decl.runtime == "jvm": setAppSamples("jvm", @[], false)
        nextRuntime = epochTime() + 5.0
      for i, sc in a.decl.scrapes:
        if now >= next[i]:
          let r = scrapeOnce(sc)
          setAppSamples(sc.name, r.samples, r.ok)
          next[i] = epochTime() + sc.interval.float
      sleep 250
