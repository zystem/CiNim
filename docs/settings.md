# Execution profile settings

The settings are changed in the UI (in the API this is `GET/PUT /api/v1/profile`; any subset of the fields can be sent) and apply to
steps that start after the change.

| Field | Range | Default | What it does |
|---|---|---|---|
| `infra_retries` | 0..20 | 3 | how many times a step is repeated when it is **known** that its command never started (the Pod was lost before the start). A step that started and whose outcome is unknown is never repeated |
| `log_max_bytes` | 0 or from 1 MiB | 1 GiB | how much log is kept per step. After that one marker line `[cicd: log truncated ...]` is written and the rest of the output is not kept. The step keeps running and its exit code does not change. `0` removes the limit |
| `log_spool_bytes` | 1 MiB..1 GiB | 10 MiB | the queue of undelivered log on the Pod's ephemeral storage. A full queue slows the build (back-pressure), nothing is lost |
| `log_hold_timeout` | 10..86400 s | 600 | how long a finished step waits for the log to be delivered and for the core's answer. After that: `logs_undelivered`, the command's result is kept |
| `liveness_timeout` | 30..3600 s | 300 | one timeout for two cases: the Pod did not start within this time (reason `start_timeout`) or the shim has been silent this long (reason `outcome_unknown`). In both cases the core finishes the step and removes the Pod; the step is not repeated. The count runs from the last sign of life or from the start of the core, whichever is later: a restart of the core does not kill steps |

The job controller's environment variables `CINIM_LOG_SPOOL_BYTES` and `CINIM_LOG_HOLD_TIMEOUT` remain defaults for the case when the core
did not pass the profile's setting; normally the profile applies.

## How they relate

- **The spool (10 MiB) and `log_max_bytes` solve different problems.** The spool bounds the queue of undelivered log: when delivery lags or
  is broken, the shim stops reading the build's output (back-pressure) and the Pod's memory and disk do not grow. While the log is being
  delivered the spool is almost empty and does not limit the total volume. The total volume is limited by `log_max_bytes`.
- **A step's timeout** (`timeout` in Lua) is enforced by the shim inside the Pod: when it expires the build gets SIGTERM, after
  `term-grace` (20 s) SIGKILL, reason `timeout`, code 124. This is a failure of the step itself, no retries.
- **`liveness_timeout` insures the rest**: the shim is silent because the node is lost or the network did not return. The core does not
  wait longer than that, which is exactly why a shim that lost the core reconnects and keeps working: five minutes are enough for it in
  most cases.

## Cluster requirements

The job controller assumes that **the namespace for steps is dedicated and holds nothing but step Pods** (by default the organisation's namespace `<prefix>-<org>`, `cinim-<org>` unless the prefix is changed; the objects the chart puts there for routing, an Ingress and its Service, are left alone). It decides itself which Pods in
it belong to it: a Pod that is not in its state is considered orphaned and is deleted. Do not put foreign Pods there. The rights needed are
`pods` (create, get, list, delete), `pods/log` (get), `pods/exec` (create; only to pull out an undelivered spool, if it is withheld that fallback
simply does not run), and `configmaps` and `secrets` (create, get) for delivering the shim and the CURVE keys.
