# Threat model (M0, spike 7; updated after spike 5b and D-24)

Scope: the platform as specified in v1.10 and as decided in ADR 0001-0018 (transport NNG, Protobuf, Lua sandbox, Kubernetes step Pods, VictoriaLogs logs,
rqlite state, no NATS in the base install). Updated from the original spike-7 version (ZincSearch/NATS/coordinator, Q-18 still open) to match D-07/D-21/D-24
and the spec's own "Изменения v1.8–v1.10". Flows and threats below carry a note where the finding changed with the architecture; nothing measured under the
old ZincSearch/NATS design is claimed to still hold for VictoriaLogs unless re-stated.
Method: trust zones and data flows, STRIDE per flow, each threat mapped to controls (requirement IDs) and to the evidence we have today.
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
| Z1 Global services | UI/API, directory, plugin registry | authenticated users, no tenant data at rest |
| Z2 Shard core | core (scheduler, collector, log-circuit module), executor workers, event service, log gateway, rqlite, vlagent, VictoriaLogs (two nodes) | platform-trusted |
| Z3 Executor sandbox | Lua state per run inside a separate unprivileged process | **untrusted code**, deterministic host API only |
| Z4 Profile namespace | job-controller, step Pods, shim | job-controller privileged in the namespace; step Pods untrusted |
| Z5 Plugin containers | step plugins in step Pods | untrusted, capability-limited |
| Z6 External | Vault/OpenBao, S3, OIDC provider, registries, SCM | separately trusted |

## 3. Data flows and their protection

| Flow | Path | Transport and identity (decided) | Notes |
|:---|:---|:---|:---|
| F1 UI/API | browser to UI/API | HTTPS at ingress, OIDC session, RBAC on every call (IAM-001) | civetweb behind ingress (ADR 0012) |
| F2 Webhooks | SCM to event service | HTTPS, provider signature, delivery-id dedupe, timestamp window | |
| F3 ControllerAttach | job-controller to scheduler | NNG `tls+tcp`, mTLS identity from bootstrap-token exchange (IAM-003), outbound only | proto `controller.proto` |
| F4 LogIngest, StepReport | shim to collector and scheduler | NNG TLS; **client identity is the projected job token (SEC-010), not a client certificate** (decided, D-24: services and the job-controller use mTLS, the shim uses TLS plus the job token, a per-Pod certificate is impractical) | `logs.proto`, `step.proto` |
| F5 ExecutorChannel | executor to scheduler | NNG mTLS; lease token (RUN-008) | `executor.proto` |
| F6 State | scheduler/core to rqlite | rqlite HTTP with authentication, TLS in cluster; strict writes | client must check top-level `error` |
| F7 Logs | collector to vlagent to both VictoriaLogs nodes; gateway to the node picked by ClusterState | TLS with server verification plus login and password (D-24: VictoriaLogs mTLS is enterprise-only); VictoriaLogs closed inside the shard, only vlagent and the gateway reach it (DAT-008) | measured, ADR 0016/0017; no NATS, no single master |
| F8 Kubernetes API | job-controller to API server | ServiceAccount token, namespaced Role without `pods/exec` (SEC-010) | official C client or thin client (ADR 0011/0013) |
| F9 Log view | browser iframe to gateway | 60 s token bound to user/resource/origin (IAM-004), separate origin, sandboxed iframe | |
| F10 Plugin contract | shim and plugin via files on the run volume | length-prefixed Protobuf files, no network by default | `plugin.proto` |

## 4. Threats (STRIDE), controls and evidence

| ID | Threat | Control (spec IDs) | Evidence | Status |
|:---|:---|:---|:---|:---|
| T-01 | Lua script escapes the sandbox or reads host state | PIP-005/006, SEC-007, corpus of escapes | `tests/unit/tsandbox.nim` (19 tests: no io/os/debug, read-only env, limits, pcall cannot swallow limits) | **partial** (in-process sandbox verified; separate process, seccomp, fuzzing not built) |
| T-02 | Script nondeterminism corrupts replay | PIP-003/004/005, SEC-008 | `tjournal.nim`: hash chain, tamper detection, crash at every journal point, real process kill | **verified** |
| T-03 | Journal or state forged or altered | hash chain, CAS writes (RUN-001), append-only, writes only from executor | tamper test; atomic batch and CAS in `trqlite.nim` | **partial** (rqlite auth and audit chain not built) |
| T-04 | Untrusted PR obtains production secrets | trust levels, protected environments, fork jobs without secrets (6.6, SEC-002) | not built | **designed** |
| T-05 | Env-file injection (`LD_PRELOAD`, `PATH`, control sequences) | STO-003/004, SEC-011 | `tdotenv.nim` (12 tests), `tshim.nim`, in-cluster `tk8s3.nim` (`env_rejected`, exit 70) | **verified** |
| T-06 | Secret leaks through step outputs | STO-004 `secret_in_output` | `tdotenv.nim`, `tshim.nim` | **verified** (shim side; collector redaction not built) |
| T-07 | Secret leaks in logs | DAT-002 redaction in collector, shim best-effort, ephemeral Secrets | Secret ownerReference GC verified in `tk8s2.nim` | **partial** |
| T-08 | Stolen or forged job token (Pod step compromised) | projected token, audience `cicd-shard`, 10 min TTL, bound to Pod (SEC-010), fencing by Pod name | `tk8s2.nim` claims; RS256 signature verified independently (PyJWT), tampered and wrong-audience tokens rejected | **partial** (Nim-side verification not built) |
| T-09 | Fake peer on an internal channel | mTLS with CA (ADR 0010) | `tnng.nim`: no cert, foreign CA and untrusted server rejected; client identity read from certificate CN | **verified** for the transport |
| T-10 | Oversized or malformed message exhausts memory (DoS) | E-003 limits, `NNG_OPT_RECVMAXSZ`, Protobuf decoder robustness | `tnng.nim` size limit, `tpb.nim` truncated and garbage input | **verified** |
| T-11 | Job-controller compromised | minimal Role, no cluster-wide rights, outbound only, audit (SEC-010) | Role not built | **designed** |
| T-12 | Two Pods run one step (duplicate execution) | deterministic Pod name, `AlreadyExists`, lease fencing (RUN-002/008) | `tk8s.nim` (409), `tk8s2.nim` (Lease 409 on stale version) | **verified** at the Kubernetes level |
| T-13 | Tenant neighbour on the node | namespace and quota per tenant, RuntimeClass sandbox for untrusted (SEC-012) | not built | **designed** |
| T-14 | Cache or artifact poisoning | trust-boundary namespaces, digests (DAT-004/005) | not built | **designed** |
| T-15 | Malicious plugin | signature, capabilities, network deny, no in-process code (PLG-001..) | file contract and `bytes`/Struct wire test in `tproto_v0.nim` | **designed** |
| T-16 | Webhook spoofing and replay | signature, timestamp window, dedupe | not built | **designed** |
| T-17 | Unauthorized deployment | environment RBAC, separation of duties, approval snapshot (PIP-013, DEP) | state machine of inputs (`tstates.nim`) | **partial** |
| T-18 | Log view bypass | 60 s tokens, separate origin, sandboxed iframe, ZF-1 claims | not built | **designed** |
| T-19 | Memory-safety bugs at the Nim and C boundary | sanitizer builds, RAII, minimal casts (E-003/E-004, SEC-009) | ASan/LSan clean on all suites including NNG, ZeroMQ, Lua | **partial** (CI sanitizer pipeline and fuzzing not built) |
| T-20 | Audit tampering | append-only hash chain, WORM export (SEC-005) | hash chain implemented for the journal only | **partial** |

## 5. Threats found during M0 (not in spec section 11)

| ID | Threat | Finding | Control decided | Status |
|:---|:---|:---|:---|:---|
| T-21 | **HTML injection (XSS) through the template engine.** Pipeline names, branch names and log text are attacker-controlled. `nimja` does not escape by default. | verified: `{{ name }}` emitted `<script>` unescaped | every expression must be `{{ h(x) }}` or `{{ raw(x) }}`; `tests/unit/ttemplates.nim` scans templates and fails the build | **verified** |
| T-22 | **False write acknowledgement from rqlite.** During a leadership change rqlite answers HTTP 200 with `{"error": ...}` | first client treated a failed write as committed | clients must check the top-level and per-result `error` (ADR 0004); regression test | **verified** |
| T-23 | **Protobuf bytes are not canonical**: implementations order fields differently (Nim by declaration, protoc by number). Hashing or signing serialized Protobuf breaks across languages | verified in `tproto_v0.nim` | journal hashes cover canonical JSON fields, never Protobuf bytes; no signature over Protobuf | **verified** (rule) |
| T-24 | **Exception across a C callback** kills the process (`httpbeast`: an unhandled handler exception terminated the server) | measured | civetweb handlers catch every exception; a handler never lets an exception cross the C frame | **verified** in the measurement server |
| T-25 | **Hang of the Kubernetes C client** (no request timeout; one 8.5-minute hang observed) | ADR 0011 | `CURLOPT_TIMEOUT` and `CURLOPT_CONNECTTIMEOUT` via `curl_pre_invoke_func` | **open** (not applied) |
| T-26 | **Shared Nim heap objects across threads** corrupt memory (ORC has per-thread heaps and non-atomic reference counts) | SIGSEGV in a watch thread | only plain data crosses threads (rule, ADR 0011) | **verified** (rule) |
| T-27 | **Leak per connection or request** exhausts a long-running service | `hyperx` leaked, other transports and civetweb did not | transport and HTTP layer chosen by measured leak-free behaviour; per-connection soak in NFR-013 | **partial** |
| T-28 | **Unbounded input to the shim**: `CICD_OUTPUT` and `CICD_ENV` sizes | STO-003 limits | 8 KiB per value, 256 keys, 64 KiB total; termination message capped at 4 KiB | **verified** |
| T-29 | **Time-of-check on the job token**: a token is checked at connect but a stolen token lives 10 minutes | SEC-010 TTL | check the token on every batch and bind to the Pod name; consider a per-attempt nonce | **open** |
| T-30 | **Cross-tenant log read through the gateway** if it builds a VictoriaLogs query without the tenant's `AccountID`/`ProjectID` header. VictoriaLogs itself does not authenticate end users: whoever reaches it can read any tenant's data (D-07, ADR 0016/0017) | measured (VictoriaLogs has no ZF-1-equivalent claim check; multi-tenancy is entirely the caller's headers) | VictoriaLogs closed inside the shard (ZF-5/DAT-008), gateway is the only reader and is the only thing that sets `AccountID`/`ProjectID`, built from the verified user token; gateway tests | **open** (no gateway code yet) |
| T-31 | **Silent data loss from the vlagent queue**: a node down longer than its buffer allows (`-remoteWrite.maxDiskUsagePerURL`) drops the oldest queued lines for that node without failing the write to the client | not measured (buffer overflow itself, only normal catch-up 7–19 s for 2 M lines, ADR 0017) | alert on queue growth approaching the limit, launch gate closes on `gate_max_pending` before the buffer would overflow (RUN-015, DAT-010) | **open** |
| T-32 | **Memory of a VictoriaLogs node scales with open index size**: idle RSS ≈2 GiB at 100 M lines/3 shards in the ADR 0017 measurement, no cap without `-memory.allowedBytes`/`allowedPercent` | measured (ADR 0017) | set `-memory.allowedBytes` and a Pod memory limit; size indexes by tenant and period, retention drops old partitions (DAT-006/008) | **partial** (flag exists and was exercised informally; not wired into the Helm values yet) |
| T-33 | **Unbounded query cost**: no request time or memory limit is enforced by the platform; VictoriaLogs itself has no fork-level guard against a wide `search` returning millions of rows | not measured (ADR 0017 did not attempt an adversarial query) | gateway-side `limit` and timeout on every query, search scoped to one job's stream (DAT-008 ZF-4) | **open** |
| T-34 | **Duplicate log lines**: VictoriaLogs does not deduplicate; a retried collector→vlagent write (ambiguous response, at-least-once semantics) can land twice under the same `(job, ln)` | measured: VictoriaLogs has no dedup (ADR 0017) | collector retries with the same `ln`; the window/search path must exclude duplicates by `(job, ln)` before returning rows | **open** (no collector or gateway code yet) |

## 6. Open decisions and spec inconsistencies (for the owner)

1. **Shim identity (Q-18, decided, D-24).** Services and the job-controller use mTLS (a certificate issued once at install); the shim uses server-authenticated TLS plus the projected job token (SEC-010), checked on every message, because issuing a client certificate per Pod would need a per-Pod CA workflow and RUN-013 has no room for it. `NodeControl`, `LogPublish` and `LogRead` (VictoriaLogs) use TLS with login and password for the same reason (VictoriaLogs mTLS is enterprise-only). Remaining gap: the Nim-side check of the token's RS256 signature against the cluster's JWKS is not built (T-08); only an independent PyJWT check exists (ADR 0011).
2. **Step state names.** RUN-001 (`pending`, `starting`) and the queue example in 7.2 (`queued`, `dispatched`). Mapping in ADR 0012: pending = queued, starting = dispatched.
3. **PLG-008 uses `google.protobuf.Struct`**, which the Nim codec cannot compile (recursive type). ADR 0012 keeps the normative `.proto` and carries Struct as `bytes` on the Nim side (wire-identical); the owner may prefer a JSON string field instead.
4. **Lua API**: the spike-3 fixture `ci.sh` is not API v1 (`Job:sh` is); removed when `ci.job` lands.
5. **TLS for the external UI** is terminated at the ingress; the spec table says "HTTPS" without saying where.

## 7. Residual risk after M0

Highest remaining: T-01 (separate process, seccomp, fuzzing), T-04 and T-13 (tenant and job isolation are only designed), T-08/T-29 (token verification in Nim, per-message checks),
T-25 (client timeouts), and the log circuit's own code (T-07 collector redaction, T-18 gateway auth, T-30/T-33/T-34 gateway query and dedup logic): spike 5b (ADR 0016/0017) measured
that VictoriaLogs itself works within budget, but the collector and gateway that must enforce tenant isolation, dedup and query limits on top of it are not built yet.
