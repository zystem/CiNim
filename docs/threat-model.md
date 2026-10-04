# Threat model

Scope: the platform as specified in `docs/specification.md` (ZeroMQ + CURVE transport, Protobuf, Lua sandbox, Kubernetes step Pods, VictoriaLogs logs through a spool in the Pod, rqlite state, no message broker). Decision references (D-xx) and measurement references (A.x) point into the specification.
Method: trust zones and data flows, STRIDE per flow, each threat mapped to controls (requirement IDs) and to the evidence that exists today.
Status values: **verified** (automated test exists), **partial**, **designed** (control specified, nothing built or measured yet), **open** (needs a decision).

## 1. Assets

| Asset | Why it matters |
|:---|:---|
| Secrets (Vault values, ephemeral Kubernetes Secrets, tokens) | production access |
| Run journal and run state (rqlite) | integrity of what was executed and approved, audit |
| Source code and artifacts, caches | supply chain |
| Logs (VictoriaLogs) | may contain secrets, tenant isolation |
| Deployment approvals and environment protections | unauthorized deployment |
| Job-controller credentials and Kubernetes rights in the profile namespace | cluster foothold |
| Signing keys (plugins, presigned URLs, log-view tokens) | forgery |

## 2. Trust zones

| Zone | Contents | Trust |
|:---|:---|:---|
| Z0 Internet | browsers, SCM webhooks, API clients | none |
| Z1 Edge and shared services | ingress, OCI plugin registry | authenticated users or none, no tenant data at rest |
| Z2 Shard core | core (scheduler, collector, log-circuit module), executor workers, UI/API service, event service, log gateway, rqlite, vlagent, VictoriaLogs (two nodes) | platform-trusted |
| Z3 Executor sandbox | Lua state per run inside a separate unprivileged process | **untrusted code**, deterministic host API only |
| Z4 Profile namespace | job-controller, step Pods, shim | job-controller privileged in the namespace; step Pods untrusted |
| Z5 Plugin containers | step plugins in step Pods | untrusted, capability-limited |
| Z6 External | Vault/OpenBao, S3, OIDC provider, registries, SCM | separately trusted |

## 3. Data flows and their protection

| Flow | Path | Transport and identity (decided) | Notes |
|:---|:---|:---|:---|
| F1 UI/API | browser to UI/API | HTTPS at ingress, OIDC session, RBAC on every call (IAM-001) | GuildenStern behind ingress (D-25); `/metrics` and `/api/v1/components` are unauthenticated for now, like the rest of the API (IAM not built) |
| F2 Webhooks | SCM to event service | HTTPS, provider signature, delivery-id dedupe, timestamp window | |
| F3 ControllerAttach | job-controller to scheduler | ZeroMQ REQ/REP with CURVE (D-24); the server key is pinned by the client, the shared `client` keypair identifies services until the bootstrap-token exchange (IAM-003) exists; outbound only | proto `controller.proto` |
| F4 LogIngest, StepReport | shim to collector and scheduler | ZeroMQ CURVE with the shared `client` keypair (mounted as a Secret); the projected job token (SEC-010) is the intended identity and is **not checked yet** (T-08); batches carry the attempt number and a per-block checksum, stale attempts cannot touch the current one | `logs.proto`, `step.proto` |
| F5 ExecutorChannel | executor to scheduler | ZeroMQ CURVE; lease token (RUN-008) | `executor.proto` |
| F6 State | scheduler/core to rqlite | rqlite HTTP with authentication, TLS in cluster; strict writes | client must check top-level `error` |
| F7 Logs | collector to vlagent to both VictoriaLogs nodes; gateway to the node picked by ClusterState | TLS with server verification plus login and password (D-24: VictoriaLogs mTLS is enterprise-only); VictoriaLogs closed inside the shard, only vlagent and the gateway reach it (DAT-008) | measured (A.7); no broker, no single master |
| F8 Kubernetes API | job-controller to API server | ServiceAccount token, namespaced Role on a **dedicated namespace** (pods create/get/list/delete, `pods/log`, `pods/exec` for the spool fallback, configmaps/secrets create/get; see docs/settings.md) | official C client (D-26, A.6); `pods/exec` is an added right, see T-37 |
| F9 Log view | browser iframe to gateway | 60 s token bound to user/resource/origin (IAM-004), separate origin, sandboxed iframe | |
| F10 Plugin contract | shim and plugin via files on the run volume | length-prefixed Protobuf files, no network by default | `plugin.proto` |

## 4. Threats (STRIDE), controls and evidence

| ID | Threat | Control (spec IDs) | Evidence | Status |
|:---|:---|:---|:---|:---|
| T-01 | Lua script escapes the sandbox or reads host state | PIP-005/006, SEC-007, corpus of escapes | `tests/unit/tsandbox.nim` (19 tests: no io/os/debug, read-only env, limits, pcall cannot swallow limits) | **partial** (in-process sandbox verified; separate process, seccomp, fuzzing not built) |
| T-02 | Script nondeterminism corrupts replay | PIP-003/004/005, SEC-008 | `tjournal.nim`: hash chain, tamper detection, crash at every journal point, real process kill | **verified** |
| T-03 | Journal or state forged or altered | hash chain, CAS writes (RUN-001), append-only, writes only from executor | tamper test; atomic batch and CAS in `trqlite.nim` | **partial** (rqlite auth and audit chain not built) |
| T-04 | Untrusted PR obtains production secrets | trust levels, protected environments, fork jobs without secrets (6.6, SEC-002) | not built | **designed** |
| T-05 | Env-file injection (`LD_PRELOAD`, `PATH`, control sequences) | STO-003/004, SEC-011 | `tdotenv.nim` (12 tests), `tshim.nim`, the shim's `env_rejected` (exit 70) is also covered by the end-to-end suite | **verified** |
| T-06 | Secret leaks through step outputs | STO-004 `secret_in_output` | `tdotenv.nim`, `tshim.nim` | **verified** |
| T-07 | Secret leaks in logs | DAT-002 redaction **in the shim before anything leaves the Pod** (raw, base64 at every alignment, URL, JSON forms; values registered at run time through `$CICD_MASK`); the Pod's own log carries only the shim's events; ephemeral Secrets | `tsecretmask.nim`, `tshim.nim` (masking through the real spool), `tm1skeleton.nim` (a runtime value never reaches the store); Secret ownerReference garbage collection was measured (A.6) | **verified** for known and registered values; **partial** overall (a value split across lines, other encodings, a value nobody registered: docs/secrets-masking.md) |
| T-08 | Stolen or forged job token (Pod step compromised) | projected token, audience `cicd-shard`, 10 min TTL, bound to Pod (SEC-010), fencing by Pod name | claims measured (A.6); RS256 signature verified independently (PyJWT), tampered and wrong-audience tokens rejected | **partial** (Nim-side verification not built) |
| T-09 | Fake peer on an internal channel | CURVE: the client pins the server's public key, the server accepts only known client keys (D-24); the clients load only the server's public key | `zmqcurve.nim`; the integration suite runs every channel over CURVE | **partial** (a wrong server key is refused by construction; per-service client keys are not issued yet) |
| T-10 | Oversized or malformed message exhausts memory (DoS) | E-003 limits, Protobuf decoder robustness, a batch is at most 64 chunks and ~1 MiB, a spool frame at most 64 MiB, sample counts and response sizes bounded | `tpb.nim` truncated and garbage input, `tspoolwire.nim`, `tappmetrics.nim` | **verified** for the decoders; **partial** for transport-level message size (`ZMQ_MAXMSGSIZE` not set) |
| T-11 | Job-controller compromised | minimal Role, no cluster-wide rights, outbound only, audit (SEC-010) | Role not built | **designed** |
| T-12 | Two Pods run one step (duplicate execution) | deterministic Pod name, `AlreadyExists`, lease fencing (RUN-002/008) | measured (A.6): 409 on a second create, Lease 409 on a stale version | **verified** by measurement; no automated test yet |
| T-13 | Tenant neighbour on the node | namespace and quota per tenant, RuntimeClass sandbox for untrusted (SEC-012) | namespace, quota, limit range and default-deny policy per organisation are made by the core (SHD-007); a run's steps go only to the controller of its organisation's namespace (`tests/integration/torgruns.nim`, checked on the TESTING cluster); the RuntimeClass sandbox for untrusted pipelines is not built | **partial** |
| T-14 | Cache or artifact poisoning | trust-boundary namespaces, digests (DAT-004/005) | not built | **designed** |
| T-15 | Malicious plugin | signature, capabilities, network deny, no in-process code (PLG-001..) | file contract and `bytes`/Struct wire test in `tproto_v0.nim` | **designed** |
| T-16 | Webhook spoofing and replay | signature, timestamp window, dedupe | not built | **designed** |
| T-17 | Unauthorized deployment | environment RBAC, separation of duties, approval snapshot (PIP-013, DEP) | state machine of inputs (`tstates.nim`) | **partial** |
| T-18 | Log view bypass | 60 s tokens, separate origin, sandboxed iframe | not built | **designed** |
| T-19 | Memory-safety bugs at the Nim and C boundary | sanitizer builds, RAII, minimal casts (E-003/E-004, SEC-009) | ASan/LSan runs on the unit suites and in the 72 h soak; a real leak at this boundary was found with heaptrack (nim-zmq `=destroy`, A.12) | **partial** (CI sanitizer pipeline and fuzzing not built) |
| T-20 | Audit tampering | append-only hash chain, WORM export (SEC-005) | hash chain implemented for the journal only | **partial** |

## 5. Further threats (beyond specification section 11)

| ID | Threat | Finding | Control decided | Status |
|:---|:---|:---|:---|:---|
| T-21 | **HTML injection (XSS) through the template engine.** Pipeline names, branch names and log text are attacker-controlled. `nimja` does not escape by default. | verified: `{{ name }}` emitted `<script>` unescaped | every expression must be `{{ h(x) }}` or `{{ raw(x) }}`; `tests/unit/ttemplates.nim` scans templates and fails the build | **verified** |
| T-22 | **False write acknowledgement from rqlite.** During a leadership change rqlite answers HTTP 200 with `{"error": ...}` | first client treated a failed write as committed | clients must check the top-level and per-result `error` (A.2); regression test | **verified** |
| T-23 | **Protobuf bytes are not canonical**: implementations order fields differently (Nim by declaration, protoc by number). Hashing or signing serialized Protobuf breaks across languages | verified in `tproto_v0.nim` | journal hashes cover canonical JSON fields, never Protobuf bytes; no signature over Protobuf | **verified** (rule) |
| T-24 | **Exception across a C callback** kills the process (`httpbeast`: an unhandled handler exception terminated the server) | measured | the HTTP handler is `raises: []` and funnels every exception through one try/except (D-25) | **verified** |
| T-25 | **Hang of the Kubernetes C client** (no request timeout; one 8.5-minute hang observed) | A.6 | `CURLOPT_TIMEOUT` and `CURLOPT_CONNECTTIMEOUT` via `curl_pre_invoke_func` | **open** (not applied) |
| T-26 | **Shared Nim heap objects across threads** corrupt memory (ORC has per-thread heaps and non-atomic reference counts) | SIGSEGV in a watch thread | only plain data crosses threads (rule, A.6) | **verified** (rule) |
| T-27 | **Leak per connection or request** exhausts a long-running service | `hyperx` leaked; the ZeroMQ path leaked 30 bytes per connection until the nim-zmq `=destroy` fix (A.12, nim-lang/nim-zmq#59) | transport and HTTP layer chosen by measured behaviour; per-connection soak in NFR-013 (the 72 h acceptance run is the final measurement) | **partial** (fix verified over 10 min and 313k connections; the 72 h result closes it) |
| T-28 | **Unbounded input to the shim**: `CICD_OUTPUT` and `CICD_ENV` sizes | STO-003 limits | 8 KiB per value, 256 keys, 64 KiB total; termination message capped at 4 KiB | **verified** |
| T-29 | **Time-of-check on the job token**: a token is checked at connect but a stolen token lives 10 minutes | SEC-010 TTL | check the token on every batch and bind to the Pod name; consider a per-attempt nonce | **open** |
| T-30 | **Cross-tenant log read through the gateway** if it builds a VictoriaLogs query without the tenant's `AccountID`/`ProjectID` header. VictoriaLogs itself does not authenticate end users: whoever reaches it can read any tenant's data (D-07, A.7) | measured (VictoriaLogs has no claim check; multi-tenancy is entirely the caller's headers) | VictoriaLogs closed inside the shard (DAT-008), gateway is the only reader and is the only thing that sets `AccountID`/`ProjectID`, built from the verified user token; gateway tests | **open** (no gateway code yet) |
| T-31 | **Silent data loss from the vlagent queue**: a node down longer than its buffer allows (`-remoteWrite.maxDiskUsagePerURL`) drops the oldest queued lines for that node without failing the write to the client | not measured (buffer overflow itself, only normal catch-up 7–19 s for 2 M lines, A.7) | alert on queue growth approaching the limit, launch gate closes on `gate_max_pending` before the buffer would overflow (RUN-015, DAT-010) | **open** |
| T-32 | **Memory of a VictoriaLogs node scales with open index size**: idle RSS ≈2 GiB at 100 M lines/3 shards in the A.7 measurement, no cap without `-memory.allowedBytes`/`allowedPercent` | measured (A.7) | set `-memory.allowedBytes` and a Pod memory limit; size indexes by tenant and period, retention drops old partitions (DAT-006/008) | **partial** (flag exists and was exercised informally; not wired into the Helm values yet) |
| T-33 | **Unbounded query cost**: no request time or memory limit is enforced by the platform; VictoriaLogs itself has no guard against a wide `search` returning millions of rows | not measured (A.7 did not attempt an adversarial query) | gateway-side `limit` and timeout on every query, search scoped to one job's stream (DAT-008) | **open** |
| T-34 | **Duplicate log lines**: VictoriaLogs does not deduplicate; a retried collector→vlagent write (ambiguous response, at-least-once semantics) can land twice under the same `(job, ln)` | measured: VictoriaLogs has no dedup (A.7) | collector retries with the same `ln`; the window/search path must exclude duplicates by `(job, ln)` before returning rows | **open** (no collector or gateway code yet) |

| T-35 | **Another attempt's data mixed into a retry** (a "ghost" shim that outlived its Pod writes to the new attempt's log or result) | D-27, D-29 | the attempt number is part of the stream key and the VictoriaLogs `job` label; results of a stale attempt are ignored (fencing); late logs of the old attempt land in the old attempt's stream | `tm1skeleton.nim` (attempts, losses), `tshimrecord.nim` | **verified** |
| T-36 | **A step that started is run a second time** (a half-done deploy repeated by a machine) | D-28 | only a step known never to have started is retried; started with an unknown outcome ends as `outcome_unknown` with the reason in the API | `tpodverdict.nim`, e2e (Pod vanishes after the command started / before it started) | **verified** |
| T-37 | **`pods/exec` right of the job-controller** (new): used to read an undelivered spool out of a running step Pod before it is removed; a compromised controller could run commands in step Pods | D-29 (fallback), docs/settings.md | the command is fixed (`cicd-shim --read-spool` / `--ack-spool`, no user input), only Pods of the dedicated namespace; the right can be withheld, the fallback then simply does not run | `tdrain.nim`, e2e (cut-off shim) | **partial** (the Role itself is not generated by the platform yet, T-11) |
| T-38 | **A step makes the shim scrape arbitrary targets** (SSRF through `metrics.scrape`) | docs/metrics.md | the Lua sandbox allows only `http://127.0.0.1`, `localhost` and `[::1]` (the Pod itself), at most 4 sources, bounded intervals, 200 series and 1 MiB per scrape | `tpipeline.nim` (URL cases) | **verified** |
| T-39 | **Log flooding / disk exhaustion by a step** | D-27 | per-step `log_max_bytes` (default 1 GiB, one marker line), the spool is bounded with backpressure and an `emptyDir` `sizeLimit`, `$CICD_MASK` is capped at 64 KiB and 256 masks | `tlogspool.nim`, e2e (`log_max_bytes`, backpressure) | **verified** |
| T-40 | **A hung or silent step/Pod holds capacity for ever** | D-29 | `timeout` enforced by the shim (TERM, then KILL, whole process group), `liveness_timeout` kills a Pod that did not start or a shim that went silent | `tshim.nim`, e2e (timeout, start_timeout, silent shim) | **verified** |
| T-41 | **A step tampers with the env file** to inject variables into the following steps (any step can write `$CICD_ENV`, and a plugin or a fork's step shares the volume) | STO-003, STO-004, VAR-004 | the shim validates the file whenever it reads it (name rule, deny-list, limits, known secrets); the file lives in `/cicd/state`, outside the workspace, so that checkout, artifacts and caches do not carry it; untrusted refs get a clean volume (STO-008) | `tdotenv.nim` (validation); the move to `/cicd/state` is specified, not built | **designed** |
| T-42 | **Tampering with or deleting the audit** (with the audit in VictoriaLogs, anyone who reaches the nodes' API could delete or alter records) | AUD-003, AUD-004, SEC-005 | the audit nodes run without the delete API and with separate write-only and read-only credentials; the chain is verified against anchors kept in rqlite and, when configured, in object-lock storage; a gap in `seq` raises `audit_chain_broken` | not built | **designed** |
| T-43 | **Enumeration of organisations through the router's page** (anyone who reaches the router sees which organisations exist and whether they are up) | SHD-006 | the page holds only slugs, URLs and availability, which are visible in URLs anyway; signing in happens under `/<org>/`; `router.listOrganizations=false` turns the page off and `/list` requires the key | not built | **designed** |
| T-44 | **A forged registration or a stolen router key**: whoever has the key can add or replace entries (links to a look-alike site) or read the list | SHD-006 | the key is kept as a Secret, compared in constant time and sent over TLS; entries expire, so a forged entry lives only while it is renewed; the list is informational and signing in always happens at the organisation's own address | not built | **designed** |
| T-45 | **The core's cluster-wide right over namespaces** (create and delete namespaces, bind a role, create controllers and Secrets in them): a compromised core could create namespaces or grant the step role elsewhere | SHD-007, SEC-010 | the right covers only the listed kinds of objects, `bind` is restricted to one ClusterRole by `resourceNames`, and a ValidatingAdmissionPolicy limits the requests to namespaces named `<prefix>-<shard>-*` | the rights and the policy are in `deploy/charts/cinim-shard`; checked by hand on the TESTING cluster by acting as the core's ServiceAccount (a namespace outside the prefix, `kube-system`, binding `cluster-admin` and reading Secrets are refused); the objects are covered by `tests/unit/torgprovision.nim`; no automated test of the policy yet | **partial** |
| T-46 | **A controller names another organisation's namespace** in its poll and receives that organisation's steps | SHD-007, IAM-003 | a namespace made by the core has a controller identity: a credential (HMAC of the namespace and a generation under the core's secret key, handed out once for a bootstrap token) that every poll carries; a poll without it is refused and changes nothing; a rotation locks the old credential out | `tests/unit/tctrlauth.nim`, `tests/integration/torgruns.nim`; checked on the TESTING cluster: the controller enrols, keeps the credential across a restart, is refused after a rotation and enrols again. A namespace without an identity (a single-tenant setup) is still trusted, and the transport still takes any holder of the shared `client` key (T-08) | **verified** |

## 6. Open points

1. **Shim identity (D-24).** Services and the job-controller authenticate with CURVE keypairs; the shim uses the shared `client` keypair plus the projected job token (SEC-010), which is meant to be checked on every message but **is not checked yet**, because a key per Pod would need a per-Pod key workflow and RUN-013 has no room for it. `NodeControl`, `LogPublish` and `LogRead` (VictoriaLogs) use TLS with login and password for the same reason (VictoriaLogs mTLS is enterprise-only). Remaining gap: the Nim-side check of the token's RS256 signature against the cluster's JWKS is not built (T-08); only an independent PyJWT check exists (A.6).
2. **Step state names.** RUN-001 (`pending`, `starting`) and the queue example in 7.2 (`queued`, `dispatched`). Mapping in A.3: pending = queued, starting = dispatched.
3. **PLG-008 uses `google.protobuf.Struct`**, which the Nim codec cannot compile (recursive type). A.3 keeps the normative `.proto` and carries Struct as `bytes` on the Nim side (wire-identical); a JSON string field is the alternative.
4. **Lua API**: the test fixture `ci.sh` is not API v1 (`Job:sh` is); it is removed when `ci.job` lands.
5. **TLS for the external UI** is terminated at the ingress; the spec table says "HTTPS" without saying where.

## 7. Residual risk

Highest remaining: T-01 (separate process, seccomp, fuzzing), T-04 and T-13 (tenant and job isolation are only designed), T-08/T-29 (token verification in Nim, per-message checks),
T-25 (client timeouts), and the log circuit's own code (T-18 gateway auth, T-30/T-33/T-34 gateway query and dedup logic): the measurements (A.7)
show that VictoriaLogs itself works within budget, but the collector and gateway that must enforce tenant isolation, dedup and query limits on top of it are not built yet.
