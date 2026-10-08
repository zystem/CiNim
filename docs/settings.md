# Execution profile settings

The settings are changed in the UI (in the API this is `GET/PUT /api/v1/profile`; any subset of the fields can be sent) and apply to
steps that start after the change. Every organisation has a profile of its own (made on its first run), addressed with `?organization=<slug>`; without it the call concerns the shard's default profile.

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

## Job controller environment

| Variable | Default | What it does |
|---|---|---|
| `CINIM_POD_RETENTION_READ` | 0 | seconds a finished step Pod is kept when core has its result and its log was delivered (nothing is left in it that the platform does not have); 0 removes it at once. Raise it to look at Pods with `kubectl` |
| `CINIM_POD_RETENTION_UNREAD` | 1209600 (14 days) | seconds a Pod is kept, a success or not, when core could not read from it what it needs: its log was not delivered or its end is unknown (the node was lost, the shim went silent). Core shows an alert for each such Pod (`GET /api/v1/alerts`, `cinim_unread_pods`) until the controller removes it |
| `CINIM_RUN_STORAGE` | `off` | `on`: the controller makes a PersistentVolumeClaim per run and mounts it in the Pod of every step (`/cicd/workspace`, `/cicd/state`), so that the steps of a run share files and the env file (STO-001). The core sets it from the Helm value `runStorage.enabled`; `off` gives every Pod an emptyDir of its own |
| `CINIM_RUN_STORAGE_SIZE` | `5Gi` | the request of a run's claim |
| `CINIM_RUN_STORAGE_CLASS` | the cluster's default class | its StorageClass |
| `CINIM_RUN_STORAGE_ACCESS` | `ReadWriteOnce` | `ReadWriteMany` if the class has it; with `ReadWriteOnce` the Pods of a run are kept on one node (pod affinity over the run label) |

## Core environment for the `multi` mode

The shard's identity and its link to the organisation router (SHD-006). Without `CINIM_ROUTER_URL` the core works alone (`single` mode):
the organisation drop-down holds the organisations of this shard and the slug is checked against them only.

| Variable | Default | What it does |
|---|---|---|
| `CINIM_ADMIN_TOKEN` | empty | a token of the operator's own for the shard's administrator (IAM-003): the chart value `auth.adminToken` (a Secret `cinim-admin-token` is made of it) or the key `token` of the Secret `auth.adminTokenSecret`. It is compared, not stored, and the API cannot rotate it. Empty: with `CINIM_AUTH=on` (the chart sets it when `auth.enabled`) the first start makes a token and writes it to the log, to be changed at first use; with neither the API is open and the core says so at start |
| `CINIM_SECRETS_KEY_FILE` | empty | the master key of the step secrets: a file of 64 hexadecimal digits (the chart value `secrets.keySecret` mounts a Secret and sets this). Empty: derived from the core's CURVE key. Keep it apart from the database backup; the core refuses secrets when it is not the key that sealed what the database holds |
| `CINIM_KEKD_URL` | empty | the key service that holds the master key of the step secrets, `http://host:port` or `https://host:port` (the chart value `secrets.kekd.url`; docs/hardware-key.md). When set it is used instead of the key file. The core does not wait for it at start: it asks every 15 s and the secrets answer `secrets_unavailable` meanwhile |
| `CINIM_KEKD_CA`, `CINIM_KEKD_CERT`, `CINIM_KEKD_KEY` | empty | the PEM files of the mutual TLS to the key service (the chart mounts the Secret `secrets.kekd.tlsSecret` with `ca.crt`, `tls.crt`, `tls.key`) |
| `CINIM_KEKD_TIMEOUT_MS` | 5000 | how long one call to the key service may take before it counts as not answering |
| `CINIM_SECRETS_DEK_CACHE` | 600 | seconds the opened data key of an organisation is kept in the core's memory, so that steps that start while the key service is down still get their secrets; 0 keeps nothing |
| `CINIM_SHARD` | `001` | the name of the shard: digits only, up to 16, immutable; part of the namespace name `<prefix>-<shard>-<slug>` |
| `CINIM_NAMESPACE_PREFIX` | `cinim` | the prefix of the namespaces of the organisations |
| `CINIM_ROUTER_URL` | empty | the router's base URL with its base path, `http://` or `https://`, no trailing slash. `https` needs a core built with `-d:ssl` (the core image carries OpenSSL); a core without it refuses to start with an https URL |
| `CINIM_ROUTER_KEY` | empty | the key shared with the router (`ROUTER_KEY`); required when `CINIM_ROUTER_URL` is set |
| `CINIM_PUBLIC_URL` | empty | `https://<domain><basePath>`, the base of the organisation URLs that the core registers and shows |
| `CINIM_ROUTER_INTERVAL` | 60 | seconds between two rounds: the core posts its organisations and reads the router's list |
| `CINIM_CORE_ID` | the shard name | the name under which the core registers at the router; it must differ between cores |
| `CINIM_METRICS` | `true` | `false` makes `/metrics` answer 404 (the Helm value `metrics.enabled`) |
| `CINIM_PROVISION` | `auto` | `auto` makes the Kubernetes objects of an organisation when the core runs in a cluster (the Pod's ServiceAccount), `off` records the organisation only |
| `CINIM_CONTROLLER_IMAGE` | empty | the image of the job controller (the controller and the shim); empty leaves the controller out and the answer of `POST /api/v1/organizations` says so |
| `CINIM_CONTROLLER_STATE_CLASS` | empty | the StorageClass of the controller's 1 Gi state volume; empty is the cluster's default class |
| `CINIM_BUILD` | `off` | `on` turns the build profile on (D-42): the namespace of every organisation is `baseline` under the build-pod policy, and a job may ask for `profile = "build"`; a step that does becomes a build Pod made by the organisation's own controller |
| `CINIM_BUILD_EGRESS` | empty | a JSON array of NetworkPolicy egress rules that build Pods may use beyond DNS and the log collector (the Helm value `build.egress`), or the string `"all"` (any address, private ones too); empty: a build reaches no registry |
| `CINIM_BUILD_INGRESS` | empty | the same for inbound connections to build Pods (the Helm value `build.ingress`): a JSON array of NetworkPolicy ingress rules, several allowed, or the string `"all"`; empty: closed |
| `CINIM_NETWORK_EGRESS` | `restricted` | `open`: the step Pods of an organisation may reach any address (SHD-009; the Helm value `network.egress`); an organisation can ask for its own at creation |
| `CINIM_NETWORK_INGRESS` | `closed` | `open`: any address may reach the step Pods of an organisation (the Helm value `network.ingress`) |
| `CINIM_BUILD_INTERNET` | ports 80, 443, 22 | a JSON object `{"ports": [...], "except": [...]}` (the Helm value `build.internet`): a build may reach public addresses on these ports, the private ranges in `except` stay closed; `off`: no internet |
| `CINIM_BUILD_CAPS` | `CHOWN,DAC_OVERRIDE,FOWNER,SETUID,SETGID,SETFCAP` | the capabilities a build Pod keeps, all others are dropped; only those that Pod Security `baseline` allows |
| `CINIM_BUILD_MEMORY_LIMIT` | `4Gi` | the memory limit of a build Pod |
| `CINIM_BUILD_EPHEMERAL_LIMIT` | `10Gi` | the ephemeral-storage limit of a build Pod (its request is `1Gi`; the Helm value `build.ephemeralStorageLimit`): a build writes layers and a cache. A Pod over its limit is evicted by the kubelet and the step has failed (`ephemeral_storage_exceeded`) |
| `CINIM_STEP_EPHEMERAL_LIMIT` | `1Gi` | the limit that the LimitRange of an organisation's namespace gives a step Pod that sets none (the Helm value `steps.ephemeralStorageLimit`); the request it gives is `64Mi`, so that such a Pod is not the first one the kubelet evicts when the node runs short of ephemeral storage |
| `CINIM_BUILD_SECCOMP` | `RuntimeDefault` | the class of a build Pod: `RuntimeDefault` (Kaniko: root of a user namespace, six capabilities) or `Localhost` (rootless BuildKit and Buildah: user 1000, the seccomp profile `profiles/cinim-userns.json` that exists on every node) (the Helm value `build.seccompProfile`) |
| `CINIM_DEPLOY` | `off` | `on` turns the deploy profile on (D-48; the Helm value `deploy.enabled`): a job may ask for `profile = "deploy"`, and the namespace of every organisation gets the policies of its Pods |
| `CINIM_DEPLOY_EGRESS` | empty | a JSON array of NetworkPolicy egress rules that deploy Pods may use beyond DNS and the collector (the Helm value `deploy.egress`), or the string `all` |
| `CINIM_DEPLOY_KUBE_APISERVER` | `false` | `true`: also a CiliumNetworkPolicy that lets deploy Pods reach the Kubernetes API server (the Helm value `deploy.kubeApiServer`); the core needs the right to make those |
| `CINIM_BUILD*` (controller) | | the core passes `CINIM_BUILD=on`, `CINIM_BUILD_SECCOMP`, `CINIM_BUILD_CAPS`, `CINIM_BUILD_MEMORY_LIMIT` and `CINIM_BUILD_EPHEMERAL_LIMIT` to the controller of every organisation; it makes a build Pod of a step of the build profile |
| `CINIM_RUN_STORAGE`, `CINIM_RUN_STORAGE_SIZE`, `CINIM_RUN_STORAGE_CLASS`, `CINIM_RUN_STORAGE_ACCESS` | `off`, `5Gi`, the default class, `ReadWriteOnce` | the run volume (STO-001; the Helm values `runStorage.enabled`, `size`, `storageClass`, `accessMode`): the core passes them to the controller of every organisation (the table above) |
| `CINIM_STORAGE_RETENTION_SUCCEEDED`, `CINIM_STORAGE_RETENTION_FAILED` | 0, 86400 | seconds after the end of a run before the core tells the controller to delete the run's volume (STO-006): at once for a run that succeeded, a day for one that did not, to look at what it left; a negative value never (the Helm values `runStorage.retention.succeeded`, `.failed`) |
| `CINIM_ORG_RECONCILE_INTERVAL` | 300 | seconds between two passes of the reconciliation (SHD-008; the Helm value `organizations.reconcileInterval`, at least 10); a pass also runs at start |
| `CINIM_ORG_RETENTION` | 1209600 (14 days) | seconds a switched-off organisation is kept before it is deleted for good with its namespace (the Helm value `organizations.retention`); `0` deletes it at once, a negative value never |
| `CINIM_CONTROLLER_BOOTSTRAP_TTL` | 86400 | seconds that the bootstrap token of an organisation's controller stays good (IAM-003) |
| `CINIM_INGRESS_CLASS`, `CINIM_INGRESS_TLS_SECRET`, `CINIM_INGRESS_ANNOTATIONS` | empty | the Ingress of an organisation in the `multi` mode: the class, the TLS Secret (for the host of `CINIM_PUBLIC_URL`) and the annotations as a JSON object |

When the router does not answer, the core keeps the last list and records the error (`GET /api/v1/router`); a slug is then checked against
the last list, and `checked_against_router` in the answer of `POST /api/v1/organizations` is false if no list was ever received. A slug that
two cores hold gives the alert `duplicate_slug` in `GET /api/v1/router`.

## Cluster requirements

The job controller assumes that **the namespace for steps is dedicated to it** (by default the organisation's namespace `<prefix>-<shard>-<org>`, for example `cinim-001-acme`; the objects the core creates there, the controller's own Pod, a RoleBinding, a ResourceQuota, a LimitRange and the NetworkPolicies, are left alone). It decides itself which Pods in
it belong to it: a Pod named `ci-...` that is not in its state is considered orphaned and is deleted. Do not put Pods of that name there. The rights needed are
`pods` (create, get, list, delete), `pods/log` (get), `pods/exec` (create; only to pull out an undelivered spool, if it is withheld that fallback
simply does not run), and `configmaps` (create, get, update) and `secrets` (create, get) for delivering the shim and the CURVE keys; the controller replaces the ConfigMap with its shim at every start, so that a new controller image brings its own shim.
