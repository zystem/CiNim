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

## Core environment for the `multi` mode

The shard's identity and its link to the organisation router (SHD-006). Without `CINIM_ROUTER_URL` the core works alone (`single` mode):
the organisation drop-down holds the organisations of this shard and the slug is checked against them only.

| Variable | Default | What it does |
|---|---|---|
| `CINIM_SHARD` | `001` | the name of the shard: digits only, up to 16, immutable; part of the namespace name `<prefix>-<shard>-<slug>` |
| `CINIM_NAMESPACE_PREFIX` | `cinim` | the prefix of the namespaces of the organisations |
| `CINIM_ROUTER_URL` | empty | the router's base URL with its base path, `http://` or `https://`, no trailing slash. `https` needs a core built with `-d:ssl` (the core image carries OpenSSL); a core without it refuses to start with an https URL |
| `CINIM_ROUTER_KEY` | empty | the key shared with the router (`ROUTER_KEY`); required when `CINIM_ROUTER_URL` is set |
| `CINIM_PUBLIC_URL` | empty | `https://<domain><basePath>`, the base of the organisation URLs that the core registers and shows |
| `CINIM_ROUTER_INTERVAL` | 60 | seconds between two rounds: the core posts its organisations and reads the router's list |
| `CINIM_CORE_ID` | the shard name | the name under which the core registers at the router; it must differ between cores |
| `CINIM_METRICS` | `true` | `false` makes `/metrics` answer 404 (the Helm value `metrics.enabled`) |

When the router does not answer, the core keeps the last list and records the error (`GET /api/v1/router`); a slug is then checked against
the last list, and `checked_against_router` in the answer of `POST /api/v1/organizations` is false if no list was ever received. A slug that
two cores hold gives the alert `duplicate_slug` in `GET /api/v1/router`.

## Cluster requirements

The job controller assumes that **the namespace for steps is dedicated and holds nothing but step Pods** (by default the organisation's namespace `<prefix>-<shard>-<org>`, for example `cinim-001-acme`; the objects the core creates there, a RoleBinding, a ResourceQuota, a LimitRange and a NetworkPolicy, are left alone). It decides itself which Pods in
it belong to it: a Pod that is not in its state is considered orphaned and is deleted. Do not put foreign Pods there. The rights needed are
`pods` (create, get, list, delete), `pods/log` (get), `pods/exec` (create; only to pull out an undelivered spool, if it is withheld that fallback
simply does not run), and `configmaps` and `secrets` (create, get) for delivering the shim and the CURVE keys.
