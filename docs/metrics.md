# Step metrics

Every step (build Pod) has three sources of metrics. The first one is always on, the others are switched on in Lua.

| Level | What | What the image and the application must provide | How to enable |
|---|---|---|---|
| 1. Container | CPU, throttling, memory (current and peak), limit, OOM kills, processes, threads, descriptors, disk | nothing | always |
| 2. Runtime | JVM: heap, GC, threads (read from `hsperfdata`) | a JVM with PerfData enabled (the default) | `metrics = {runtime = "jvm"}` |
| 3. Application | any metrics the application serves over HTTP itself | the application listens on a loopback port | `metrics = {scrape = {...}}` |

The shim does not link or contain language runtimes (JVM, Go, Python, Node): it reads only kernel files and HTTP responses. Whatever
is needed for metrics inside the application is added to the application itself (see "What the application needs").

## Lua syntax

```lua
ci.job({ image = "maven:3.9-eclipse-temurin-21",
         metrics = { runtime = "jvm" } },                    -- default for all steps of the job
  function(job)
    job:sh("mvn -B verify")                                  -- inherits the job's declaration
    job:sh("java -jar target/it.jar", {                      -- replaces it entirely
      metrics = {
        runtime = "jvm",
        scrape = {
          { url = "http://127.0.0.1:9404/metrics", name = "exporter", interval = "10s",
            include = { "jvm_*", "http_server_requests_*" } },
          { url = "http://127.0.0.1:8080/debug/vars", name = "gopprof", format = "expvar" },
        },
      },
    })
    job:sh("make lint", { metrics = false })                 -- this step has level 1 only
  end)
```

Fields of `ScrapeSpec`:

| Field | Meaning |
|---|---|
| `url` | only `http://127.0.0.1:<port>/...`, `http://localhost...` or `http://[::1]...`: the shim polls the Pod it runs in and nothing else |
| `name` | name of the source, `[a-z][a-z0-9_]*`, up to 32 characters; `app1`, `app2`... by default |
| `format` | `prometheus` (default) or `expvar` (Go `/debug/vars`) |
| `interval` | `1s`..`5m`, seconds or a string (`"10s"`, `"2m"`); 15 s by default |
| `timeout` | `1s`..`interval`; the smaller of `interval` and 5 s by default |
| `include` | metric names, `*` as a wildcard; empty = all |

Limits (checked in the sandbox before the step starts; a violation is a script error): at most 4 sources per step, at most 32 `include`
patterns, a pattern of up to 128 characters. The shim takes at most 200 series from a source and reads at most 1 MiB of a response.
Labels (`{area="heap"}`) are dropped, values of one metric with different labels are summed, `NaN`/`Inf` are ignored. The declaration is
written to the run journal (PIP-003) in canonical form, so the same script always gives the same bytes.

If a declaration is broken or a source does not answer, the step's command still runs: metrics cannot stop it. An unavailable source
shows in the metric `cinim_step_scrape_up{source="..."}` (0/1).

## What the application needs

The platform adds nothing to the image and does not change the application. If level 2 and 3 metrics are needed, they are enabled in the
image or the application, **not in the shim**:

**JVM (level 2, `runtime = "jvm"`).** The shim reads `/tmp/hsperfdata_<user>/<pid>`, the same file `jstat` reads. Nothing has to be
installed, but:
- PerfData counters must be on (they are by default; `-XX:-UsePerfData` turns them off);
- the JVM must run as the same user as the shim (`runAsUser: 1000` in the Pod) and they must share `/tmp`;
- the metrics are only what PerfData provides (heap/GC/classes/threads). For everything else (connection pools, custom metrics) add a
  JMX exporter or Micrometer and a `scrape` (level 3).

**JVM, level 3.** Any option that opens a loopback port:
- the [Prometheus JMX exporter](https://github.com/prometheus/jmx_exporter) as `-javaagent:jmx_prometheus_javaagent.jar=127.0.0.1:9404:config.yaml`
  (the jar goes into the image);
- Micrometer / Spring Boot Actuator `/actuator/prometheus` (listen on loopback in the test profile).

**Go.** Nothing can be read from inside the process without the application's help, so there are two ways:
- `format = "expvar"`: the application imports `_ "expvar"` and listens on loopback (`http.ListenAndServe("127.0.0.1:8080", nil)`);
  the shim converts `memstats` and numbers into `go_*`;
- [client_golang](https://github.com/prometheus/client_golang) with its own `/metrics` and `format = "prometheus"`.

**Python, Node.js, .NET, Rust and others.** Their Prometheus client library is needed (`prometheus_client`, `prom-client`,
`prometheus-net`, `metrics-exporter-prometheus`...); the application opens a loopback port and the step declares a `scrape`.

If the application needs a library, it is installed in its own image. Runtimes are **not linked statically into the shim** and no agents
are injected into foreign processes: this keeps the shim at about 0.5 MiB and creates no dependency on the JVM/Go version.

## What is visible from outside

Prometheus polls **only the core**: `GET /metrics` (Prometheus format 0.0.4). Step Pods are short-lived and are not polled, so there are
no per-Pod series, only aggregates. The shim sends its numbers to the core with its heartbeat (every 5 s and on every event).

The endpoint can be turned off in Helm (`metrics.enabled: false`, on by default; it sets `CINIM_METRICS=false` for the core): the route is then a 404. The router has the same switch (`ROUTER_METRICS`). The charts create the scrape objects of the Prometheus or the VictoriaMetrics operator with `metrics.monitor.enabled` (docs/deployment.md).

| Metric | What |
|---|---|
| `cinim_component_up{kind,id}`, `cinim_component_last_seen_seconds` | state of the components (controller, executor, shim, rqlite, log circuit) |
| `cinim_steps{state}`, `cinim_runs{state}` | number of steps and runs by state |
| `cinim_launch_gate_open` | 1 if the launch gate is open (RUN-015) |
| `cinim_inflight_steps` | steps whose shim is currently reporting |
| `cinim_inflight_<name>_sum` / `_max` | over the steps in flight: `cpu_throttled_seconds`, `memory_bytes`, `memory_peak_bytes`, `process_rss_bytes`, `pids`, `io_read_bytes`... |
| `cinim_finished_steps_total`, `cinim_step_cpu_seconds_total`, `cinim_step_oom_kills_total` | counters over finished steps |
| `cinim_inflight_app_metric_sum{source,metric}` | application metrics (`metrics.scrape`) and JVM (`source="jvm"`), summed over the steps in flight |
| `cinim_inflight_scrape_up{source}` | 1 if the endpoint answers for every step in flight |
| `cicd_process_rss_bytes{service="core"}` | memory of the core itself |

Details per component: `GET /api/v1/components`. The totals of a step (peak memory, CPU seconds, number of OOM kills) are written to its
state in rqlite (`steps.shim_json`, field `res`) and to the last line of the Pod log, so they survive the end of the step. An OOM kill is
the step's own failure, reason `oom_killed` (no retry). Modern Kubernetes (1.28 and later, cgroup v2) kills the whole container at once on
memory exhaustion, together with the shim: the verdict then comes from the Pod status (`OOMKilled`, exit code 137), not from the shim. If
the shim is alive (older nodes, cgroup v1), it sees the OOM counter rise in the cgroup itself and reports the same reason.

### JVM metrics (`runtime = "jvm"`)

The shim reads HotSpot counters from the file `/tmp/hsperfdata_<user>/<pid>` (the `jstat` format), without an agent or JMX:
`jvm_threads_current`, `jvm_threads_daemon`, `jvm_classes_loaded`, `jvm_heap_used_bytes`, `jvm_heap_capacity_bytes`,
`jvm_gc_collections_total`, `jvm_gc_time_seconds_total`, `jvm_metaspace_used_bytes`, `jvm_safepoints_total`, `jvm_up`.
If the file is missing (`-XX:-UsePerfData`, another user, another `/tmp`): `cinim_inflight_scrape_up{source="jvm"} 0` with
`runtime = "jvm"`, silence with `"auto"`.
