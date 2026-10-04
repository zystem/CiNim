---
title: CI/CD Platform Specification
subtitle: Analysis of 20 systems, 20 extensions and the requirements for building a platform of this kind
---

*Version 1.0 • Status: specification*

# Purpose

This document defines the product, functional and architectural requirements for a new self-hosted CI/CD platform that runs only on Kubernetes. The goal is to combine the manageability of TeamCity, the ecosystem and flexibility of Jenkins (an imperative pipeline script and an extensible UI), the portability of the pipeline-as-code of modern SaaS systems, and Kubernetes-native execution, without depending on a particular Git host. The main implementation priority is low memory consumption on the server, in the job Pod and in the browser, and the absence of leaks in every component.

The document is written as a working specification: every requirement has a stable ID and a verifiable criterion, and the order of work is given as vertical slices with exit criteria (section 17). The same text serves product owners, architects, SRE and security engineers as the basis for design review.

The platform is a set of independent microservices written in Nim and grouped into shards (cells), which scale by adding shards. Execution uses no permanent agents: every pipeline step runs in its own Pod, which a job controller creates and watches, and data moves between steps through shared storage and an env file. Pipelines are imperative Lua 5.4 scripts with a replay journal, state is kept in rqlite, the protocol between services is Protobuf, and extensions are isolated. The first version solves CI and managed CD; it does not try to also build a Git host, an artifact repository and a full secret manager.

# Solution summary

| **Topic** | **Choice** |
|:---|:---|
| Deployment | Kubernetes only, installed with Helm. Docker Compose, VMs, bare metal and shell agents are out of scope |
| Implementation language | Nim 2.x (ORC); the shim and the CLI are static binaries, the other services may link libraries into their images, which are no larger than Alpine; low memory and no leaks are the priority |
| Architecture | Microservices from the first release; a shard (cell) is a set of services with its own rqlite and log circuit (two independent VictoriaLogs nodes fed by a vlagent); capacity grows by adding shards; an organization is pinned to a shard by the path prefix of its URL at the ingress, there is no global directory |
| Execution | No permanent agents (the disposable shim in each step's Pod does an agent's work for that step); the job controller creates a Pod for every step, a Pod can be started many times over a persistent run volume, every step of a run mounts the shared storage, data moves through the env file and files |
| Pipeline | Imperative Lua 5.4 script in a sandbox; runtime execution with a replay journal; no YAML |
| Protocols | Protobuf (proto3) between services and for plugins over ZeroMQ with CURVE; the external API is REST/JSON; HTTP is served by GuildenStern |
| Extensions | Step plugins are OCI images with a file-based Protobuf contract, service plugins are separate services; capability permissions; signing; no code is loaded into server processes; UI contributions go through extension points and isolated iframes |
| UI | Server-side rendering, no SPA, a permanent link to every element, minimal client code and browser memory; logs are shown as a window |
| Logs | VictoriaLogs (upstream, two independent nodes fed by vlagent) is the log store and source of truth; the step's shim masks secrets and spools compressed blocks on the Pod, core proxies them to vlagent; the browser only ever holds a window of the log, the full log is streamed on download |
| Security | OIDC/SAML, RBAC with scopes, Vault/KMS, short-lived credentials, OIDC federation, Lua sandbox, restricted Pod Security, policy engine |
| Compatibility | Importers for Jenkinsfile, TeamCity Kotlin DSL, GitHub Actions, GitLab CI and Travis/CircleCI that generate Lua scripts and report what could not be translated |

# How to use this document

## Conventions

- Every requirement has an ID such as `PIP-001`, `DAT-002`, `NFR-006`. A requirement is mandatory unless it is marked `[recommendation]`. The name of every test contains the ID of the requirement it verifies.

- A statement about a third-party product marked `[verify]` in section 2 is not confirmed by the product's official documentation overview at the date of writing.

- Decisions are recorded in the decision log below (D-xx) and in Appendix A, which holds the rationale and the measurements behind them.

## Engineering rules

- **E-001 Vertical slices.** Work proceeds in slices, each of which covers the whole path (API, state, Pod, UI, test). Horizontal layers without a working scenario are not accepted.

- **E-002 Tests first.** For every requirement the test is written first, then the implementation. A slice is closed when the exit criteria of its stage are met.

- **E-003 Memory is a requirement.** Every queue, buffer, cache and table is bounded. Every C resource (Lua state, TLS context, descriptor) is wrapped in a type with `=destroy`. Cycles between `ref` objects are forbidden without an explicit justification in the code. The same rules apply to client-side UI code (UI-008).

- **E-004 Memory observability.** Every process exposes RSS and `getOccupiedMem` metrics, and the CI build includes an AddressSanitizer/LeakSanitizer variant for the server services, the executor and the runner shim.

- **E-005 No foreign code in the control plane.** User scripts and plugins run only in separate processes or Pods with restrictions (PLG-001, SEC-007).

- **E-006 Decisions are written down.** Every architectural decision and every measured result is recorded in this document: the decision log (D-xx) states the decision and its rationale, Appendix A holds the evidence.

- **E-007 No invented behaviour.** The behaviour of third-party systems or libraries is never assumed. A fact that is not confirmed by documentation or by an experiment is written down as an assumption marked `[verify]` and is not relied on in public APIs until it is checked.

## Repository layout

```text
proto/            # .proto: internal, plugin; N/N-1 compatibility checks
src/core/         # shard core: scheduler, log collector, launch gate, REST API
src/executor/     # pipeline executor library: Lua sandbox, journal, replay
src/executorsvc/  # executor service
src/jobcontroller/# job controller: Pods, storage, secrets, cleanup, watch
src/shim/         # runner shim: step wrapper in the Pod, env file, logs, metrics, result
src/common/       # shared types, Protobuf code, Kubernetes client, transport, metrics, limits
src/ui/           # server-side rendering
lua/stdlib/       # Lua API v1 (6.7), type stubs for IDEs
deploy/           # Helm values and service units for test environments
tools/            # build, code generation and benchmark helpers
docs/             # this specification and the documents it references
tests/            # unit, contract, integration, e2e, soak, security
```

# Decision log

Each decision has a rationale and a condition under which it is revisited. Measurements behind the decisions are in Appendix A.

| **ID** | **Decision** | **Rationale** | **Revisit when** |
|:---|:---|:---|:---|
| D-01 | Nim 2.x, ORC, for all services, the shim and the CLI | Low memory use and no leaks | The soak test does not meet NFR-013, or there is no working secured transport |
| D-02 | State lives in rqlite (Raft, SQLite); capacity grows by sharding | Compared with Percona XtraDB Cluster on the same workload rqlite is 4--10x faster at claiming a step and an order of magnitude lighter in memory; compared with a PostgreSQL cluster it recovers from a leader loss in a fraction of a second instead of about half a minute, uses a quarter of the memory and is one binary with built-in S3 backup, while PostgreSQL claims steps about 2.5x faster under contention (A.2) | The benchmark does not reach the single-shard targets (NFR-006): shrink the shard, reduce writes; then PostgreSQL is the alternative |
| D-03 | No message broker. Platform events (webhooks, statuses, notifications about available work) go only through an outbox in rqlite that a worker drains | A broker is not needed for logs (D-07) and is not worth a component of its own for notifications; when load grows the shard is made smaller (SHD-003), no component is added | The outbox systematically fails NFR-003 even after the shard is made smaller |
| D-04 | Protobuf (proto3) between services and for plugins | Compact, versioned contracts with N/N-1 compatibility checks | None |
| D-05 | Imperative pipeline script in Lua 5.4 with runtime execution and a replay journal; no YAML | Full flexibility of an imperative script with deterministic replay | None |
| D-06 | UI without an SPA; permanent links; extension points; server-side rendering as the main approach | Saves memory in the browser as well | None |
| D-07 | VictoriaLogs (upstream, Apache-2.0) is the log store and source of truth. Resilience comes from a pair of independent single nodes on persistent volumes fed by vlagent (a disk buffer per node); the store does not replicate data itself; no chunks in S3 | On 100 M lines: ingest about 1 M lines/s, disk 0.39x of the text, window p95 about 10 ms, memory about 2 GiB (A.7) | Write durability of vlagent, duplicates on redelivery or memory under soak turn out unacceptable. `LogStore` is an interface, the product can be replaced |
| D-08 | Delivery is a sequence of vertical slices with exit criteria (section 17) | Every slice is a working scenario | None |
| D-09 | Policy engine: Lua policies in the same sandbox; OPA is an optional external adapter | Rego and CEL cannot be embedded in Nim without an external process | Q-07 in section 21 |
| D-10 | The external REST API stays JSON (OpenAPI 3.1) | The Protobuf requirement applies to internal contracts and plugins | Q-08 in section 21 |
| D-11 | Plugin manifests and platform configuration are JSON | A consequence of having no YAML; smaller parser surface | Q-08 in section 21 |
| D-12 | The analysis covers 20 systems | Breadth of the comparison | None |
| D-13 | The first-party set is 10 extensions in the MVP and the other 10 in stage 3 | Keeps the MVP deliverable | Q-05 in section 21 |
| D-14 | Microservice architecture from the first release; Kubernetes only | One deployment model to test and support | None |
| D-15 | No permanent agents or agent pools: the work of an agent for one step is done by the disposable runner shim in the step's Pod (RUN-010); the job controller creates a Pod per step and is connected to the shard by an outbound connection; a Pod can be started many times over a persistent run volume (RUN-014) and a volume can be reused across runs (STO-008) | No agent fleet to operate; start latency stays within RUN-013 | Measurements show that starting a Pod per step is unacceptable even with volume reuse |
| D-16 | Storage is attached to every step of a run; data moves between steps through the env file and files | One workspace model for all steps | Q-11 in section 21 |
| D-17 | Capacity grows by sharding: a shard is a set of services with its own rqlite and log circuit (two VictoriaLogs nodes and vlagent) | No cross-shard coordination on the hot path | Q-12 in section 21 |
| D-18 | Logs: a window (offset/limit) in the UI; the full log is a streamed download on request | Bounded browser memory | None |
| D-19 | Client memory is bounded by a budget (UI-008): JS heap ≤ 10 MiB, ≤ 5 MiB while viewing logs; checked by automated tests | People rarely look at the interface of a CI/CD system | None |
| D-20 | Logs are read (window, search, live tail, export) from one VictoriaLogs node chosen by the gateway (an `up` node whose vlagent queue is empty or smallest), retried on the other node on error; a lag of a couple of seconds is acceptable | The nodes are equal, a small lag is not critical for logs | The read load on one node does not meet NFR-005: spread reads over both nodes |
| D-21 | There is no storage coordinator and no storage failover. What remains is node health checking, snapshots, their upload and verification, and node recovery; these run in the log-circuit module inside the shard's core process (DAT-010, BKP-001--BKP-006); delivery and retries are vlagent's | VictoriaLogs has no master | Node recovery and snapshots prove too complex for a core module: move them to a service of their own |
| D-22 | While no VictoriaLogs node is reachable or vlagent does not accept writes, starting steps is forbidden; the core always knows the state of the log circuit and adapts execution to it (RUN-015) | There is nowhere to write the logs | Q-16 in section 21 |
| D-23 | The scheduler, the log collector and the log-circuit module run in one process (the shard core); the scheduler plans and the UI starts rqlite and log backups; logs are always on two VictoriaLogs nodes; a log snapshot is taken on a node with no delivery lag; node recovery is always automatic | The log circuit is part of the core module from the start | Planning delays under log-ingest load: move log ingest to a process of its own (7) |
| D-24 | Transport between the services of a shard is ZeroMQ REQ/REP with CURVE encryption and Protobuf messages. Services and the job controller authenticate with CURVE key pairs and the clients pin the server's public key; the shim uses the shared client key plus the task token (SEC-010) | `hyperx` (HTTP/2 on Nim) leaks up to 830 B per connection; gRPC C-core is 15.8 MiB and glibc-only; NATS puts a broker on the hot path; NNG is lean but its TLS stack adds a second certificate hierarchy, while CURVE needs only key files and the static client is smaller (A.4) | Measurements show a leak or unreachable throughput in the ZeroMQ path |
| D-25 | The HTTP layer is GuildenStern (pure Nim, MIT) with two vendored patches | Streaming responses with back-pressure, flat memory under keep-alive, connection churn and handler errors, no C dependency (A.5) | The server is unmaintained or a measured leak appears |
| D-26 | The Kubernetes client is the official C client behind a thin Nim binding, with a shared connection cache | A client that builds a TLS context per request leaks about 170 KiB per cycle; the C client with a shared connection cache is flat and faster (A.6) | A pure Nim client with a flat profile becomes available |
| D-27 | Log delivery: the shim masks, numbers and compresses the output into independent gzip blocks, queues them in a spool on the Pod's ephemeral storage and sends them to core, which proxies them to vlagent untouched and takes each block once. A full spool slows the build (back-pressure), nothing is lost. The Pod's own log carries only the shim's events | Core never sees plain text or recompresses; vlagent accepts independently compressed blocks glued together (A.8) | The spool proves too small or too slow in practice |
| D-28 | Retries: a step is repeated automatically only when it is known that its command never started (up to `infra_retries`, default 3). A step that started and whose outcome is unknown is not restarted: the run ends as an infrastructure error with the reason `outcome_unknown`. If only the log was not delivered, the command's own result stands | A half-finished deploy must not be started a second time by a machine | None |
| D-29 | Completion handshake and liveness: the shim reports the step's result to core and waits for permission to exit; the Pod's status is the fallback. One `liveness_timeout` (default 300 s) covers a Pod that did not start and a shim that went silent: core then finishes the step and removes the Pod | The result comes from the process that ran the command; silence alone never counts as loss before the timeout | None |
| D-30 | One vocabulary for the shim's state: the Pod-log events, the ZeroMQ heartbeat and rqlite carry the same JSON numbered by event, and reconcile by that number | Any source, in any order, converges on the same picture | None |
| D-31 | Secrets are masked in the shim before anything leaves the Pod: the raw value, base64 at every alignment, URL and JSON forms, and values the build registers at run time in `$CICD_MASK` | Core, the spool and the log store never hold a plain value | None |
| D-32 | Metrics are scraped only from core. Pods are short-lived: the shim reports resource use, JVM counters and the application's own endpoints to core, which exposes aggregates | One scrape target, no series per Pod | None |
| D-33 | The job controller keeps its own state in sqlite (adoption after a restart, retention of finished Pods, orphan sweep) and requires a namespace dedicated to it; every organisation has a controller of its own in its own namespace (SHD-007). Kubernetes access sits behind one seam so that decisions are tested without a cluster | Restarts must not lose Pods; the namespace is the controller's | None |
| D-34 | Execution-profile settings edited in the UI: `infra_retries`, `log_max_bytes` (default 1 GiB), `log_spool_bytes` (10 MiB), `log_hold_timeout` (600 s) and `liveness_timeout` (300 s) | Each limit is explicit and bounded | None |
| D-35 | Variables set in the UI (organization, group, project, pipeline) and launch parameters reach every step as ordinary environment variables of the container, with the current values at the moment the step's Pod is created; only the launch parameters are stored with the run. There is no snapshot of the variables for the run | A retry after fixing a variable sees the fix; nothing is added to rqlite; the script does not read the live variables, so replay stays deterministic (VAR-002). Other CI systems also read such variables when a job starts | Reproducing exactly what a past run used becomes a requirement that the log header (VAR-005) and the audit (VAR-006) cannot meet |
| D-36 | `$CICD_ENV` is a file on the run volume in `state/`, outside the workspace and outside rqlite; the user writes it, nothing captures a step's environment automatically; `$CICD_OUTPUT` returns at most 4 KiB per step to the script and is journaled | A process cannot change its parent's environment, an explicit file works in any language; outside the workspace the checkout, `git clean`, artifacts, caches and tools that read `.env` files do not touch it; the journal stays small (STO-003) | Users routinely lose variables they expected to pass: automatic capture is reconsidered |
| D-37 | The audit log can be stored in a separate pair of VictoriaLogs nodes (the setting `audit_store`, rqlite by default): events are chained and anchored in rqlite, the nodes have no delete API and their own retention | Keeps the growth of the audit out of rqlite; searchable with LogsQL; retention in VictoriaLogs is per node and the log circuit uses deletion by filter, so the audit needs a pair of its own to be append-only at the store level (A.7) | The audit volume stays so small that rqlite suffices, or running the audit circuit proves too costly |
| D-38 | There is no directory: a shard has a name made of digits and holds many organisations created in its UI, and the path prefix of an organisation's URL (`/<org>/`) at the ingress selects it; identities, memberships and the plugin catalogue are kept by each shard | No global service or database to run, back up and keep available, so a shard is independent end to end; the Ingress objects created by the core are the routing table, and the uniqueness of slugs comes from the database, the conflict of Ingress paths and the router's list | A user needs one view over organisations on different shards, or the core's right to manage Ingress objects and namespaces proves unacceptable |
| D-39 | In `multi` mode a small router microservice, installed once per cluster by a release of its own, keeps a registry of organisations in memory: every core registers its organisations with POST under a shared key and reads the list with GET; the router shows a page with the list and the availability and proxies nothing, every organisation is opened through its own Ingress. In `single` mode there is no router and Helm refuses a second organisation | Nothing depends on Kubernetes objects, as in the discovery of Talos; cores of other clusters register the same way and an entry expires when a core stops renewing it | The registry in memory proves too fragile (a restart empties it until the cores register again), or a shared key is not acceptable |
| D-40 | The steps of an organisation run in a namespace of its own, `<prefix>-<shard>-<org>`, which the core creates together with a job controller of the organisation (a ServiceAccount, a RoleBinding, a Secret and a Deployment), a ResourceQuota, a LimitRange and a default-deny NetworkPolicy; the core therefore holds a limited cluster-wide right over namespaces, fenced by an admission policy | Quotas, network rules, Pod Security and operator access can differ per organisation (SEC-012); a namespace shared by the shard would rest on Pod labels and one shared quota | The cluster-wide right is not acceptable in some installations: then one namespace per shard, with isolation expressed by labels, which is weaker |

# 1 Analysis method and criteria

The list is not an absolute ranking by market share. The systems are chosen to cover different mature models: a server with plugins, an integrated DevOps suite, SaaS workflow, a hybrid control plane, Kubernetes CRDs, a compact open-source CI, specialised CD, GitOps and programmable pipelines. The state of the features of systems 1--10 was checked against official documentation. For systems 11--20 the overview pages of the official documentation were checked; details that those pages do not contain are marked `[verify]`.

| **Criterion** | **Weight** | **What is assessed** |
|:---|:---|:---|
| Pipeline model | 15% | DAG, conditions, dynamics, reuse, typing |
| Executors | 15% | Self-hosted, cloud, Kubernetes, VM, containers, autoscaling |
| Extensibility | 15% | SDK, plugins, marketplace, API stability, isolation |
| Security | 15% | RBAC, secrets, supply chain, approvals, audit |
| Scaling | 15% | Queue, HA, fault tolerance, large monorepos |
| Developer experience | 10% | Logs, debugging, UI, local runs, IDE schema |
| Operations | 10% | Upgrade, backup, observability, resource cost |
| Portability | 5% | Independence from SCM and cloud, open formats |

# 2 Analysis of 20 CI/CD systems

## 2.1 TeamCity

A mature on-prem server with projects and build configurations, strong dependency chains, Kotlin DSL, build agents and convenient test diagnostics.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| A good administrative model and UX; configuration templates; parameters and artifact dependencies. | A commercial model; the DSL is tied closely to the product API; JVM plugins can complicate upgrades; the control plane is heavier than compact systems. | Take the project hierarchy, templates, build chains, typed parameters and test investigation. |

## 2.2 Jenkins

An open-source automation server; Declarative/Scripted Jenkinsfile; controller/agents; a huge plugin ecosystem and shared libraries.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Maximum extensibility; almost any environment; durable/pausable pipelines; a mature base of integrations. | Plugins run inside the JVM and form dependency hell; Groovy/CPS is complex; security and HA require discipline; the UI and configuration are uneven. | Take the imperative pipeline script with durable execution (in our model Lua with a replay journal), the simple step API, shared libraries and UI extension points. Forbid in-process third-party plugins. |

## 2.3 GitHub Actions

Workflows in the repository, events, jobs, reusable workflows, composite/Docker/JavaScript actions, hosted and self-hosted runners.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| The best path from a commit/PR to a workflow; a large marketplace; matrix; OIDC to clouds; clear composition. | Strong tie to GitHub; the risk of unpinned actions; YAML expressions have rough edges; local emulation is incomplete. | Take the event model, marketplace UX, reusable workflows and immutable pinning. |

## 2.4 GitLab CI/CD

An integrated model of stages/jobs/DAG, runners, includes/components, environments, deployments, variables and security reports.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| A coherent SDLC; rich YAML; child/parent pipelines; environment UX; a self-managed option. | A large platform is hard to operate; some features depend on the tier; YAML rules/includes get complicated quickly. | Take components with typed inputs, environments, review apps and reports, separating CI from Git hosting. |

## 2.5 Azure Pipelines

Multi-stage YAML, templates, variable groups, environments/checks, hosted/self-hosted agents, service connections.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Strong enterprise governance, approvals/checks and heterogeneous runners; mature Azure DevOps integration. | Complex terminology and expressions; part of the UX depends on Azure DevOps; service connections can be heavyweight. | Take protected environments, checks and centralised service connections. |

## 2.6 CircleCI

Workflows, jobs, executors, orbs, caching/workspaces, hosted and self-hosted runners.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Good start speed; orbs as reusable packages; convenient performance insights and test splitting. | The main experience is SaaS-centric; orb portability is limited; dynamic configuration adds a second stage to understand. | Take a versioned component registry and test timing optimisation. |

## 2.7 Travis CI

A simple `.travis.yml`, lifecycle phases, build matrix, conditions, caching and deployment providers.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| A low entry threshold and a compact model for small and open-source projects. | Fewer governance capabilities and complex enterprise DAGs; historic SaaS dependency; less expressive composition. | Keep the low entry threshold: pipeline-script templates for common languages and a built-in `matrix` helper. |

## 2.8 Buildkite

A SaaS control plane with self-hosted agents, queues/tags, dynamic pipelines, block/wait/trigger steps and plugins.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| A clear separation of control and compute; high scalability; agents stay in the customer's network. | The control plane is usually external; the security of agents and plugins remains the customer's responsibility; cost at scale. | Take queues, dynamic upload and independent compute scaling. The pull model is applied at cluster level: the in-cluster job controller connects to the shard with an outbound connection. |

## 2.9 Tekton

Kubernetes CRDs for Tasks, Pipelines and Runs; workspaces, results, chains; reconciliation through controllers.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Kubernetes-native, declarative and composable tasks; natural ephemeral execution. | Verbose CRDs; a weaker ready-made end-user UI; Kubernetes becomes mandatory complexity; debugging needs Kubernetes knowledge. | Take reconciliation, Pod isolation, results, the entrypoint wrapper of a step and signed provenance, but hide the CRDs behind a convenient API. |

## 2.10 Woodpecker CI

A lightweight open-source CI with YAML pipelines, container steps, server/agent, plugins as containers and compatibility with popular forges.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Simplicity, a small operating cost, safer than in-process plugins, a good self-hosted baseline. | Less enterprise governance, analytics and complex orchestration; an ecosystem smaller than Jenkins or GitHub. | Take the container plugin contract and the minimal installation model. |

## 2.11 Argo Workflows and Argo CD

Argo Workflows is a Kubernetes-native workflow engine (CRDs, a CNCF graduated project) in which every step is a container. Argo CD is a declarative GitOps continuous-delivery tool for Kubernetes.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Workflows: DAG or steps, WorkflowTemplates, artifacts (S3, GCS, Azure Blob, HTTP, Git), retry/timeout/suspend/resume, cron, REST and gRPC APIs, UI, SDKs. CD: OutOfSync/health statuses, ApplicationSets, multi-cluster, SSO (OIDC, OAuth2, LDAP, SAML), RBAC, rollback, hooks, notifications, audit. | Workflows depend on Kubernetes and require container knowledge; events are a separate project, Argo Events; complex patterns are hard. CD: all changes go through Git, there is no real imperative control; it is not CI. | Take the artifact repository abstraction, suspend/resume, cron workflows, sync/health statuses in the environment view and generation of uniform objects on the model of ApplicationSets. Continuous GitOps reconciliation is not in the MVP (4.2). |

## 2.12 Drone

A CI platform configured by `.drone.yml`, with container plugins, secrets, promotion and cron jobs. Shipped as Community Edition (open source) and Enterprise Edition; maintained by Harness, a related project is Gitness.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Simple configuration; container plugins; integrations with GitHub, GitHub Enterprise, Gitee, Bitbucket, Bitbucket Server and Gitea; templates. | Some capabilities are in the Enterprise Edition `[verify]`; development is tied to Harness's plans `[verify]`; less governance. | Take promotion as a first-class action, cron triggers and a minimal runner. The container plugin contract is already taken over from Woodpecker. |

## 2.13 Atlassian Bamboo

Atlassian's CI/CD server: plans, stages, jobs, deployment projects, a tight link with Jira and Bitbucket `[verify]`.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Builds and releases are tied to Jira issues and Bitbucket repositories; deployment projects with environments `[verify]`. | End of life has been announced for Bamboo Data Center: according to a JetBrains Blog post citing Atlassian, sales to new customers end in 2026 and full EOL is 28 March 2029 (to be confirmed on the Atlassian site). No full DAG beyond stages `[verify]`. | Fold the environment model of deployment projects into environments. This is a separate migration market: a Bamboo importer is in the backlog after stage 5 (section 16). |

## 2.14 Spinnaker

An open-source multi-cloud continuous-delivery platform built from microservices: Orca (orchestration), Clouddriver (cloud providers), Gate (API), Deck (UI), Echo (events), Igor (CI integration), Front50 (storage), Rosco (images).

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Pipelines of stages, pipeline templates, expressions; canary analysis, blue/green, automatic rollback (above all on Kubernetes); AWS, Azure, Google Cloud, Kubernetes, Oracle Cloud, Cloud Foundry. | Many services; production needs Redis, an SQL store, monitoring and security; oriented to CD, not CI. | Take the canary and blue/green rollout strategies as CD plugins (Helm/Kubernetes), the execution history of a stage and the idea of pipeline templates. Do not copy the multi-service topology. |

## 2.15 Harness CI/CD

A commercial platform: a pipeline of stages and steps in YAML; the Harness Delegate is software that runs tasks in the customer's infrastructure without sending credentials out; cloud and self-hosted variants are available.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| The delegate as a trust boundary; a single platform for CI and CD; Test Intelligence and caching `[verify]`; governance and policy as code `[verify]`. | A commercial model; the depth of capabilities depends on modules and plan `[verify]`; SaaS orientation `[verify]`. | Take the delegate model for environments with local secrets and cluster access (the in-cluster job controller with a limited scope) and policies at environment level. Test Intelligence is in the backlog. |

## 2.16 Semaphore

CI/CD with a hierarchy of workflows, pipelines, blocks and jobs. Editions: Cloud (SaaS), Community Edition v1.5 (open source), Enterprise Edition v1.5 (self-hosted).

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Promotions for conditional advancement between pipelines; change detection for monorepos; hosted and self-hosted agents; caches, parallelism, test reports with flaky detection; a public API and CLI. | The main experience is SaaS; integrations per the documentation are GitHub and Bitbucket, narrower than we need; a smaller extension ecosystem `[verify]`. | Take promotions (manual and automatic) as a single gate mechanism, change detection as the basis of path filters (PRJ-004) and flaky detection (DAT-005). |

## 2.17 Bitbucket Pipelines

CI/CD built into Bitbucket Cloud: configuration in `bitbucket-pipelines.yml`, sequential and parallel steps, pipes, deployments, self-hosted runners.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Pipes as ready reusable components; deployment tracking by environment; Linux Docker, Linux Shell, Windows and macOS runners; caches. | A tight tie to Bitbucket Cloud; limits on minutes and pushes; a simple orchestration model. | Take the packaging format of ready steps (pipes) for the plugin contract and the classification of runners by executor type. |

## 2.18 AWS CodePipeline

A managed AWS continuous-delivery service that models and automates the stages of a release. There are pipeline types V1 and V2 (V2 adds trigger configuration parameters and release safety); integration with CodeBuild and CodeDeploy `[verify]`.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| A clear model of stages and actions; input and output artifacts; execution modes (superseded, queued, parallel) and stage conditions `[verify]`. | AWS only and a managed service only; the pipeline structure is described in JSON; not self-hosted. | Take the concurrency modes (superseded, queued, parallel) as the PIP-010 policies and stage conditions as environment checks (DEP-002). |

## 2.19 Concourse CI

A CI system with a core of three concepts: resources (external state), jobs (sequences of get, put and task steps) and tasks (containerised work). Pipelines are described as "distributed Makefiles".

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Every task runs in an isolated container with its own image; resource types are defined inside the pipeline without server plugins; horizontal scaling of workers; the `fly` CLI. | The documentation itself admits a steep learning curve; weaker diagnostics UX `[verify]`; no imperative logic in the pipeline. | Take the model of versioned resource inputs and outputs as the basis of reproducibility and version triggers, a container per step and a CLI that controls the pipeline. |

## 2.20 Dagger

An engine of programmable pipelines: described in code through SDKs (Go, Python, TypeScript and others), containerised execution on BuildKit, an automatic cache, end-to-end tracing, a GraphQL API.

| **Strengths** | **Limitations** | **What we take over** |
|:---|:---|:---|
| Identical execution locally and in CI; a real programming language instead of script workarounds; cache and tracing out of the box. | It is not a CI server or scheduler: no queues, agents or hosting. | Take parity between local and server runs (`cicd run --local`), a programmable pipeline API and step tracing. |

## 2.21 Summary matrix

| **System** | **Self-hosted** | **DAG** | **Reuse** | **Plugins** | **K8s** | **Main model** |
|:---|:---|:---|:---|:---|:---|:---|
| TeamCity | Yes | Yes | Templates/Kotlin | JVM/API | Agents/Cloud | Manageability |
| Jenkins | Yes | Yes | Libraries | Very many | Plugin | Extensibility, imperative pipeline |
| GitHub Actions | Runner | Yes | Actions/workflows | Marketplace | ARC | DX and events |
| GitLab CI | Yes | Yes | Includes/components | Integrations | Runner | Full SDLC |
| Azure Pipelines | Server/agents | Yes | Templates | Tasks | Agents | Governance |
| CircleCI | Runner | Yes | Orbs | Orbs | Runner | Performance |
| Travis CI | Enterprise | Limited | Templates | Providers | Limited | Simplicity |
| Buildkite | Agents | Yes | Dynamic | Plugins | Agent stack | Hybrid compute |
| Tekton | Yes | Yes | Tasks/Bundles | Catalog | Native | Reconciliation |
| Woodpecker | Yes | Yes | Templates | Containers | Yes | Minimalism |
| Argo WF/CD | Yes | Yes | WorkflowTemplates/ApplicationSets | Argo Events, hooks | Native | Reconciliation, GitOps |
| Drone | Community | Yes\* | Templates | Containers | Runners\* | Container plugins |
| Bamboo | Server/DC (EOL 2029) | Limited\* | Specs\* | Marketplace\* | Agents\* | Deployment projects |
| Spinnaker | Yes | Yes\* | Pipeline templates | Plugins\* | Provider | Rollout strategies |
| Harness | Delegate/self-hosted | Yes\* | Templates\* | Steps\* | Delegate | Trust boundaries |
| Semaphore | CE/EE | Yes\* | Limited\* | Toolbox\* | Agents\* | Promotions, UX |
| Bitbucket Pipelines | Runners | Limited | Pipes | Pipes | Runners | Pipes |
| AWS CodePipeline | No (managed) | Stages/actions | Limited | Action providers\* | Through EKS/CodeBuild\* | Execution modes |
| Concourse | Yes | Yes\* | Resource types/tasks | Resource types | Workers | Resource model |
| Dagger | Engine (not a CI server) | Yes | Modules | SDK/modules | Runner\* | Programmable pipelines |

\* The cell is not confirmed by the documentation overview page; verify (`[verify]`).

# 3 Catalogue of 20 mandatory extensions

A plugin below means a signed extension package with a manifest, a configuration JSON Schema and one or more components: trigger, step, report parser, secret provider, notifier, policy check or UI contribution. Extensions have two support tiers: the 10 first-tier extensions ("M" in the "Stage" column) are in the MVP and supported first-party; the other 10 ("3") are implemented first-party in stage 3 (section 17). After that any extension can evolve independently but passes the same verification (PLG-003, PLG-004).

| **No.** | **Extension** | **Type** | **Key function** | **Security control** | **Stage** |
|:---|:---|:---|:---|:---|:---|
| 1 | Git | SCM | Clone/fetch, shallow/partial clone, submodules, LFS, commit metadata, merge ref | SSH/HTTPS credentials; known_hosts; ref allowlist | M |
| 2 | GitHub | Forge | App/webhooks, PR checks, commit status, comments, releases | GitHub App tokens; webhook signature; fork trust policy | M |
| 3 | GitLab | Forge | OAuth/App, merge request status, pipeline triggers, releases | Scoped tokens; protected refs; webhook secret | M |
| 4 | Bitbucket | Forge | Cloud/Data Center webhooks, build status, PR metadata | OAuth/permissions; rate limits | 3 |
| 5 | Docker BuildKit | Build | buildx, multi-arch, layer cache, metadata, push, SBOM/provenance | Rootless mode; registry auth; privileged denied by default | M |
| 6 | Kubernetes | CD | Apply/wait/rollout, namespace environments (running a job in a Pod is part of the core, not a plugin) | ServiceAccount per project; NetworkPolicy; admission controls | M |
| 7 | Helm | CD | Template/diff/upgrade/rollback, OCI charts, values artifacts | No secret values in logs; atomic mode; namespace policy | M |
| 8 | Terraform/OpenTofu | IaC | fmt/validate/plan/apply, plan report, state lock, policy gate | Apply requires environment approval; remote state credentials are short-lived | 3 |
| 9 | HashiCorp Vault/OpenBao | Secrets | JWT/OIDC auth, dynamic secrets, transit operations, lease renew/revoke | Secrets never persist in DB; response wrapping; audit correlation | M |
| 10 | AWS | Cloud | OIDC role assumption, ECR/EKS/S3/CloudFormation deployment steps | No long-lived keys by default; session tags; audience validation | 3 |
| 11 | Azure | Cloud | Workload identity, ACR/AKS, CLI and deployment tasks | Federated credential; tenant/subscription allowlist | 3 |
| 12 | Google Cloud | Cloud | Workload Identity Federation, Artifact Registry/GKE/Cloud Run | Short-lived token; project allowlist | 3 |
| 13 | Nexus Repository | Artifacts | Publish/download Maven, npm, NuGet, raw; promotion and checksums | Repository scoped token; immutable release policy | 3 |
| 14 | JFrog Artifactory | Artifacts | Build info, publish, promotion, Xray metadata | OIDC/access token; checksum deploy | 3 |
| 15 | JUnit and test reports | Report | JUnit XML, TRX, NUnit, flaky history, test ownership | Parser limits; untrusted XML hardened against XXE | M |
| 16 | SonarQube | Quality | Scanner wrapper, quality gate wait, MR decoration | Token masking; fail/unstable policy configurable | 3 |
| 17 | Trivy and SBOM | Security | Filesystem/image/IaC scan, SARIF, CycloneDX/SPDX, severity gate | Pinned DB/source; exemptions audited | 3 |
| 18 | Slack and Mattermost | Notification | Start/failure/recovery/deployment notifications, actions | Signed callbacks; channel allowlist; secret redaction | 3 |
| 19 | Email SMTP | Notification | Templated mail, digest, recipient policies | No arbitrary recipients from untrusted forks; TLS required | M |
| 20 | Prometheus OpenTelemetry Grafana | Observability | Metrics, traces, log correlation, dashboards and alerts | Tenant labels; cardinality budgets; no secret attributes | M |

# 4 Product boundaries

## 4.1 In the MVP

- Organisations, groups, projects, repositories, pipeline definitions, runs, jobs, artifacts, environments, execution profiles and credentials.

- Webhook, push, pull/merge request, tag, schedule, API and manual triggers; deduplication and cancellation of outdated runs.

- Imperative Lua pipeline scripts (6.2): sequential and parallel execution, matrix, conditions and loops by means of the language, retries, timeouts, services, artifacts, caches and approvals that suspend without holding an agent.

- Execution on Kubernetes without permanent agents: a Pod per step, shared storage for all steps of a run (6.8), execution profiles (namespace, node selector, RuntimeClass, quotas), Linux nodes only, an in-cluster job controller.

- OIDC login, a local bootstrap admin, RBAC, an audit log, masked/protected variables and an external secret provider.

- Logs in VictoriaLogs with window viewing in a sandboxed iframe and streamed download (DAT-007), JUnit test reports, artifacts, basic metrics, the REST API, the CLI and plugin SDK v1 (Protobuf).

- Permanent links to every UI element, dynamic lists, server-side charts, a client memory budget (UI-008) and three UI extension points: a run/job tab, a dashboard widget and a parameter form element (13).

- Sharding: an organisation is pinned to a shard by the path prefix of its URL at the ingress (`/<org>/`), with no global directory; the MVP runs one shard, but the data model and routing are shard-oriented from the first slice (7.3).

- Ten first-tier first-party extensions: Git, GitHub, GitLab, Docker BuildKit, Kubernetes, Helm, Vault/OpenBao, JUnit, SMTP, Prometheus/OTel.

## 4.2 Not in the MVP

- Hosting of Git repositories, an issue tracker, a general-purpose container registry and a full package registry.

- A visual drag-and-drop editor as the source of truth; a mobile application; AI generation of pipelines without review; an SPA front end.

- A YAML pipeline dialect (pipelines are described only by Lua scripts); WASM extensions (open question Q-06).

- Operation outside Kubernetes: Docker Compose, VM and bare-metal executors, a shell executor, permanent agents, Windows and macOS nodes; an own VM hypervisor; billing SaaS; absolute compatibility with all Jenkins plugins.

- Global full-text search across the logs of all projects (the MVP searches within a job and a run); online transfer of organisations between shards (the MVP has only offline transfer by an administrative tool) (open question Q-12).

- Continuous GitOps reconciliation at the level of Argo CD/Flux: the platform starts and observes a deployment but does not replace a GitOps controller.

# 5 Users and permissions

| **Role** | **Main actions** | **Default prohibitions** |
|:---|:---|:---|
| Platform admin | HA, shards, execution profiles, global plugins, auth, quotas, audit, backup | Does not read secret values |
| Organization owner | Members, projects, org credentials, policies | Does not change the global trust policy |
| Project maintainer | Pipelines, schedules, environments, project credentials | Does not reveal secret values |
| Developer | Run, view, retry, artifacts, non-prod deploy | No prod approval, no management of shards and execution profiles |
| Release manager | Approvals, protected environments, releases | Cannot change the pipeline after approval |
| Auditor | Read-only configs, runs, approvals, audit exports | Cannot run or download sensitive artifacts |
| Service account | API within scopes and expiry | No interactive login; token rotation is mandatory |

**IAM-001 RBAC.** Check authorization on every API and event consumer; the scope is given by the resource path organization/project/environment, a role and an optional condition.

**IAM-002 SSO.** Support OIDC in the MVP; SAML 2.0 in the enterprise milestone. Allow group-to-role mapping and a break-glass account with mandatory audit.

**IAM-003 Token model.** Store API tokens only as an Argon2id hash, show them once, support scopes, expiry, last-used and revoke. The bootstrap token of the in-cluster job controller is exchanged once for a CURVE key pair; a job Pod receives only a short-lived task token (SEC-010).

**IAM-004 Tokens for embedded views.** Browser access to iframe content (logs, plugin panels) is granted only by a short-lived signed token bound to the user, the resource and the origin (DAT-007, PLG-007). The token gives no rights beyond those checked at issue time and is not issued from a session cookie without an RBAC check.

# 6 Functional requirements

## 6.1 Projects and repositories

**PRJ-001 Hierarchy.** An organisation contains groups, which may be nested, and a group contains projects (a project created directly under an organisation lives in the organisation's root group). A group or a project may inherit policy, variables, execution profiles (RUN-004) and libraries from the level above, but an override is shown explicitly.

**PRJ-002 SCM neutrality.** One project connects several GitHub, GitLab, Bitbucket or generic Git repositories; an SCM adapter must not require changes to the scheduler core.

**PRJ-003 Discovery.** The system discovers the pipeline script automatically on configurable paths (`.ci/pipeline.lua` by default), runs the metadata phase (PIP-002) and builds a preview of triggers, parameters and required execution profiles before the first run.

**PRJ-004 Monorepo.** Path filters are computed against the merge-base; include/exclude, ownership and starting child pipelines (`ci.run`) for changed subprojects are supported. The function `run.changed_paths()` is available to the script and is written to the journal.

## 6.2 Pipeline scripts and execution

A pipeline is a Lua 5.4 script executed in the sandbox of the pipeline executor. The model borrows from Jenkins the ability to write ordinary code (conditions, loops, error handling) and the reliability of durable execution, but instead of a CPS transformation of Groovy it uses a call journal and replay. The script does not do the work itself: it describes steps, and each step runs in a separate container on Kubernetes (6.4). Terminology: a **job** is a named block with a common image, resources and environment; a **step** is one call of `j.sh` or `j.use`, which runs in a separate Pod; a **run** is one execution of a pipeline.

**PIP-001 Bundle and versioning.** Every run stores an immutable bundle: the source script, the commit SHA, the digest of every connected Lua module and plugin, the Lua API version and the runtime version. A change of the script in the repository does not affect a run that has already been created.

**PIP-002 Two phases.** The script returns a table `ci.pipeline{...}` with metadata fields (`name`, `on`, `params`, `env`, `requires` --- execution profiles, `storage`, `permissions`, `concurrency`, `timeout`) and a function `main`. The metadata phase runs at discovery and at run creation in a mode without side effects: only type constructors and pure functions are available. The execution phase calls `main(run)`.

**PIP-003 Call journal.** `main` runs as a coroutine. Every host API call that has a side effect or a result is written to the append-only run journal: `(run_id, seq, type, call fingerprint, result)`. This covers `ci.job`, `j.sh`, `j.use`, `j.env`, `ci.parallel`, `ci.spawn`, `ci.input`, `ci.run`, `ci.sleep`, `ci.now`, `ci.random`. The result of a step includes the exit code and `outputs` (STO-003), so data passed between steps is reproducible on replay. Calls must be suspendable through `pcall` so that ordinary Lua error handling works. Waiting for a step, an approval or a timer frees the executor and takes no cluster resources.

**PIP-004 Replay.** When an executor fails, restarts or is rebalanced, a new worker runs the same bundle from the beginning, substituting results from the journal for real calls until it reaches the first call with no record; from there execution proceeds normally. A step that was started but not finished at the moment of failure is not started again: the job controller reports its actual state by the deterministic Pod name (RUN-002). If the fingerprint of a call does not match the journal record, the run gets the state `infrastructure_error` with the code `script_nondeterminism`, and the diagnostics give the `seq`, the expected call and the actual call.

**PIP-005 Sandbox determinism.** Mandatory measures: (a) `io`, `os`, `debug`, `dofile`, `loadfile` and `package.loadlib` are removed; `load` accepts only text chunks; `collectgarbage` is restricted; (b) `math.random` is replaced by the journaled `ci.random` and time is available only through `ci.now`; (c) `pairs` and `next` are replaced by iteration in a stable order (the sequential part first, then the keys sorted by type and value); table keys and function keys are forbidden because their order depends on addresses; (d) the string hash seed of Lua is fixed at build time (`luai_makeseed`, `src/executor/lua_glue.c`; tested in `tests/unit/tsandbox.nim`); (e) `tostring` and `%p` do not print addresses; (f) the global environment is write-protected after start.

**PIP-006 Limits.** Per-run limits apply: Lua state memory (64 MiB by default, implemented through a custom `lua_newstate` allocator), a CPU budget between host API calls (an instruction counter through a hook, 50 million by default), the number of journal records (100 000 by default), the width of `parallel` and `matrix` (1 000 by default), and total duration. Exceeding a limit finishes the run in state `failed` with the limit code. The values are configurable by policy.

**PIP-007 Graph.** The UI builds the run graph from the journal; the page is rendered on the server (UI-009), the graph is a server-side SVG with fragment updates over SSE. Nodes: stage, job, step, parallel branches, spawn/wait and input. The order of dependencies is given by code: `ci.spawn` returns a handle and `handle:wait()` is possible only for a handle that already exists, so cycles are structurally impossible.

**PIP-008 Stages.** `ci.stage(name, fn)` groups calls for the UI, metrics and restart from a stage (PIP-015); a stage does not limit parallelism.

**PIP-009 Matrix.** `ci.matrix` builds the Cartesian product of axes with include/exclude, `max_parallel` and `fail_fast`; the result is executed through `ci.parallel`. The expansion limit is checked at the call and, where the size is computed statically, at preflight (PIP-016).

**PIP-010 Child pipelines.** `ci.run(ref, params, opts)` creates a child run (in the same or another project of the same shard if policy allows; a project on another shard cannot be called, SHD-002) and with `wait=true` suspends the parent until the result. A child run passes policy like an ordinary one, gets its own storage (STO-001) and keeps a reference to the parent.

**PIP-011 Libraries.** A Lua module is published to the registry with SemVer, a digest and a declaration of inputs and outputs. `require("lib/go@1.4.0")` is resolved through the lockfile `.ci/lock.json` (name, version, digest); a production policy may forbid mutable refs. A module is loaded only by digest and runs in the same sandbox.

**PIP-012 Typed parameters.** The `params` field uses type constructors (`ci.string`, `ci.number`, `ci.bool`, `ci.choice`, `ci.list`, `ci.map`, `ci.secret`). Values are validated before the run starts, and the UI builds the launch form from these declarations (13).

**PIP-013 Manual gates.** `ci.input{...}` suspends the run without holding a Pod or any other cluster resource. An approval contains the approver, a timestamp, a comment, a policy snapshot and the SHA; the author of a change cannot approve their own prod deploy when separation of duties is enabled.

**PIP-014 Concurrency.** Support a concurrency group and the policies queue, cancel-oldest and cancel-newest, given in `ci.pipeline{concurrency=...}`; the lock lease is restored after a scheduler failure.

**PIP-015 Retries and restart.** A retry of a step or job creates a new attempt with the same bundle and the same run storage if the run is still active. A retry of a finished run supports the modes `full`, `failed-only` and `from-stage`: the new run replays the journal of the previous one up to the chosen point, substituting successful results, `outputs` and artifacts. The storage of the previous run is not reused: only recorded artifacts and outputs are restored, and the contents of the workspace only when snapshots are enabled (STO-006) (open question Q-11).

**PIP-016 Static check.** `cicd pipeline check` and the server-side preflight run the metadata phase and static analysis: forbidden globals, unknown plugins and versions, parameters that do not match the schema, host API calls outside `main`, known limit violations, unknown execution profiles. The check does not guarantee that the script terminates.

**PIP-017 IDE.** Type annotations (`lua/stdlib/cicd.d.lua`, LuaLS format) are shipped for autocompletion and type checking of the host API.

**PIP-018 Step options.** `ci.job` and `j.sh` accept `timeout`, `metrics` (docs/metrics.md) and `mask` (docs/secrets-masking.md) options. Options of a job are the defaults of its steps and a step overrides them key by key. The sandbox validates the options and reduces them to one canonical JSON object, so that the same declaration is always the same bytes in the journal.

## 6.3 Example pipeline

```lua
local ci = require("cicd")                 -- host API v1
local go = require("lib/go@1.4.0")         -- module by lockfile (digest)

return ci.pipeline {
  name = "service-ci",
  on = {
    push = { branches = { "main" } },
    pull_request = {},
  },
  params = {
    deploy = ci.bool { default = false },
  },
  env = { IMAGE = "registry.example.com/team/service" },
  storage = { size = "5Gi" },              -- shared run storage (6.8)

  main = function(run)
    ci.stage("test", function()
      ci.job({ image = "golang:1.25-alpine" }, function(j)
        j.checkout()                       -- into /cicd/workspace/src
        go.test(j, { json = "test.json" })
        j.use("reports/go-test@1.2.0", { path = "test.json" })
      end)
    end)

    ci.stage("image", function()
      ci.job({ permissions = { registry = "write", oidc = "write" } }, function(j)
        local r = j.use("build/buildkit@2.1.0", {
          image = run.env.IMAGE .. ":" .. run.commit,
          provenance = true,
        })
        j.env { DIGEST = r.outputs.digest } -- pass data to the following steps
      end)
    end)

    if run.params.deploy and run.branch == "main" then
      ci.deploy("production", function(j)
        j.use("deploy/helm@3.0.0", { release = "service", chart = "./chart", atomic = true })
      end)
    end
  end,
}
```

The example shows the imperative capabilities (error handling, a manual decision, parallel branches) and passing data between steps through the `$CICD_ENV` file.

```lua
main = function(run)
  local ok = pcall(function()
    ci.job({ image = "registry.example.com/ci/tools:2" }, function(j)
      j.sh("./integration.sh")
    end)
  end)
  if not ok then
    ci.input {
      message = "The integration tests failed. Continue the rollout?",
      approvers = { "role:release-manager" },
      timeout = "4h",
    }
  end

  ci.job({ image = "alpine:3.21" }, function(j)
    -- one line: export in this shell, pass on to the following steps ($CICD_ENV) and return to the script ($CICD_OUTPUT), STO-003
    local r = j.sh([[export VERSION="1.$(date +%Y%m%d)" && echo "VERSION=$VERSION" | tee -a "$CICD_ENV" >> "$CICD_OUTPUT"]])
    ci.log("info", "version: " .. r.outputs.VERSION)
    j.sh('echo "building $VERSION"')     -- VERSION is already in the step environment
  end)

  local builds = ci.matrix {
    axes = { target = { "server", "worker" }, arch = { "amd64", "arm64" } },
    exclude = { { target = "worker", arch = "arm64" } },
    max_parallel = 3,
  }
  local jobs = {}
  for _, c in ipairs(builds) do
    jobs[c.target .. "-" .. c.arch] = function()
      ci.job({ image = "golang:1.25", profile = "build-" .. c.arch,
               workspace = "isolated" }, function(j)
        j.sh("make dist TARGET=" .. c.target)
      end)
    end
  end
  ci.parallel(jobs, { fail_fast = true })
end
```

## 6.4 Runs, queue and execution

The platform works only inside Kubernetes and uses no permanent agents: there are no long-lived executor processes on nodes, no agent registration and no agent pools. The agent's duties for one step are carried out by the runner shim (RUN-010), a disposable wrapper that lives only as long as its step and reports its state to the core (RUN-016); it neither registers, nor asks for work, nor holds rights in the cluster. Every step runs in its own Pod (container), which the job controller creates and watches. The job controller is the only component of a shard that holds rights in the cluster (SEC-010).

**RUN-001 Run state.** Run states: created, compiling, queued, running, waiting, succeeded, failed, canceled, skipped, timed_out, infrastructure_error. The state `compiling` means the metadata phase and preflight. Transitions are compare-and-swap writes (`UPDATE ... WHERE id=? AND version=?`); all writes to rqlite are serialised by the leader of the shard's cluster. Step states: pending, starting, running, succeeded, failed, canceled, timed_out, lost. The state machines are generated from `src/common/states.nim` into `docs/state-machines.md`.

**RUN-002 Step dispatch.** The scheduler places a step in the shard queue and the job controller receives tasks over a long-lived outbound Protobuf channel over ZeroMQ (REQ/REP with CURVE; the controller connects to the scheduler itself, there are no inbound connections into the cluster). For every step the controller creates a Pod with the deterministic name `ci-<run>-<seq>-<attempt>`: creating it again after a channel retry returns `AlreadyExists` and is safe (idempotence and fencing). The controller observes the Pod through the Kubernetes API and passes only state transitions to the scheduler. After a restart the controller continues with the Pods recorded in its own state (D-33). A report about an attempt that is no longer the step's current one changes nothing (fencing), but late log blocks of an older attempt are stored under that attempt's own label. The loss of the controller itself is detected by one heartbeat per controller (in the scheduler's memory, not written to rqlite); leadership among replicas is a Kubernetes Lease.

**RUN-003 Fair scheduling.** A weighted fair queue between organisations and projects; separate quotas for concurrent Pods, CPU/memory requests, storage volume and privileged capabilities.

**RUN-004 Execution profiles.** A profile (the replacement for agent pools) defines: namespace, node selector and tolerations, RuntimeClass, default and maximum resources, StorageClass, a ServiceAccount without rights, a NetworkPolicy class, allowed projects, maximum parallelism, trust level, and the settings of D-34. A job selects a profile with the `profile` field or gets the project's default profile. Only Linux nodes; Windows and macOS are not supported. By default the namespace of a profile is the organisation's namespace `<prefix>-<shard>-<org>` (SHD-007); it is dedicated to the job controller (D-33).

**RUN-005 Ephemeral Pods.** A step Pod is created under restricted Pod Security (non-root, no capabilities, seccomp RuntimeDefault, read-only root where the image allows). A finished Pod is kept after its result is recorded, for 10 minutes after a success and 6 hours otherwise, so that it can be inspected, and is then removed. Orphaned Pods (labelled `ci-*` in the dedicated namespace but unknown to the controller) are removed after a grace period, and so are orphaned PVCs and Secrets (GC by `cicd.io/run` labels).

**RUN-006 Cancellation.** Cancellation reaches the controller within 5 seconds at p95; the controller deletes the Pod with a grace period (SIGTERM, then SIGKILL); the cleanup step from `ci.finally` has its own timeout. Cancelling a run interrupts `main` with an exception that can be caught only inside a `ci.finally` block. The shim forwards SIGTERM to the whole process tree of the build, finishes the log delivery and reports the reason `terminated` (RUN-017).

**RUN-007 Log delivery resilience.** The runner shim (RUN-010) turns the step's output into numbered, masked, compressed blocks and queues them in a spool on the Pod's ephemeral storage (10 MiB by default, `log_spool_bytes`). A sender delivers the blocks to the log collector (DAT-001) in order; a block is deleted from the spool only after core has acknowledged it, and core acknowledges only after vlagent accepted it. When delivery is slow or fails, the spool fills and the shim stops reading the build's pipe, so the build is slowed (back-pressure) and nothing is lost. The memory of the shim does not depend on the size of the log. A step that has finished waits up to `log_hold_timeout` (600 s) for its log to be delivered; after that its result stands, the log is marked incomplete and the reason is `logs_undelivered`. A spool that cannot be written degrades the log but never the step. The stored log of a step is bounded by `log_max_bytes` (1 GiB by default): past it one marker line is stored and the rest of the output is counted and dropped.

**RUN-008 Pipeline executor.** Executor workers are separate processes (SEC-007) that lead a run on a lease with a TTL extended by the scheduler in memory (rqlite receives the grant of a lease and an extension not more often than `lease_persist_interval`, 60 s by default; after a scheduler restart a grace TTL applies and the worker confirms its lease by `lease_token`). When an executor is lost another worker performs replay (PIP-004). The script has no access to the network, the database or the file system; all interaction goes through the Protobuf channel to the scheduler. An executor survives a restart of the core: it reconnects and continues.

**RUN-009 Density.** One executor worker leads many runs (one Lua state per run) within the worker's memory limit and a configurable number of runs (200 by default).

**RUN-010 Runner shim.** The shim is a static Nim binary (≤ 1 MiB packed), not a daemon: it reaches the Pod through a ConfigMap mount and is the entrypoint wrapper of the user's command (on the model of the Tekton entrypoint). The shim: prepares the environment (loads the env file, STO-003; prints the variables header of a run's first step, VAR-005), starts the command as a child process in its own process group, at a lower CPU priority and a higher OOM score than its own so that it outlives trouble in the build, reads stdout/stderr, masks secrets (SEC-011, D-31), spools and delivers the log (RUN-007), samples the container's resources and the application's metrics (docs/metrics.md), enforces the step timeout (RUN-017), collects `$CICD_ENV` and `$CICD_OUTPUT` after the command ends, writes the result into the termination message (≤ 4 KiB: exit code, reason, digest of outputs) and into its own events in the Pod log (D-30), reports the result to core and waits for core's permission to exit (D-29), and exits with the command's code. The user's image is not modified and may be any Linux image. The shim uses the task token (SEC-010) only to talk to the collector and the scheduler. The build's output never goes to the Pod's own log: it holds only the shim's events.

**RUN-011 Services.** Service containers (`services` in `ci.job`) are started as a separate Pod of the job with a headless Service and a DNS name inside the run; a NetworkPolicy allows access only to Pods of the same run. A service Pod is created on first use and removed when the job ends; it is not part of the log of the steps but has its own log stream.

**RUN-012 Limits of the model without permanent agents.** Privileged containers and Docker-in-Docker are not supported. Images are built by the BuildKit plugin through a rootless buildkitd as a service Pod of the profile (whether a rootless builder can run in the restricted namespace of an organisation is measured in A.13 and open, Q-17). Tasks that need a long-lived container for the whole job (for example interactive debugging or heavy cache warm-up) use session mode, which is reserved for stage 3 (7.4) (open question Q-14).

**RUN-013 Start latency.** Target: from placing a step in the queue to the start of the user process, p95 ≤ 10 s with warm images. Measured on a shared, noisy test environment of two worker nodes (A.6): p50 0.9--1.7 s, p95 up to 7.0 s (creating a Pod is not the bottleneck at about 0.2 s; the time is spent in the kubelet, with a tail up to 7 s), which meets the target; a batch of 50 Pods takes 8.4--11.8 s, still above the target if starting several steps in a batch becomes an ordinary scenario; a cold shim image takes about 8 s. Measures 1--3 of section 7.4 (volume, persistent volumes, image preloading) do not shorten the kubelet time in that environment and are verified again on the target cluster. To reduce latency the shim image is preloaded onto nodes by a DaemonSet (which runs no jobs); repeated starts of Pods over one volume (RUN-014) and persistent volumes between runs (STO-008) remove repeated data preparation from a step.

**RUN-014 Repeated Pod starts over a persistent volume.** A step Pod is disposable and the run state lives on a persistent volume (STO-001), so a Pod can be created again and again: the next step, a step retry, a restart after a node loss or a controller failure, a repeated start of the same image for diagnostics. A Pod keeps no state between starts: everything it needs is taken from the volume (`/cicd/workspace`) and the env files (STO-003). The controller must: (a) create the Pod of any step over an existing volume without repeated preparation; (b) preserve the contents of the volume on retry unless policy requires cleaning (`clean`); (c) with `ReadWriteOnce`, create the Pod on the node where the volume is already attached or wait for it to be released (STO-001); (d) never allow more than one active Pod per step (RUN-002). The idempotence of the steps themselves is the responsibility of the pipeline author.

**RUN-015 Launch admission by the state of the log circuit.** The core always knows the state of the log circuit (DAT-010) and adapts execution to it. Starting step and service Pods is allowed only while the launch gate is open: at least one VictoriaLogs node is `up`, vlagent accepts writes and the vlagent delivery queue for that node does not exceed `gate_max_pending` (256 MiB by default). When the condition is violated the gate closes: (a) the scheduler does not assign steps to controllers and controllers do not create new Pods, even for steps that are already assigned; such steps stay in the queue with the reason `logs_unavailable` (`steps.wait_reason`); (b) creating runs, parsing scripts, preflight, waiting on `ci.input` and cancellation are not blocked (cancellation deletes the Pod and does not need logs); (c) running steps are not interrupted by the platform: their log accumulates in the shim's spool and when it fills the build is slowed by back-pressure (RUN-007); (d) the UI shows the banner "starting jobs is paused: the log circuit is unavailable", the API returns the reason, and metrics and alerts record the closing time (section 15). The gate closes no later than 10 s after the loss of the last available node or the refusal of vlagent writes; it also closes at once when the log proxy fails to hand a block to vlagent, and opens when the polled condition has held continuously for `gate_stabilize` (10 s by default); the queue then resumes automatically with priorities and quotas respected. After a scheduler restart the gate stays closed until the first state is received (fail-closed). `ci.finally` cleanup steps are subject to the same rule; an emergency bypass of the prohibition is an open question (Q-16).

**RUN-016 Component liveness.** The core always knows the state of every other component. Every poll of the job controller, every executor lease and every shim heartbeat (every 5 s and at every state change) is a sign of life carried with a status; core also probes rqlite and the log circuit itself. A component silent beyond its limit (controller 15 s, executor 30 s, shim 30 s) is shown as `down` in `/api/v1/components` and `/metrics`. Silence alone does not finish a step before `liveness_timeout` (RUN-017).

**RUN-017 Timeouts, results and loss.** (a) The `timeout` of a step is enforced by the shim: on expiry the build's process group receives SIGTERM and, after a grace period (20 s), SIGKILL; the reason is `timeout` and the exit code 124; this is the step's own failure and it is not retried. (b) The shim reports the result of the step to core and waits for core's permission to exit; the Pod's status and termination message are only the fallback when core cannot be reached. (c) One `liveness_timeout` (300 s by default, counted from the later of the last sign of life and the start of the core) covers a Pod that did not start (reason `start_timeout`) and a shim that went silent (reason `outcome_unknown`); core then finishes the step, and the job controller removes the Pod after pulling an undelivered log out of it. (d) An out-of-memory kill is the step's own failure (reason `oom_killed`).

**RUN-018 Retry rule.** A step is repeated automatically only when it is known that its command never started, at most `infra_retries` times (3 by default), with a growing pause (5 s times the attempt, at most 60 s). A step whose command started and whose outcome is unknown (the node was lost, the Pod vanished, the Pod was deleted during the step) is not restarted: the run ends as `infrastructure_error` and the reason `outcome_unknown` is visible in the API. When only the log was not delivered, the command's exit code is the result and the step is not repeated. "Never started" is decided by evidence of the start: the container was seen running, or the shim reached core; everything unknown counts as started.

## 6.5 Logs, tests, artifacts and cache

**DAT-001 Logs: the source of truth is VictoriaLogs.** The shim turns the step's output into jsonline records (fields `_msg`, `_time`, `ln`, `ts`, `job`, `run`), masks secrets (DAT-002), numbers the lines with `ln` within the job attempt, and compresses them in independent gzip blocks (about 64 KiB of text each, gzip level 1, one CRC32C per block over the compressed bytes). The blocks are queued in the spool on the Pod (RUN-007) and sent to the shard's log collector in order. The collector checks the checksum, forwards the blocks without decompressing or recompressing them to vlagent (`/insert/jsonline`, with the matching `Content-Encoding`; vlagent accepts independently compressed blocks glued into one body; the stream is `_stream_fields=job`; the organisation and the top-level group are passed in the `AccountID`/`ProjectID` headers) and acknowledges to the shim the sequence number of the last block vlagent accepted. A block that vlagent refuses for good (a 4xx other than 408/429) is reported as rejected and dropped by the shim; a refusal that is worth retrying (408, 429, 5xx, no answer) is reported as `logs_unavailable` and the shim retries. The collector takes each block once: a block that was already forwarded and is sent again after a lost acknowledgement is acknowledged but not stored twice. vlagent delivers the data to both VictoriaLogs nodes (DAT-008) and keeps a queue on disk for each node separately. The window key is the service time `_time` = the base time of the job plus `ln` milliseconds (monotonic and unique within the job, A.7); the real time of the line is stored in the field `ts` and shown to the user; the field `ln` is stored for anchors and sorting by `(_time, ln)`. Every attempt of a step has its own stream (the `job` label contains the attempt number), so the log of a lost attempt is never mixed into its retry. The collector has no read path of its own: all viewing goes through the gateway (DAT-011). VictoriaLogs does not deduplicate records, so every line is sent once and the window excludes duplicates by `ln`. The unavailability of vlagent leads to back-pressure on the shim (RUN-007). There is no copy of the log in S3 as a source of truth: the browser, the API and the download read only VictoriaLogs. ANSI is allowed after sanitisation. Lines longer than the limit (32 KiB) are split between characters, never inside one, with a continuation mark. Invalid UTF-8 is replaced byte by byte with U+FFFD so that every record is valid JSON.

**DAT-002 Redaction.** Secrets are masked in the shim, before anything leaves the Pod: the log collector, the spool, the Pod's own log and VictoriaLogs never hold a plain value (D-31, docs/secrets-masking.md). A value is masked as is, as base64 (at each of the three alignments it can take inside a longer base64 string, in the standard and the URL-safe alphabet), URL-encoded (both cases of hex, and a space as `%20` and `+`) and JSON-escaped. A build may register more values at run time by appending them to the file `$CICD_MASK`; they protect the lines that follow. Values shorter than a configurable minimum (4 characters by default) are not masked because they would mangle ordinary output. Limits: a value split by a line break is masked line by line, other encodings (hex, compressed) are not recognised, and at most 256 masks apply to a step. Direct writes of steps and plugins to VictoriaLogs are forbidden: the network policy (SEC-003) opens vlagent only to the log collector, the management interface of the nodes (snapshots, deletion) only to the log-circuit module, and reads only to the read gateway.

**DAT-003 Artifacts.** The shim and plugins upload artifacts straight to S3-compatible storage by short-lived URL (multipart); SHA-256, size, media type, expiry, provenance and ACL are kept in rqlite. S3 is the store of artifacts and cache, not of logs.

**DAT-004 Cache.** The cache key is immutable; restore-keys select the latest compatible object; protection against poisoning separates trusted and untrusted refs and projects. Restore and save are performed by a plugin step into the shared storage (STO-001) through S3. The cache does not replace storage: the cache lives between runs, storage lives within a run. Persistent volumes (STO-008) are for reusing directories between runs without an exchange through S3.

**DAT-005 Tests.** A normalised suite/case/attempt model; duration history, flaky detection, owner, failure fingerprint and comparison with the base branch.

**DAT-006 Retention.** Separate policies for logs, artifacts, caches, audit, journal and provenance; a legal hold forbids GC of chosen runs. Log retention is set by the common period of the VictoriaLogs nodes (`-retentionPeriod`, daily partitions are dropped whole) and by a space limit (`-retention.maxDiskSpaceUsageBytes`); separate periods for a tenant or a type of data are enforced by deletion by filter (`/delete/run_task`, about 8 s per 1 M lines) on a schedule of the log-circuit module. Deleting a tenant is deletion by its `AccountID`.

**DAT-007 Viewing logs as a window.** A user never loads a whole log: the viewer always works with a window of lines (200 lines by default, at most 500 and at most 256 KiB per window) that the server requests from VictoriaLogs by a range of the line time inside the job's stream (DAT-008, DAT-011); a lag of the displayed log behind the step's output of a couple of seconds is acceptable. The viewer is served as an iframe from a separate origin (`logs.<base-domain>`) with the attribute `sandbox="allow-scripts"` without `allow-same-origin`, and the CSP `frame-ancestors` limited to the UI origin. Access is given by a token (IAM-004) valid for at most 60 s and bound to a job or run. The window is rendered on the server as ready HTML (one line, one element with the anchor `L<ln>`); the client code (≤ 20 KiB) only loads the neighbouring window on scroll and keeps at most three windows in the DOM, dropping the distant ones, so the JS heap of the viewer does not exceed 5 MiB for a log of any size (UI-008). Jumping to a line number, to a time and to a found search match, live tail (SSE, new lines are appended to the end of the last window and old windows are dropped), ANSI after sanitisation and deep links to a line or range (`#L1234`, `#L100-L140`; opening by link loads the window around the line) are supported. Size and position are reported to the parent through `postMessage` with an origin check. Without JS the same information is available on the page `/jobs/{id}/log?from=N` with links "previous window" and "next window".

**DAT-008 VictoriaLogs and its requirements.** `LogStore` is an internal interface with the operations `append`, `window`, `tail`, `search`, `export`, `delete` (by filter and tenant) and `snapshot`; the only product implementation is VictoriaLogs (Go, a single binary, Apache-2.0, upstream); the interface exists for substitution in tests and for a possible change of product. A shard's log circuit consists of two independent single VictoriaLogs nodes on persistent volumes (a StatefulSet, one Pod each), a vlagent agent with a disk buffer and a separate queue per node (`-remoteWrite.url` twice, `-remoteWrite.maxDiskUsagePerURL`) and a read gateway. The facts about the product come from its documentation and the flags of the v1.52.0 binary and are confirmed by measurements (A.7). Properties the platform relies on: (a) the store does not replicate data between nodes, fault tolerance comes from delivery to both nodes; while a node is unavailable vlagent accumulates its queue and delivers it when the node returns (measured: 2 M lines in 7--19 s, without losses or duplicates); (b) multi-tenancy through the `AccountID` and `ProjectID` headers; (c) node flags: `-storageDataPath`, `-retentionPeriod`, `-retention.maxDiskSpaceUsageBytes`, `-delete.enable`, `-memory.allowedBytes` or `-memory.allowedPercent`, `-tls`, `-httpAuth.*`; (d) partition snapshots `POST /internal/partition/snapshot/create|list|delete` (created in tens of milliseconds, restored by copying the partition directory); (e) search by fields and text without index configuration; (f) the store does not drop duplicates. Client certificates (mTLS) exist in VictoriaLogs only in the enterprise edition, so inside a shard the channel is protected by TLS with server verification and a login and password. Requirements on the store: no JWT inside the store (user access is checked by the gateway, which is also the only reader); retention is a node period, dropped partitions and deletion by filter (DAT-006); live tail uses `/select/logsql/tail` with `offset=0s` (p50 latency 1.5 s) or polling by query; limits are the `limit` and `timeout` of a query, `-memory.allowedBytes` and the Pod memory limit; the network circuit is closed (only the gateway is published outside); the window query selects N lines of the job's stream by a `_time` range in ascending order (6.8 ms p50 on 100 M lines regardless of offset); export is a streamed response of queries by time blocks with constant gateway memory. Targets (confirmed on 100 M lines, A.7): window p95 ≤ 100 ms (obtained 9.7 ms), disk amplification ≤ 3× (0.39×), ingest ≥ 5 MiB/s per job (about 100 MiB/s in total), restart of a node holding 100 M lines (first query after 0.5 s).

**DAT-009 Download.** The "download" button is the only scenario that reads a whole log. The gateway serves it as a stream (`Content-Disposition`, optional gzip), in blocks by time from VictoriaLogs (DAT-008) through a buffer of at most 4 MiB and without holding the log in memory; the stream honours redaction and the download quota. For finished runs the link is signed for a short time.

**DAT-010 Log durability and the log-circuit module.** The source of truth is the shard's two independent VictoriaLogs nodes on persistent volumes (DAT-008); a single node is not supported. The log-circuit module is part of the shard's core process, in which the scheduler and the log collector also run (D-23): (a) it polls the nodes (`/health`, `poll_interval`, 2 s by default) and the vlagent metrics (the queue size per node) and counts a node `down` after `fail_threshold` (3 by default) failed polls in a row, and a node with a non-empty queue `catching_up`; (b) it reports the state of the nodes to the gateway (ClusterState): reads go to an `up` node with the smallest queue and on error the query is repeated on the other node; (c) it performs snapshots, their upload and verification, automatic node recovery and deletion by retention (BKP-001--BKP-006); (d) it hands the scheduler, inside the process, the readiness of the circuit for the gate of RUN-015. There is no master election, no promotion and no storage failover. State (nodes, backups, policies) and leadership are kept in the shard's rqlite: the tables `log_nodes`, `backups`, `backup_policies` and the lease `shard-core` with a fencing token (shared with the scheduler); a write happens only on changes, poll results are not written to rqlite. One core instance is active; a second (standby) is a recommendation. The default topology (open question Q-13) is two VictoriaLogs nodes and vlagent; in a small installation they may run in one cluster without separate Kubernetes nodes but on different persistent volumes. The vlagent queue lies on its own volume and is the only place that holds lines not yet delivered; its size is bounded (`maxDiskUsagePerURL`) and on overflow the launch gate closes earlier (RUN-015, `gate_max_pending`). The log RPO target is about zero on the loss of one node (measured: the vlagent queue catches up 2 M lines in 7--19 s without losses or duplicates after the node returns) and at most the backup interval (1 h by default) on the loss of both nodes (measured: a snapshot in S3 through a companion container, the node destroyed, recovery into a new Pod from S3 gives exactly the data at the moment of the snapshot, A.11). The log circuit is part of the shard core (SHD-005). A copy of finished logs in S3 as a gzip archive (`logs.archive`, off by default) is allowed only for long retention and compliance and is not read by the UI.

**DAT-011 Reading logs.** All log reads (window, search, live tail, export) go to one VictoriaLogs node chosen by the gateway from ClusterState (DAT-010): an `up` node with an empty or smallest vlagent queue; on error or timeout the request is repeated on the other node (verified: with one node stopped, not a single request was lost). A lag of the displayed log behind the step's output of a couple of seconds is acceptable, so there are no separate freshness mechanisms and no reads from the collector's memory. The gateway caches the choice for a few seconds; when no node is available it returns a temporary error with `Retry-After` and the viewer repeats the request automatically. The read load falls on one node, so queries are limited in size and time (DAT-008), and an excess over NFR-005 is handled by decision D-20. A ready vmauth proxy with the `first_available` policy is acceptable instead of node-choice code in the gateway (verified).

## 6.6 Environments and deployment

**DEP-001 Environment.** An environment has a tier, a URL, protection rules, concurrency, credentials binding, deployment history and an optional Kubernetes target.

**DEP-002 Checks.** Before a job the following run: approvals, a change window, a branch/tag rule, an external policy webhook and an exclusive lock.

**DEP-003 Deployment record.** The record contains the artifact digest, the source SHA, the environment, the actor, the pipeline, timestamps, the status and a rollback reference.

**DEP-004 Promotion.** One immutable artifact is promoted between environments; rebuilding on promotion is forbidden by default.

**DEP-005 Rollback.** A rollback is a new audited deployment of an existing digest/config snapshot, not a rewrite of history.

## 6.7 Host API of pipeline scripts (Lua API v1)

Names, semantics and journaling rules are normative; the signatures are fixed in `lua/stdlib/cicd.d.lua` and do not change within API version v1. The module is imported as `local ci = require("cicd")`.

| **Function** | **Where called** | **Journal** | **Purpose** |
|:---|:---|:---|:---|
| `ci.pipeline{...}` | Top level of the script | No | Metadata and `main`; returned from the script |
| `ci.string`, `ci.number`, `ci.bool`, `ci.choice`, `ci.list`, `ci.map`, `ci.secret` | Metadata phase | No | Typed parameters (PIP-012) |
| `ci.stage(name, fn)` | `main` | Yes | A group for the UI, metrics and restart |
| `ci.job(opts, fn)` | `main` | Yes | A job: `image`, `profile`, `resources`, `timeout`, `retry`, `services`, `permissions`, `env`, `secrets`, `metrics`, `mask`, `workspace` (`shared` by default or `isolated`); `fn` receives `j` |
| `j.checkout(opts)` | Inside `job` | Yes | Step: fetch the sources through an SCM plugin into `/cicd/workspace/src` |
| `j.sh(cmd, opts)` | Inside `job` | Yes | Step: a shell command in a Pod with the job's image (or `opts.image`); options `timeout`, `metrics`, `mask`, `capture`, `ignore_failure`; result: `code`, `outputs`, optionally stdout |
| `j.use(ref, inputs)` | Inside `job` | Yes | A plugin step by a pinned reference; inputs are validated against the plugin's JSON Schema; result: `code`, `outputs` |
| `j.env(tbl)` | Inside `job` | Yes | Environment variables for the following steps of the job (without starting a Pod); the `env` level of VAR-004 |
| `j.artifact`, `j.cache` | Inside `job` | Yes | Upload, download, save/restore |
| `ci.parallel(tbl, opts)` | `main` | Yes | Parallel branches, `fail_fast` |
| `ci.spawn(fn)`, `h:wait()`, `h:cancel()` | `main` | Yes | Asynchronous branches; the DAG is given by the order of spawn/wait |
| `ci.matrix{...}` | `main` | No | Combinations of axes with include/exclude and a limit |
| `ci.input{...}` | `main` | Yes | A manual decision that holds no cluster resources (PIP-013) |
| `ci.deploy(env, fn)` | `main` | Yes | A job in a protected environment with the DEP-002 checks |
| `ci.run(ref, params, opts)` | `main` | Yes | A child run (PIP-010) |
| `ci.sleep(seconds)`, `ci.now()`, `ci.random()` | `main` | Yes | A timer without a Pod, the time, a random number |
| `ci.finally(fn)` | `main` | Yes | Cleanup on cancellation and error |
| `ci.log(level, msg)`, `ci.fail(msg)` | Everywhere | Yes | A message to the run log; an explicit failure |

Secret values never enter the Lua state: the script works with opaque handles (`ci.secret`, `ci.vault(path)`). Immediately before a step the job controller creates an ephemeral Kubernetes Secret with the permitted values, mounts it in the step Pod and deletes it with the Pod; the values are masked by the shim (DAT-002).

## 6.8 Storage and data exchange between steps

**STO-001 Run storage.** One volume (PersistentVolumeClaim) is created for a run; the job controller creates it at the first step, mounts it in the Pod of every step (`workspace/` at `/cicd/workspace`, `state/` at `/cicd/state`, STO-002) and deletes it on completion (STO-006). The size is given by `ci.pipeline{storage={size=...}}` within the project quota, the StorageClass by the execution profile. `ReadWriteMany` is preferred (parallel jobs on different nodes); with `ReadWriteOnce` the controller pins all Pods of the run to one node through pod affinity, which limits parallelism to the resources of that node (open question Q-11). A step Pod is disposable while the volume is persistent for the run, so a Pod can be created again and again (RUN-014). Storage is available only to Pods of the same run; between runs the volume is not reused by default (the exception is persistent volumes, STO-008).

**STO-002 Layout.** `/cicd/workspace` is the common directory of all steps; `j.checkout()` places the sources in `/cicd/workspace/src`; the variable `CICD_WORKSPACE` points to the root. For a job with `workspace="isolated"` the controller mounts the subdirectory `.jobs/<job-id>` of the volume (`subPath`) as `/cicd/workspace` so that parallel branches do not disturb each other. `/cicd/state` is the `state/` subdirectory of the same volume, mounted separately and not part of the workspace; it holds the env file `env` (STO-003). It lies outside the workspace so that the checkout, `git clean`, uploads of artifacts and caches, the reuse of persistent volumes (STO-008) and tools that read `.env` files never touch it, and it is shared by all jobs of the run even when the workspace is isolated. Outside the volume the following are available: `/cicd/tmp` (an `emptyDir` per step) and `/cicd/run` (service files of the shim: `CICD_OUTPUT`, `CICD_MASK` and the directory `plugin/` of the plugin file contract, PLG-008).

**STO-003 Passing data between steps.** Two files in a dotenv-subset format are available to every step. `$CICD_ENV` (the file `/cicd/state/env`) carries variables from a step to all following steps of the run: the step writes it, and the shim loads it into the environment of every following step (precedence in VAR-004). It is stored neither in rqlite nor in the journal. `$CICD_OUTPUT` returns values to the script as `r.outputs` (journaled, reproducible on replay); it is for values the script itself needs, not for passing data between steps. Nothing captures the environment of a step automatically: a variable that a step exports reaches the following steps only when the step writes it to `$CICD_ENV`. In a shell one line does both:

```sh
export A=1 && echo "A=$A" >> "$CICD_ENV"
```

and `export A=1 && echo "A=$A" | tee -a "$CICD_ENV" >> "$CICD_OUTPUT"` also returns it to the script; in other languages `$CICD_ENV` is opened in append mode (Python: `open(os.environ["CICD_ENV"], "a").write("A=1\n")`). Format: lines `NAME=VALUE`; a quoted value allows escape sequences; a multi-line value is `NAME<<DELIM` ... `DELIM`. The shim parses the files with a parser (not `source` by a shell). Limits: the name matches `[A-Z_][A-Z0-9_]*`; `$CICD_ENV` has values of at most 8 KiB, at most 256 keys and 64 KiB; `$CICD_OUTPUT` is at most 4 KiB per step in total (names and values) and 32 keys. Parallel branches write the same file, and resolving conflicts (the last write wins, nothing is merged) is the responsibility of the pipeline author. Between jobs, data passes through the env file, through Lua code (the `outputs` values in the options of the next `ci.job`) or through files in the workspace.

**STO-004 Exchange security.** A deny-list of names (SEC-011): `LD_*`, `PATH`, `IFS`, `BASH_ENV`, `ENV`, `SHELL`, `HOME`, `CICD_*`, `NODE_OPTIONS`, `PYTHONPATH` and the like; a value containing a known secret is rejected with the error `secret_in_output`. Outputs, the env file and variables of kind plain are not meant for secrets; `outputs` are stored in rqlite (4 KiB per step), the env file only on the volume; secrets are passed only as handles (6.7) or as variables of kind secret (VAR-001).

**STO-005 Storage and artifacts.** Storage lives until the end of the run and is not long-term storage. Results needed after the run are saved as artifacts (DAT-003); dependencies between runs are the cache (DAT-004).

**STO-006 Lifecycle.** The volume is deleted `storage_retention` after the run ends (0 by default for succeeded, 24 h for failed and timed_out for diagnostics). For restart from a stage (PIP-015), volume snapshots at stage boundaries are allowed (VolumeSnapshot, a profile option, off by default) (open question Q-11). Orphaned volumes are removed by reconciliation on labels (RUN-005). Encryption at rest is provided by the StorageClass.

**STO-007 Errors and quotas.** When the volume is exhausted a step gets a write error and the run gets the code `storage_exhausted`; the size and number of volumes are limited by the project quota (RUN-003); usage is shown in the UI and in metrics.

**STO-008 Persistent volumes between runs** (stage M2). A pipeline may request a named volume that is kept after the run and reused by the following ones: `ci.pipeline{storage={persist={name="build", scope="branch"}}}`. The goal is to remove repeated checkout, dependency download and from-scratch builds from a start (`j.checkout()` does a fetch instead of a clone). Rules: (a) the volume is given to one run exclusively by lease; the others wait or get a clean volume by policy; (b) the key of a volume is the project, the name, the `scope` (`project`, `branch` or `pipeline`) and the trust level of the ref; a volume is never shared between trusted and untrusted refs (by analogy with DAT-004) and forks get only clean volumes; (c) the content is considered untrusted: policy may require cleaning (`clean`) before the start; (d) the size and number of volumes are limited by quota, eviction by LRU and TTL (14 days without use by default); (e) the volume is bound to the execution profile and its StorageClass. Implemented on top of PVCs, snapshots are not required (open question Q-11).

## 6.9 Shard backup

**BKP-001 Planning in the scheduler.** Backup is a system task of the shard core process: the schedule is managed by the scheduler, execution by the log-circuit module of the same process. Backups are not pipeline runs, do not create step Pods and are not subject to the launch gate RUN-015. Targets: `state` (the shard's rqlite), `logs` (VictoriaLogs) and, when the audit store is VictoriaLogs, `audit` (AUD-006). The policy of each target: `enabled`, `interval` (for `state` 5 minutes by default, which follows from the RPO in NFR-007; for `logs` 1 h), `retention` (the last 3 good backups plus the newest verified one), `verify_interval` (24 h by default). At most one backup per target runs at a time; ownership is ensured by the lease `shard-core`.

**BKP-002 One UI section and API.** The "Backups" section (role Platform admin) is common to `state` and `logs`: the policy (schedule, retention, verification), a manual "back up now" action, history and statuses (`running`, `uploaded`, `verified`, `bad`, `failed`), size, the size and number of snapshots (for `logs`), time, the verification result, the state of the VictoriaLogs nodes and vlagent queues, the progress of automatic recovery and the log of losses during it. The same actions are available through REST (`GET` and `POST /api/v1/shards/{id}/backups`, `PUT /api/v1/shards/{id}/backup-policy`) and the CLI (`cicd admin backup`). Manual runs, policy changes and automatic decisions (node recovery, closing the gate) are written to the audit (SEC-005); a policy change requires confirmation.

**BKP-003 Log snapshot and upload.** A partition snapshot is taken on an `up` node with no delivery lag (the vlagent queue is empty) by `POST /internal/partition/snapshot/create`; it takes tens of milliseconds and stops neither the node, nor ingest, nor job launch. The snapshot is uploaded to S3 by a tool in the node's Pod (a companion container over the same volume, for example rclone) with a SHA-256 and a manifest (partitions, size, record count, time); the archive is kept only if the checksum matched, after which the snapshot on the node is deleted. If there is no suitable node the backup is postponed and retried, and when there is no successful backup for more than two intervals an alert is raised. A partition snapshot takes about 0.02 s (A.7), so the pause is far shorter than what closing the launch gate would take.

**BKP-004 Automatic recovery of a VictoriaLogs node.** Node recovery is always automatic. A node with a lost disk or damaged data is recovered by the log-circuit module as follows (verified): (1) it briefly pauses vlagent delivery (writes are held, the launch gate RUN-015 closes for a few seconds); (2) it creates a snapshot on the other `up` node; (3) it copies the snapshot into the volume of the node being recovered (143 MiB in 0.13 s; for 100 M lines about 3.5 GiB); (4) it clears the vlagent queue for that node so that lines that went both into the snapshot and into the queue are not doubled; (5) it starts the node and resumes delivery. If there is no second node, the node is recovered from the newest backup with status `verified` (a `bad` backup is never used) and delivery resumes from the vlagent queue; records between the backup and the start of the queue are lost, and the range of the loss is written to the audit and shown in the UI. If both nodes are lost, the first node is recovered from a backup and then the second is copied from it; the launch gate stays closed while there is no node (RUN-015). The copy runs as an init container or a Job over the volume.

**BKP-005 Backup and restore of rqlite.** Backup and restore of `state` use the built-in rqlite flags `-auto-backup`/`-auto-restore` with a JSON config (`type: s3`, interval, keys, `bucket`, `path`); no tool of our own and no `cicd admin restore-state` command are needed (A.11). Only the leader backs up and only when data has changed; measured: an upload takes 6--17 ms, the RPO on the test interval is exact (exactly the records after the last backup were lost, not one more), no effect on writes. Restore happens at node start, before it joins the cluster; the UI section lists the backups and their statuses. `-auto-restore` has been verified on a single node; the behaviour on a multi-node cluster (according to the rqlite documentation only the node that becomes leader actually applies the data, the others receive it through Raft) is still to be verified, as is a repeatable restore drill.

**BKP-006 Verification and alerts.** Once per `verify_interval` the newest backup is verified: for `logs` and `audit`, the snapshot is restored into a temporary VictoriaLogs instance and the record count and a control sample are compared with the manifest; for `state`, it is restored into a temporary rqlite instance and its integrity is checked. Alerts: no successful backup for more than two intervals, no verified backup for more than two verification periods, no node for a lag-free snapshot, recovery in progress, records lost during recovery (section 15).

## 6.10 Variables and parameters

Variables are set in the UI or the API, not in the pipeline script, at four levels: organization, group (PRJ-001), project and pipeline (the build). A launch parameter (`params`, PIP-012) is given for one run.

**VAR-001 Levels and kinds.** A variable has a name, a kind and a value. Kinds: plain (an ordinary string, number, boolean or choice) and secret (the value is kept in the credential store and is never shown again, 6.7). Variables are inherited down the hierarchy and an override at a lower level is shown explicitly (PRJ-001).

**VAR-002 Delivery to steps.** Every plain variable and every launch parameter is available to every step as an ordinary environment variable (`$URL` in a shell, `os.environ["URL"]` in Python); no special syntax is needed. The job controller puts them into the `env` of the step's container when it creates the Pod, using the **current** values at that moment; secret variables go through the step's ephemeral Secret (6.7) at their current version. There is no snapshot of the variables for the whole run: a change takes effect for the steps that start after it, running steps are not affected, and a retry of a step after a variable was corrected gets the corrected value. Launch parameters are the exception: they are fixed when the run is created and stored with it (`runs.params`, at most 4 KiB). The script does not see the live variables: `run.params` and `run.env` hold only the launch parameters and the `env` declared in the pipeline itself, so that replay stays deterministic (PIP-004). The variables and the environment of a step are stored neither in rqlite nor on the volume.

**VAR-003 Validation.** The UI and the API validate variables when they are saved and launch parameters when a run is created: the name matches `[A-Z_][A-Z0-9_]*` and is not in the deny-list of STO-004; the type, the required flag, the allowed choices, the pattern and the length (a value of at most 8 KiB) match the declaration; and the total of the variables stays within the limits of a step's environment. An error is reported before the run starts, not in the middle of the pipeline.

**VAR-004 Precedence.** From the lowest to the highest: variables of the organization, the group, the project and the pipeline; launch parameters; the `env` of the pipeline and of the job; values written to `$CICD_ENV`; the `env` of the step. A step that writes `$CICD_ENV` thus deliberately overrides a variable from the UI.

**VAR-005 Values in the log.** The header of the first step of a run prints in its log the effective values of the launch parameters and variables and a short digest (the first 12 hex digits of SHA-256 over the sorted `NAME=value` list). Secret variables are not printed (only their names are listed, with `***`) and do not enter the digest. The header goes through the ordinary log pipeline (DAT-001, masking included), so it is stored in VictoriaLogs and answers the question which values a run used.

**VAR-006 Audit.** Changes of variables and parameters are not audited by default, plain and secret alike. The setting `audit.variables` of the organization turns the audit on in one of two modes: `full` (for a plain variable the old and the new value are written in full to the audit) or `digest` (for a plain value longer than 256 characters only its digest is written, and the value itself is found in the log header of a step that used it, VAR-005). For a secret variable either mode records the fact of the change (who, when, the new version of the credential) and a digest of the value, never the value itself (SEC-005). The digest is an HMAC-SHA256 under a key of the tenant, not a plain hash, so that a short or guessable secret cannot be recovered from the audit; the first 12 hex digits are kept.

## 6.11 Audit storage

The audit log (SEC-005) is stored in one of two places, chosen per shard by the setting `audit_store`: `rqlite` (the default) or `victorialogs`. The format of an event, the hash chain and the API (`/api/v1/audit-events`) are the same in both.

**AUD-001 Stores.** `rqlite`: the table `audit_events` (8.2) in the shard's rqlite, rotated by month and exported to WORM/SIEM; it needs nothing beyond the shard's own components and suits small installations. `victorialogs`: events are JSON lines in a separate **audit circuit**, a pair of independent VictoriaLogs nodes fed by a vlagent of their own, built like the log circuit (DAT-008, DAT-010) and operated by the same log-circuit module; nothing is kept in rqlite except the anchors (AUD-003). This mode takes the growth of the audit out of rqlite and suits large installations and long retention.

**AUD-002 Record.** A record carries `_time` (the time of the event, to the millisecond), `seq` (a number growing by one within the chain), `tenant` (also the `AccountID` header; platform-level events use tenant 0), `actor`, `action`, `resource`, `before`, `after`, `ip`, `prev_hash` and `hash`, with `_stream_fields=kind` and `kind=audit`. `hash` is SHA-256 over `prev_hash`, `seq` and the canonical JSON of the other fields (as for the run journal, SEC-008). Secret values never enter a record (SEC-005); for variables the record holds the value, its digest or nothing, as VAR-006 sets, and for a secret variable only the keyed digest.

**AUD-003 One writer and anchors.** One chain per shard is written by the shard core under the lease `shard-core` (D-23), which assigns `seq` and `hash`. About every 1 000 events or 10 s the core writes an anchor to rqlite (`audit_anchors`: chain, `from_seq`, `to_seq`, `head_hash`, time) and, if object-lock storage is configured, a copy of it there (WORM). A new owner of the lease continues the chain from the newest anchor plus the tail read from the audit nodes; if the tail cannot be read it writes nothing (AUD-005).

**AUD-004 Integrity and verification.** The audit nodes run with the delete API off (without `-delete.enable`) and with credentials of their own: the core may only write and the gateway only read; retention is the nodes' `-retentionPeriod` (`audit.retention`, 400 days by default). A record may arrive twice (VictoriaLogs does not deduplicate, A.7), so a reader drops duplicates by `seq`. Every `verify_interval` the log-circuit module recomputes the chain between anchors from the nodes and compares the heads with the anchors; a gap in `seq` or a different hash raises the alert `audit_chain_broken` and is shown in the Audit screen (`GET /api/v1/audit-chain`).

**AUD-005 When the audit store is unavailable.** A write is acknowledged only after vlagent accepted the record. While the audit circuit is unavailable the setting `audit.on_unavailable` decides: `deny` (the default) refuses the operations that are audited (changes of configuration and permissions, approvals, deployments, backup and restore actions, and changes of variables and credentials when `audit.variables` is on) with the code `audit_unavailable`, while running steps, reads and the creation of runs go on; `buffer` accepts them and keeps the records in the vlagent queue and in a bounded disk queue of the core, at the risk of losing them if that queue is lost.

**AUD-006 Reading, export and switching.** The Audit screen and the API search records by actor, action, resource and time (LogsQL on the node chosen as in DAT-011); pagination is by `(time, seq)`; export is a streamed response, and live forwarding to a SIEM follows `/select/logsql/tail`. When `audit_store` is changed, new events go to the new store, the first of them is a link record that carries the head hash of the old chain, and reads cover both stores until the old one is past its retention. The audit circuit is backed up like the logs, as the target `audit` (BKP-001): snapshots, upload, verification and automatic node recovery (BKP-003, BKP-004, BKP-006). A restored node continues from its own data; events lost between the backup and the loss show as a gap in `seq` and are reported (AUD-004).

# 7 Architecture

The platform is a set of microservices, each of which is a separate process with its own Deployment or StatefulSet and independent scaling; shared code lives in `src/common`. Merging services into one process is not foreseen (except the shard core, D-23). A single-node installation (one replica of each service, one shard) is a Helm configuration, not a different architecture. Operation outside Kubernetes is not supported. All components belong to a shard (7.3) except the OCI plugin registry, which the shards share; there is no global directory or database.

| **Component** | **Level** | **Responsibility** | **State/protocol** |
|:---|:---|:---|:---|
| Web UI and API service | Shard | Server-side HTML rendering, forms, fragments (HTMX), SSE, permanent URLs, extension points, REST v1, auth; reached through the ingress by the organisation's path prefix (SHD-001) | Stateless; HTTPS; no direct access to a shard's database |
| Router (`multi` mode) | Cluster | A registry of organisations kept in memory (cores register with POST and read with GET under a shared key) and a page with the list and the availability of every core; proxies nothing (SHD-006) | Lists with a time to live in memory; HTTP |
| Plugin registry | Platform | Manifest, signature, OCI digest, compatibility, trust | An OCI registry shared by the shards; every shard keeps the catalogue (`plugin_catalog`) refreshed from it |
| Shard core (one process) | Shard | Modules: the scheduler (step queue, quotas, priorities, leases of executors and job controllers, launch admission by RUN-015, backup schedule, watchdog of `liveness_timeout`); the log collector (receives log blocks from the shim, forwards them to vlagent); the log-circuit module (polls the VictoriaLogs nodes and the vlagent queues, snapshots and their upload, automatic node recovery, retention by deletion, BKP-001--BKP-006); the component registry, `/api/v1/components` and `/metrics` | The shard's rqlite is authoritative; Protobuf channels over ZeroMQ with CURVE; vlagent; the VictoriaLogs node API; lease timers in memory |
| Pipeline executor | Shard | Lua sandbox, run journal, replay, limits | Separate processes, seccomp, no network; the only channel is Protobuf to the scheduler over ZeroMQ with CURVE (ExecutorChannel, 9.2) |
| Job controller | Shard, one per organisation namespace | Creates and watches Pods, storage, ephemeral Secrets, cleanup, GC; keeps its own sqlite state; pulls an undelivered spool out of a Pod before removing it | An outbound Protobuf channel over ZeroMQ (CURVE) to the scheduler; the Kubernetes API; Lease |
| Log gateway | Shard | Window reads, search, live tail, streamed download from the chosen VictoriaLogs node; issuing and checking iframe tokens | VictoriaLogs (two nodes); node state from the shard core (ClusterState); IAM-004 tokens |
| Log store (VictoriaLogs) | Shard | Two independent VictoriaLogs nodes: storage and search of logs; a user reads one node (without lag), the other is the reserve and the source of snapshots | Each node receives data from vlagent; `/health`, metrics |
| vlagent | Shard | Receives records from the log collector, keeps a disk buffer and a separate delivery queue for each VictoriaLogs node, retries while a node is unavailable | The queue size metric per node; `-remoteWrite.maxDiskUsagePerURL` |
| Audit circuit (optional) | Shard | With `audit_store = victorialogs`: a separate pair of VictoriaLogs nodes without the delete API and a vlagent of their own; keeps the audit events (AUD-001) | Written only by the shard core, read by the gateway; snapshots as the target `audit` |
| Event service | Shard | Webhooks, validation, deduplication, routing, schedules | rqlite outbox |
| Policy service | Shard | Admission rules for pipelines, plugins and deployments | Lua policies in the sandbox; versioned bundles; OPA as an optional adapter |
| Worker | Shard | GC, notifications, reports, imports, retention | Idempotent handlers; rqlite outbox |
| Runner shim | Step Pod | The step wrapper: env file, running the command, masking, spooling and delivering logs, metrics, result (RUN-010) | A Protobuf channel over ZeroMQ (CURVE with the shared client key and a task token) to the collector and the scheduler; the Pod's own log carries its events |

The modules of the shard core work in one process (D-23), so the scheduler knows the state of the log circuit without network calls; in the text the modules are called by their own names (scheduler, log collector, log-circuit module). Log ingest and planning compete for the resources of one process, so every module has its own threads and memory limits, and if needed log ingest can be moved to a separate process without changing the contracts. The pipeline executor runs user code and must work in separate processes with restrictions (SEC-007) even in a single-node installation. Services talk Protobuf over ZeroMQ with CURVE (the table of internal channels is in section 9); the shim connects with the shared client key and a task token instead of a client certificate on every Pod (D-24); the services of a shard do not access the databases of other services.

## 7.1 Technology baseline

| **Area** | **Recommendation** | **Reason** |
|:---|:---|:---|
| Language | Nim 2.x, `--mm:orc`, `--threads:on`, musl; static linking for the shim and the CLI, the other services may link libraries (OpenSSL for TLS clients) into an image no larger than Alpine | Low memory, deterministic freeing, static binaries of the shim and the CLI |
| Transport | ZeroMQ (libzmq with libsodium), REQ/REP with CURVE; the server key is pinned by clients; Protobuf messages; a static build links libzmq and libsodium in (`tools/shim/build_static.sh`) | Lean, leak-free in the measured path (A.4, A.12), no second certificate hierarchy |
| HTTP | GuildenStern (pure Nim) with two vendored patches | A.5 |
| Kubernetes API | The official C client `kubernetes-client/c` (Apache-2.0), generic JSON API, a thin Nim binding, a shared connection cache; creation, status polling, Lease fencing and exec verified on Pods, PVCs, Secrets and Leases | There is no mature Nim client; a narrow set of resources simplifies the client and minimises the controller's rights (A.6) |
| Serialisation | Protobuf (proto3); the codec `nim-protobuf-serialization` is used in all code (`tests/unit/tpb.nim`, `tests/contract/tproto_v0.nim`, `tproto_compat.nim`: the vectors match protoc for Go and Python) | The schema as a contract for plugins in any language; chosen by test vectors shared with Go and Python |
| Scripts | Lua 5.4 (C), statically linked, own allocator, fixed hash seed | Small size, coroutines for suspension, a sandbox through an allow-list |
| State | rqlite per shard: 3 voting nodes, optionally non-voting nodes for reads; there is no global database | D-02; see 7.2 and 7.3 |
| Logs | Two independent VictoriaLogs nodes per shard, vlagent and delivery queues are the store and source of truth; snapshots, recovery and retention are performed by the log-circuit module of the shard core (DAT-001, DAT-008, DAT-010) | D-07, D-21; A.7 |
| Blob | S3-compatible (SigV4 presign is implemented in the project, it is HMAC-SHA256) | Artifacts, caches and backups outside the database, multipart and lifecycle; logs are not stored here |
| UI | HTML on the server, HTMX, SSE, small custom elements for dynamic components, charts as server-side SVG; templates escape output by default (`h()` is mandatory, checked by `tests/unit/ttemplates.nim`) | Not an SPA: permanent links, minimal client code and browser memory (UI-008) |
| API | External REST/JSON; Protobuf for the shim, plugins and internal services | Available to clients; efficient streams |
| Schemas | OpenAPI 3.1, JSON Schema 2020-12, Protobuf; a backward-compatibility check of `.proto` (buf breaking or equivalent) in CI | Client generation and strict compatibility |
| Packaging | One Helm release per shard (the chart `cinim-shard` with rqlite and the log circuit, two VictoriaLogs nodes and vlagent, as subcharts from their official charts, so that a shard is installed with one `helm install` and no helmfile) and the chart `cinim-router` of the cluster-wide router; both can create the scrape objects of the Prometheus or the VictoriaMetrics operator (`metrics.monitor`); OCI images: the shim and the CLI are static and need no base (scratch), every other service may carry the libraries it needs, but its image is no larger than Alpine (Alpine itself, or scratch/distroless with the libraries copied in; Debian, Ubuntu and the like are not used) | Managed installation; small images |

## 7.2 Reliability and consistency

- The shard's rqlite is the source of truth for the state machines of the shard's tenants. Every state transition is a CAS write (`UPDATE ... WHERE version=?`). Writes that determine state, the journal and the audit go only through strict rqlite writes; queued writes (asynchronous, with a small risk of loss when a node fails) are allowed only for data that can be restored (metrics, auxiliary timestamps).

- SQLite and rqlite have no `SELECT FOR UPDATE SKIP LOCKED` and no advisory locks. Placing a step for execution is done by one atomic write with a subquery (the example below); competition between scheduler instances is excluded by the profile's queue belonging to one active instance through a lease row with a fencing token; when the owner fails the queue is taken over after the TTL.

- The loss of a notification about available work does not lose a step: the scheduler periodically (`reconcile_interval`) reviews `queued` rows, and the job controller, after reconnecting, reconciles its Pods with the list of the shard's active steps.

- The outbox pattern is mandatory for events produced by a transaction. Consumers use an idempotency key and an inbox table or a natural unique constraint.

- A journal record is written by the same transaction as the state change that resumed the script: the executor accumulates the records of one execution interval and commits them as one batch.

- Webhook deduplication key: provider + delivery ID; when there is no ID, HMAC(normalised payload + time bucket).

- All long-running operations are represented by an operation resource and do not hold an HTTP connection, except SSE and the log download stream.

- rqlite read levels: `strong` or linearizable for queueing and state transitions; `weak`/`none` with a freshness parameter for UI lists.

- The state of the Pod in Kubernetes is the source of truth about the actual execution of a step; rqlite keeps the intention and the result. The shim's own report of the result and the Pod's status are reconciled by event number (D-30); disagreements are removed by the controller's reconciliation (RUN-002): a Pod with no record is removed, a record with no Pod becomes `lost` after the evidence rule of RUN-018.

```sql
UPDATE steps
   SET state = 'starting', controller_id = :controller, claimed_at = :now,
       version = version + 1
 WHERE id = (SELECT id FROM steps
              WHERE state = 'pending' AND profile_id = :profile AND not_before <= :now
              ORDER BY priority DESC, queued_at
              LIMIT 1)
   AND state = 'pending'
RETURNING run_id, ordinal, image, command, attempt, opts;
```

The atomicity of this statement through the Raft log, including `RETURNING`, has been verified (A.2).

## 7.3 Sharding and operating rqlite

Capacity grows by sharding. A shard (cell) is a self-contained set of services and stores: its own rqlite, the core (scheduler, log collector and log-circuit module in one process), executors, the event service, the log gateway, the log circuit (two VictoriaLogs nodes and vlagent) and the job controllers of its organisations (SHD-007). A shard lives in exactly one Kubernetes cluster: it never spans two clusters, and another cluster always means another shard. A shard has a name made of digits (`001` by default) and holds many organisations; an organisation (a tenant, with all its groups, projects, runs and logs) belongs entirely to one shard. Organisations are created in the UI of the shard (SHD-007). The shards need no coordination: the platform has no directory, and the path prefix of the organisation's URL tells the ingress which shard to send a request to.

**SHD-001 Routing by URL path.** A shard has a name made of digits (`001` by default; the second shard in a cluster must be given another one) and holds many organisations, which are created in the UI of the shard. The URL prefix `/<org>/` (the organisation's slug) selects the organisation and, through it, the shard: the ingress sends `/<org>/...` to the UI/API service of the shard that holds the organisation, and the same prefix is used on the separate origins of logs and plugin panels (`logs.<base-domain>/<org>/`, `x.<base-domain>/<org>/<plugin>/`). The mapping organisation → shard is the set of Ingress objects: the Helm release does not create them (it has no list of organisations), in `multi` mode the core of the shard creates the Ingress `<basePath>/<org>/` when an organisation is created and deletes it when the organisation is deleted (SHD-007), while in `single` mode the one Ingress of the release covers every organisation; there is no directory and no shared database. Uniqueness: the name of a shard is unique in a cluster because the release is installed into the namespace `<prefix>-<shard>` (`helm install ... -n <prefix>-<shard> --create-namespace`; the chart refuses any other namespace) and a second release of the same shard fails with a conflict of the cluster-scoped objects it owns (its ClusterRoles and its admission policy); a slug is unique in a shard through the database, in a cluster through the conflict of Ingress paths, and across clusters through the list of the router (SHD-006), which the core checks when an organisation is created. A slug is a DNS label (`[a-z0-9-]`, at most 63 characters minus the prefix, the shard name and two dashes, so that the namespace name `<prefix>-<shard>-<slug>` fits), may not consist of digits only (such names belong to shards) and may not be one of the reserved ones: `list`, `api`, `logs`, `x`. Sign-in happens once per shard under `<basePath>/<shard>/`: one redirect URI per shard is registered in the identity provider, the return address is checked to belong to the organisations of the shard, and the session cookie is named after the shard and scoped to `<basePath>/`, so it holds for all organisations of the shard; an organisation on another shard needs its own sign-in. Identities and memberships are kept by each shard. A request for an organisation that the shard does not hold gets Problem Details with the code `organization_not_found`. Moving an organisation is switching its Ingress (SHD-003). The name of a shard, the namespace prefix and the slug of an organisation cannot be changed after creation, because they are part of namespace names and URLs; an organisation can be moved to another shard (SHD-003). The router and the organisation list are described in SHD-006.

**SHD-002 Failure isolation.** A failure or degradation of a shard affects only its tenants. Between shards there are no distributed transactions, shared queues or shared data except S3 and the plugin registry; therefore a cross-shard `ci.run` is not supported in the MVP (PIP-010). The organisations of one shard share its core, rqlite and log circuit, so a heavy organisation can slow its neighbours; where the isolation must be hard, the organisation is moved to a shard of its own (SHD-003).

**SHD-003 Placement and growth.** A new organisation is created in the UI of the shard where it is to live; there is no automatic placement. The capacity of a shard is determined by the benchmark against NFR-006 with a 2× margin; at 70 % of capacity a new shard (a new release with a new name) is created and the next organisations are created there. Moving an existing organisation in the MVP is an offline operation of an administrative tool: stop intake, export the organisation's rows from rqlite, move its logs through export (DAT-008, selected by the `AccountID` header) and ingest them again in the target shard, then the core of the old shard deletes the Ingress and the core of the new one creates it; an online move is outside the MVP (open question Q-12).

**SHD-004 Shard orientation from the first slice.** Every table of a shard contains `tenant_id` (the organisation's id); all identifiers contain a shard prefix; configuration and metrics are labelled `shard`. The MVP deploys one shard, but the code must not assume there is only one.

**SHD-005 The log circuit is part of the shard core.** The shard core (scheduler, log collector, log-circuit module), vlagent, the log gateway and the VictoriaLogs nodes form the shard core. While no VictoriaLogs node is available or vlagent does not accept writes, starting new steps is forbidden and the queue waits (RUN-015); when the core is unavailable the shard is unavailable as a whole (there are no new logs, nobody to view them, the shard's interface is down). There is no mode of operation without logs and no requirement for independent availability of log intake and viewing; fault tolerance is provided by the two nodes, the vlagent queues and backups (DAT-010).

**SHD-006 Modes, the router and the organisation list.** The Helm release is per shard. Its values include the name of the shard (`shard`, digits, `001` by default), `mode` (`single` or `multi`), `domain`, `basePath` (`/` by default), the namespace prefix (`cinim` by default) and, in `multi`, the router URL and the shared key. The release is installed into the namespace `<prefix>-<shard>` and puts there the services of the shard and an Ingress for `<basePath>/<shard>/` that serves the pages of the shard itself (sign-in, the choice of an organisation, administration). **`single`**: one shard in the cluster. The release also creates an Ingress for `<domain><basePath>` that goes straight to the core and covers all the organisations. A second shard release is refused: its Ingress for the same host and path conflicts with the first (ingress controllers that validate Ingress objects, such as ingress-nginx, reject the duplicate), and, independently of the controller, the chart creates a cluster-scoped marker object with a fixed name, so the second release fails with a resource conflict in any case. When `basePath` is `/`, a request to the core for the bare domain is answered with a redirect to `/<org>/` if the shard holds exactly one organisation, and to the page of the shard `/<shard>/`, which lists the organisations, otherwise; when `basePath` is anything else the bare domain belongs to the user, who serves it with another service, and neither the release nor the core handles it. **`multi`**: many shards in the cluster or in several clusters, and one more value is required, the shared key (`routerKey`), the same for the router and for every core. The **router** is a separate chart installed once per cluster as a release of its own; it creates the shared namespace (`sharedNamespace`, by default the namespace prefix the user chose, `cinim`), the router microservice with its Service, and an Ingress for `<domain><basePath>` that points to the router (with `basePath` `/` the bare domain shows the page of the router; with any other `basePath` the bare domain belongs to the user, as in `single`, and the router does not handle it). The router proxies nothing: every organisation is opened through its own Ingress (SHD-001) and the pages of a shard through the Ingress of its release. The router never calls Kubernetes. Organisations are registered as in the discovery of Talos: every core sends the list of its organisations (slug, display name, URL) with `POST <domain><basePath>/list`, authenticated by the shared key (compared in constant time, over TLS), at least once a minute. A POST replaces the whole list of that core and is valid for a limited time (5 minutes by default, `router.ttl`); an entry that is not renewed disappears. The router keeps the lists in memory, so after its restart the next POSTs of the cores rebuild them. A core gets the list of all organisations with `GET <domain><basePath>/list` (also with the key) and shows it as an organisation switcher (a drop-down list); when the router is unreachable the core shows the last list it received, or only its own organisation. When an organisation is created its core checks the slug against that list; a duplicate that appears later (for instance because the router was unreachable at the time) is shown in the UI as an alert, and nothing is changed automatically. A core of another Kubernetes cluster registers in the same way with the same router URL, so no records are made by hand. Clusters have ingress controllers of their own, so several clusters mean several base URLs, to which the router links, unless all of them stand behind one load balancer that sends the paths to the right cluster (for example the dev, stage and prod clusters of one data centre); building such a balancer is the operator's job. For people the router serves a page at `<domain><basePath>` with the list of the organisations and their availability: whether the core of an organisation is up (its last POST is within the time to live) and when it was last seen. The page also draws an availability chart for the last 24 hours, one strip per core with one cell per minute (up if a POST of that core was within the time to live at that minute, otherwise down), as server-side SVG with a table alternative (UI-006). The history is kept in memory (about 1 440 cells per core) and is lost when the router restarts; for a longer history the router exposes `/metrics` for Prometheus (`cinim_router_core_up{core}`). `router.listOrganizations=false` turns the page and the chart off while `/list` stays for the cores. `list` is a reserved slug (SHD-001), so that no organisation hides `<basePath>/list`. The router and the `multi` mode belong to stage M1 (section 17).

**SHD-007 Creating an organisation.** An organisation is created in the UI (or with `POST /api/v1/organizations`) by a user with the Platform admin role of the shard. The UI checks the slug while it is typed: besides the rules of SHD-001 it verifies that the namespace name `<prefix>-<shard>-<slug>` is at most 63 characters (the limit for a namespace name) and shows how many characters are left; the core repeats the check, because the API can be called without the UI. The core: (1) checks the slug (SHD-001), the list of the router included; (2) creates the namespace `<prefix>-<shard>-<slug>` for the steps of the organisation, labelled with the shard and the organisation and with Pod Security `restricted` (`pod-security.kubernetes.io/enforce=restricted`, the same value for `audit` and `warn`); (3) creates the job controller of the organisation in that namespace: a ServiceAccount, a RoleBinding that gives it the ClusterRole `<prefix>-<shard>-step-runner`, which the chart creates once per shard so that two shards of a cluster do not share it (pods, persistentvolumeclaims, secrets, services, leases and events, SEC-010) in that namespace only, a Secret with its bootstrap token (IAM-003) and a Deployment; the controller is small (NFR-012), connects to the core by an outbound connection (RUN-002) and watches only its own namespace; (4) creates a default ResourceQuota, LimitRange and NetworkPolicy (default-deny with the allowances of SEC-003 for the Pods of steps; the controller is not a step Pod and is left out of the egress policies, because its way to the API server cannot be named in a portable NetworkPolicy, Cilium keeps node addresses out of `ipBlock`, and its ingress is closed by a policy of its own); (5) in `multi` mode creates the Ingress `<basePath>/<slug>/` in the namespace of the shard (in `single` mode the Ingress of the release covers every organisation); (6) records the organisation in the database, from where it goes into the next registration at the router. An organisation is removed in two steps. It is first switched off (state `disabled`): its Ingress and its controller are removed, it leaves the registration at the router, and its data stays. It is deleted for good, in the reverse order of the steps above with the namespace and its volumes, after the retention period (`org_retention`, 14 days by default, 0 means at once) or earlier on an explicit confirmation in the UI. Besides a namespaced Role for Ingress objects in the namespace of the shard (`multi` mode), the core needs a ClusterRole to `get`, `list`, `create` and `delete` namespaces, to create and delete ServiceAccounts, Secrets, PersistentVolumeClaims (the state volume of the controller), Deployments, RoleBindings, ResourceQuotas, LimitRanges and NetworkPolicies, and to `bind` the ClusterRole `<prefix>-<shard>-step-runner` (restricted by `resourceNames`), and nothing else. The chart installs a ValidatingAdmissionPolicy (stable since Kubernetes 1.30) that lets these requests touch only namespaces named `<prefix>-<shard>-*`; on older clusters the operator may turn it off (`admissionPolicy.enabled=false`) at their own risk. This is the only cluster-wide right of the core and is covered in the threat model (T-45).

**SHD-008 Reconciliation.** At start and every `org_reconcile_interval` (5 minutes by default) the core compares the organisations in its database with the Kubernetes objects of SHD-007 (the namespace, the job controller with its ServiceAccount, RoleBinding, Secret and Deployment, the ResourceQuota, LimitRange, NetworkPolicy and, in `multi` mode, the Ingress; a switched-off organisation is expected without the Ingress and the controller) and creates the missing ones with the same content. It never deletes an object by itself: an object that differs from the expected one, or that belongs to no organisation, is shown as an alert in the UI, and objects are removed only by the explicit deletion of an organisation (SHD-007). After a restore of the database into a new cluster this recreates the namespaces, controllers and Ingress objects of the organisations.

**rqlite limits the project accounts for.** Writes go through the leader and Raft; single writes manage, according to the documentation, from 10 to hundreds of requests per second, and batching (the bulk API, transactions) raises throughput by about two orders of magnitude; writes block while a snapshot is created and during VACUUM. Consequences: heartbeats, logs and queue offers are not written to rqlite (RUN-002, DAT-001); writes are grouped in batches; snapshots and VACUUM are configured and scheduled outside peaks. Measured (A.2): a batch of 500 rows gives about 4 000 rows/s against 10--60 single writes/s (a difference of about 100×), a pause during VACUUM on about 20 MB is 1.1--2.6 s.

**The ladder when writes to a shard's rqlite are insufficient.** (1) Reduce and enlarge writes: batches, moving ephemeral data out of the database. (2) Make the shard smaller: move some tenants to a new shard (SHD-003). Replacing rqlite with another database is not foreseen; the `StateStore` interface with a set of conformance tests remains an internal boundary of the core for test substitution.

**Platform events go only through the outbox in rqlite.** Webhook events, delivery of notifications about available work and fan-out of statuses go through an outbox table (consumers with an idempotency key and an inbox table, 7.2); there is no separate bus and state stays in rqlite. If delivery systematically fails NFR-003 even after the shard is made smaller (SHD-003) and writes are enlarged, the question of which broker to add is raised again (D-03).

**Backup.** Every shard is backed up independently: the backups of rqlite and the logs are planned and performed by the shard core, managed from one UI section (BKP-001--BKP-006). Backup and restore of the logs have been measured (A.7: a snapshot in 0.02 s, node recovery in 8.5 s); backup and restore of `state` use rqlite's S3 flags (A.11).

## 7.4 Speeding up step start: repeated Pod starts and session mode

Ordinary containers cannot be added to an existing Pod, and ephemeral containers are meant for debugging and do not suit a working load `[verify]`, so the base model is one Pod per step (RUN-002). Its price is the start latency of RUN-013 for every step. To reduce it the model is built on repeated starts of disposable Pods over a persistent volume; a full session mode is held in reserve (open question Q-14). The measures are applied in order.

1. **Repeated Pod starts over a volume (RUN-014, MVP).** A Pod keeps no state, so it is created anew for every step and retry, and the whole state of the run lives on the volume (STO-001) and in the env files (STO-003). A step spends no time on preparing data.

2. **Persistent volumes between runs (STO-008, stage M2).** Checkout, dependencies and intermediate results survive a run; a step starts from a warm directory.

3. **Preloading images** of the shim and the typical images of a profile onto nodes (RUN-013).

4. **Session mode (in reserve, stage 3).** Applied only if measures 1--3 do not reach RUN-013.

**SES-001 Condition for switching on.** Session mode is developed only if one of the following holds: (a) measurements show that p95 of step start under RUN-013 cannot be reached on the target clusters even with measures 1--3 (not the case in the reference environment, A.6, where p95 of 7.0 s meets the target of 10 s; to be checked again for batch starts and on weaker clusters); (b) a significant share of jobs consists of dozens of short steps with one image.

**SES-002 Essence.** For a job with the mode switched on, one Pod with one image is created; the shim works as its entrypoint in session mode: it opens an outbound stream to the scheduler by the task token (SEC-010), receives the commands of the following steps and executes each as a child process in the same container. There is no permanent process on the node; a session lives no longer than the job. A step with another image runs in a separate Pod.

**SES-003 Requirements are kept.** The journal, outputs, storage (STO-001), redaction, restricted Pod Security and cancellation work as in the base model; cancelling a step in a session is a signal to the process and its group. Separation of secrets between steps is ensured by cleaning the environment of the child process; the mode is not switched on for untrusted pipelines (SEC-007).

**SES-004 The interface does not change.** The pipeline script and Lua API v1 are the same in both modes; the mode is chosen by the execution profile (RUN-004).

# 8 Data model

All data belongs to a shard; there is no global database. Every table of a shard has `tenant_id` (SHD-004).

## 8.1 Identities and the plugin catalogue

These tables belong to each shard like all the others; there is no global database.

| **Table** | **Key fields** | **Key/index** |
|:---|:---|:---|
| identities | id, provider, subject, email, state | provider, subject |
| memberships | identity_id, tenant_id, role_bindings | identity_id, tenant_id |
| plugin_catalog | id, name, version, digest, signature, trust, created_at | name, version |

## 8.2 Shard data

| **Table** | **Key fields** | **Key/index** |
|:---|:---|:---|
| organizations | id, tenant_id, slug, state (active, disabled), settings, plan, created_at | slug |
| groups | id, tenant_id, parent_id, slug, policy_set_id | parent_id, slug |
| projects | id, tenant_id, group_id, slug, policy_set_id | group_id, slug |
| repositories | id, project_id, provider, external_id, url, default_branch | provider, external_id |
| pipeline_definitions | id, project_id, repository_id, path, enabled | repository_id, path |
| pipeline_bundles | id, definition_id, commit_sha, source, module_digests, api_version, runtime_version, digest | definition_id, digest |
| runs | id, project_id, bundle_id, trigger_id, parent_run_id, state, actor_id, params (launch parameters, at most 4 KiB), version, timestamps | project_id, created_at |
| run_journal | run_id, seq, kind, fingerprint, payload, result, created_at | run_id, seq |
| jobs | id, run_id, key, state, profile_id, attempt, version | run_id, key, attempt |
| steps | id, run_id, job_id, ordinal, type, state, wait_reason, priority, profile_id, image, command, opts (the canonical JSON of the Lua step options), controller_id, pod_name, exit_code, termination (the reason the attempt ended), attempt, not_before, claimed_at, shim_n, shim_phase, shim_json, shim_seen_at, shim_source (the shim's last known state, D-30), version, timestamps | run_id, ordinal; state, profile_id, priority |
| execution_profiles | id, tenant_id, name, namespace, node_selector, runtime_class, resources, storage_class, network_class, trust_level, max_parallel, infra_retries, log_max_bytes, log_spool_bytes, log_hold_timeout, liveness_timeout (D-34) | tenant_id, name |
| job_controllers | id, tenant_id, namespace, identity, state, version | identity |
| run_storage | run_id, pvc_name, size, storage_class, state, retention_until | run_id |
| log_streams | job_id, step_id, attempt, index_name, line_count, state (open, closed, abandoned), closed_at | job_id, step_id, attempt |
| log_nodes | id, url, state (up, catching_up, down, needs_restore), version | id |
| backups | id, target (state, logs, audit), node_id, object_key, stream_offset, sha256, size, state (running, uploaded, verified, bad, failed), verified_at, created_at | target, created_at |
| backup_policies | target, enabled, interval, retention, verify_interval, updated_by, updated_at | target |
| leases | scope, owner, token, expires_at | scope |
| artifacts | id, run_id, job_id, object_key, digest, size, retention | object_key |
| environments | id, project_id, name, tier, protection, lock_version | project_id, name |
| deployments | id, environment_id, run_id, artifact_digest, state | environment_id, created_at |
| credentials | id, scope, provider, encrypted_ref, metadata, version | scope, name |
| variables | id, scope (organization, group, project, pipeline), scope_id, name, kind (plain, secret), value (plain only), credential_id (secret only), declaration (type, required, choices, pattern, max_length), version, updated_by, updated_at | scope, scope_id, name |
| outbox | id, topic, payload, created_at, delivered_at | delivered_at, id |
| audit_events | id, tenant_id, actor, action, resource, before, after, ip, time, prev_hash, hash | tenant_id, time, id |
| audit_anchors | id, chain, from_seq, to_seq, head_hash, created_at, exported_at | chain, to_seq |

The table `log_streams` holds only the metadata of a stream (tenant, the job's stream in VictoriaLogs, the number of lines, the state); the contents of logs never reach rqlite, and the line counter is updated when the stream is closed. Every attempt of a step has its own stream; the stream of an attempt that was lost is marked `abandoned`. SQLite does not support partitioning, so hot tables are kept small: finished runs together with their journal move to an S3 archive (Protobuf) after `hot_retention` (14 days by default) and a pointer row stays in rqlite; `audit_events` (the store `rqlite`, AUD-001) is rotated by tables per month and exported to WORM/SIEM; with the store `victorialogs` only `audit_anchors` stays in rqlite. UUIDv7 identifiers are stored as BLOB(16). Secret material is not stored in these tables: credentials contains only envelope-encrypted ciphertext or an external reference; the `outputs` of steps (at most 4 KiB per step) are not meant for secrets (STO-004). The environment of a step and the env file are not stored in these tables (VAR-002, STO-003).

# 9 API and events

## 9.1 External REST API

| **Method** | **Path** | **Purpose** |
|:---|:---|:---|
| POST | /api/v1/projects/{id}/runs | Start a pipeline with a ref and typed params; Idempotency-Key is mandatory for automation |
| GET | /api/v1/runs/{id} | State, the graph from the journal, steps with their attempts and the reason each ended (`steps[].termination`), permission-filtered links |
| GET | /api/v1/runs/{id}/journal | A paged read-only call journal for diagnostics and the UI |
| POST | /api/v1/runs/{id}/inputs/{input_id} | Answer to `ci.input`: approve/reject with a comment |
| POST | /api/v1/jobs/{id}:retry | Create a new attempt with an optimistic version |
| POST | /api/v1/runs/{id}:cancel | Idempotently request cancellation |
| GET | /api/v1/jobs/{id}/log | A log window: `from` (line number) or `around` (a line), `limit` (≤ 500); search: `q`; follow through SSE (DAT-007) |
| GET | /api/v1/jobs/{id}/log:download | Streamed download of the full log (DAT-009) |
| POST | /api/v1/jobs/{id}/log-tokens | Issue a log viewing token (valid up to 60 s, IAM-004) |
| GET | /api/v1/runs/{id}/storage | State and use of the run storage (STO-001) |
| POST | /api/v1/pipelines:check | Preflight and static check of a script (PIP-016) |
| POST | /api/v1/environments/{id}/approvals | Approve/reject with a comment and the expected policy digest |
| GET | /api/v1/audit-events | Cursor pagination and filters; asynchronous export |
| GET | /api/v1/audit-chain | The audit store, the newest anchor, the last verification and its result (AUD-004) |
| GET, POST | /api/v1/organizations | The organisations of this shard and their state; POST creates an organisation, with its Kubernetes objects when the core runs in a cluster (SHD-007) |
| DELETE | /api/v1/organizations/{slug} | Switches the organisation off (its Ingress and controller are removed, the data stays); `?purge=true` deletes it for good, with its namespace, and needs the organisation to be switched off already or `force=true` (SHD-007) |
| GET | /api/v1/organizations:check | `?slug=` The slug rules and how many characters of the namespace name are left (SHD-007); what the UI asks while a slug is typed |
| GET | /api/v1/router | The data of the organisation drop-down (the router's list, or this shard's own organisations without a router), the router's reachability and the alerts for a slug held by two cores (SHD-006) |
| GET | /api/v1/shards/{id}/backups | One list of rqlite and log backups, statuses and recovery progress (BKP-002) |
| POST | /api/v1/shards/{id}/backups | Start a backup manually (`target`: state or logs), audited |
| PUT | /api/v1/shards/{id}/backup-policy | Change the schedule, retention and verification (BKP-001), with confirmation and audit |
| GET, PUT | /api/v1/profile | The execution profile's settings (D-34); PUT takes any subset of `infra_retries`, `log_max_bytes`, `log_spool_bytes`, `log_hold_timeout`, `liveness_timeout`, each validated against its range |
| GET, PUT | /api/v1/{scope}/{id}/variables | Variables of an organization, group, project or pipeline (VAR-001); PUT validates every variable (VAR-003) and answers with Problem Details naming the failing fields |
| GET | /api/v1/launch-gate | The state of the launch gate and the reason (RUN-015) |
| GET | /api/v1/components | Every component the core knows, its state and the time since its last sign of life (RUN-016) |
| GET | /metrics | Prometheus text: component liveness, steps and runs by state, the gate, in-flight resource use and the application metrics aggregated over the steps in flight (docs/metrics.md); can be turned off in Helm (`metrics.enabled`, on by default) |

- Errors conform to RFC 9457 Problem Details: type, title, status, detail, instance, code, fields, request_id.

- Pagination is cursor-based; timestamps are RFC 3339 UTC; IDs are UUIDv7; ETag/If-Match for mutable resources.

- Breaking changes create a new major API; additive fields are allowed. SDKs must ignore unknown response fields.

- Domain events have an envelope: id, type, specversion, source, tenant, subject, time, data, correlation_id, causation_id. Inside the platform events are encoded in Protobuf, outward (webhooks, integrations) they are published as JSON by the CloudEvents schema.

## 9.2 Internal Protobuf channels

Internal channels are Protobuf over ZeroMQ with CURVE (D-24), package `cicd.internal.v1`; N/N-1 compatibility is checked in CI (7.1). Services and the job controller authenticate with CURVE key pairs and clients pin the server's public key; the shim channels (LogIngest, StepReport) use the shared client key plus the task token (D-24, SEC-010). The channels to VictoriaLogs (LogPublish, NodeControl, LogRead) use TLS with a login and password, marked in their rows.

| **Channel** | **Direction** | **Purpose** |
|:---|:---|:---|
| ControllerAttach | Job controller → scheduler (outbound request/reply poll) | Receiving step tasks and cancellations (`CancelStep` for a Pod the core no longer wants), the state of the launch gate (RUN-015), reports of Pod transitions with the shim's state read from the Pod's log, an inventory of the Pods the controller tracks, the controller's status as its heartbeat (RUN-016); registration by a bootstrap token in exchange for a key pair (IAM-003) |
| LogIngest | Shim → log collector (client request/reply) | Log blocks with sequence numbers and checksums, the shim's status JSON and resource metrics as a heartbeat (a batch without blocks); the acknowledgement follows vlagent's acceptance (DAT-001); also used by the job controller to hand over blocks it pulled out of a Pod's spool |
| StepReport | Shim → scheduler (unary) | The step's result and the shim's final state (RUN-010); the answer says whether the shim may exit (RUN-017); the termination message and the Pod log carry the same facts as the fallback |
| ExecutorChannel | Executor ↔ scheduler | Host API requests, the journal, results; the only channel of the sandbox (RUN-008) |
| LogPublish | Log collector → vlagent → VictoriaLogs nodes | Sending log lines to vlagent's `/insert/jsonline` (JSON lines: `_msg`, `_time`, `ln`, `ts`, `job`, `run`; headers `AccountID`, `ProjectID`; independently gzip-compressed blocks with `Content-Encoding`), delivery to both nodes; an exception to the Protobuf rule, the format is given by the product (DAT-001, DAT-008); TLS and a login and password |
| NodeControl | Shard core (log-circuit module) → VictoriaLogs nodes and vlagent | Polling `/health` and metrics, snapshots `/internal/partition/snapshot/*`, deletion `/delete/run_task`, pausing delivery and clearing a queue on recovery (DAT-008, BKP-003, BKP-004); TLS and a login and password |
| ClusterState | Log gateway → shard core | The state of the VictoriaLogs nodes (`up`, `catching_up`, `down`, vlagent queue) and the recommended read node (DAT-011); the scheduler gets the same state in process (RUN-015) |
| LogRead | Log gateway → the chosen VictoriaLogs node | Window queries, tail, export to the node chosen by ClusterState, with a retry on the other (DAT-011); TLS and a login and password |

The shim's state is one JSON object, numbered by event, carried by the heartbeat, the StepReport and the Pod's own log, and recorded in `steps.shim_json`; a state replaces a stored one only when it comes from a later event (D-30).

# 10 Plugin SDK and marketplace

## 10.1 Extension types

| **Type** | **Contract** | **Example** |
|:---|:---|:---|
| Step | An OCI image run in the step's Pod; input and output through a file contract (PLG-008); WASM is outside the MVP (open question Q-06) | Helm upgrade, Sonar scan |
| Trigger | Webhook schema -> normalized event | GitHub pull_request |
| SCM adapter | Resolve ref, checkout credential, status/check API | GitLab |
| Secret provider | Resolve(handle, context) -> leased secret | Vault/OpenBao |
| Report parser | Stream artifact -> normalized report | JUnit, SARIF |
| Notifier | Domain event -> external message | Slack |
| Policy check | Admission input -> allow/deny/warn | Change window |
| UI contribution | Extension point + panel URL + context token | A run tab, a dashboard widget |

## 10.2 Plugin protocol

**PLG-008 Protobuf protocol.** The plugin contract is described in `.proto` (package `cicd.plugin.v1`). A step plugin is an ordinary container in the step's Pod (RUN-010) with a file contract on the shared storage: the shim writes the `ExecuteStep` request to the file `$CICD_PLUGIN_REQUEST` (a length-prefixed message: varint + Protobuf, in the directory `/cicd/run/plugin/`), the plugin reads it, does its work in `/cicd/workspace`, writes `StepResult` to `$CICD_PLUGIN_RESULT` and exits; the log is stdout and stderr, which the shim collects. Such a contract needs neither a network path from the plugin to the platform nor a permanent connection nor an SDK in a particular language. Service plugins (trigger, secret provider, notifier, policy check, report parser) run as separate services over HTTP/2 or a unix socket and agree the protocol version (N and N-1) in the first `Hello` message. The default maximum message size is 4 MiB, unknown fields are ignored, removed field numbers are reserved. Compatibility is checked in CI by a breaking-change checker for `.proto`, and a conformance container is run before a plugin is published. A sketch of the schema:

```proto
syntax = "proto3";
package cicd.plugin.v1;
import "google/protobuf/struct.proto";

message Hello        { uint32 protocol = 1; string plugin = 2; string version = 3; }
message ExecuteStep  {
  uint32 protocol = 5;                        // contract version (N or N-1)
  string step_id = 1;
  google.protobuf.Struct inputs = 2;          // validated against the plugin's JSON Schema
  map<string, string> secret_handles = 3;     // names, not values
  string workspace = 4;                       // /cicd/workspace
}
message StepResult   { string step_id = 1; int32 exit_code = 2; google.protobuf.Struct outputs = 3; }
```

The inputs of a step go through the path Lua table -> canonical JSON -> validation against the plugin's JSON Schema -> `google.protobuf.Struct`. Scripts and configuration stay human-readable and Protobuf is used on the wire.

## 10.3 Manifest

```json
{
  "apiVersion": "plugins.cicd.example.io/v1",
  "name": "deploy/helm",
  "version": "3.0.0",
  "runtime": "oci",
  "image": "registry.example/plugins/helm@sha256:...",
  "entrypoint": ["/plugin"],
  "compatibility": { "server": ">=1.0 <2.0", "protocol": 1 },
  "capabilities": ["network", "workspace.read", "artifacts.read", "secrets.request"],
  "inputsSchema": "schemas/inputs.json",
  "outputsSchema": "schemas/outputs.json",
  "signature": { "type": "sigstore", "identity": "release@example.com" }
}
```

**PLG-001 Isolation.** A third-party plugin is never loaded into a control-plane process. A step runs in its own step Pod with no access to the control plane except the job token; service extensions run in a separate process or Pod over a versioned protocol.

**PLG-002 Capabilities.** The manifest declares network, workspace, artifacts, cache, secrets, oidc, privileged, host mounts and `ui.contribute`. The capabilities `privileged` and `host mounts` are not satisfied in the MVP (RUN-012, SEC-004). Policy may forbid the others or require approval.

**PLG-003 Supply chain.** The marketplace accepts only an immutable OCI digest, an SBOM, provenance and a signature. The UI shows the publisher, permissions, vulnerabilities and the last audit.

**PLG-004 Compatibility.** The protocol uses semantic versioning; the server supports N and N-1; the conformance suite is run before publication.

**PLG-005 Configuration.** Every plugin ships a JSON Schema with defaults, secret annotations and UI hints; unknown fields are rejected in strict mode.

**PLG-006 Updates.** An update does not change existing runs; a pipeline pin fixes the digest. Automatic update is allowed only for a chosen SemVer range and after a policy scan.

**PLG-007 UI contributions.** A plugin with the capability `ui.contribute` adds panels to the extension points of the UI (UI-002). A panel is served as an iframe from a separate origin (`x.<base-domain>/<plugin>/`), with the attribute `sandbox="allow-scripts allow-forms"` without `allow-same-origin` and a CSP `frame-ancestors` limited to the UI origin. The context (project, run, job, user, permissions) is passed in a signed token (IAM-004), not a cookie. The plugin has no access to the DOM of the main UI; size and navigation are exchanged through `postMessage` with an origin check. An administrator approves a UI contribution separately and can revoke it without removing the plugin.

# 11 Security

## 11.1 Threat model

| **Threat** | **Main control** |
|:---|:---|
| An untrusted PR extracts a production secret | Trust level of refs; protected environments; fork jobs without secrets; explicit approval |
| Poisoned cache/artifact | Namespace by trust boundary; digest verification; immutable keys; provenance |
| Malicious plugin | Signature, capabilities, sandbox, network deny, no in-process code |
| Escape from the Lua sandbox of a pipeline script | Allow-list environment, a separate unprivileged process, seccomp, no network and no database, CPU/memory limits, fuzzing of the host API |
| Tampering with or corruption of a run's journal | Hash chain of journal records, verification on replay, append-only, written only by the executor |
| Authorization bypass when viewing logs and panels | 60 s tokens, a separate origin, a sandboxed iframe, VictoriaLogs only on the internal network, the gateway is the only reader, queries limited by tenant (`AccountID`) and job stream, redaction before write |
| Memory-safety errors at the Nim/C boundary | Sanitizer builds, parser fuzzing, input limits, wrappers with `=destroy`, a minimum of `cast` and unsafe code |
| Compromise of a step Pod or a job token | The token is bound to the Pod and the attempt and lives for minutes (SEC-010), restricted Pod Security, default-deny NetworkPolicy, an ephemeral Pod, no access to the database and the Kubernetes API |
| Compromise of the job controller | A minimal Role in the profile's namespace, no cluster-wide rights, an outbound connection, a CURVE identity, audit of actions (SEC-010) |
| Injection through the env file (`LD_PRELOAD`, `PATH`) | A dotenv-subset parser in the shim, a deny-list of names, limits (SEC-011, STO-004) |
| Container escape or tenant co-location on a node | A namespace and quotas per tenant, a RuntimeClass with a sandbox (gVisor or Kata) for untrusted pipelines, separate profiles and nodes (SEC-012) |
| Secret leaks in logs | Masking in the shim before anything leaves the Pod (D-31, DAT-002), ephemeral Secrets, structured secret handles, shell tracing disabled, retention controls |
| Webhook spoof/replay | Provider signature, timestamp window, delivery dedupe, optional IP policy |
| Dependency confusion | Pinned components, private registry priority, digest allow-list, SBOM |
| Unauthorized deployment | Environment RBAC, separation of duties, immutable approval snapshot, audit |

**SEC-001 Encryption.** TLS 1.3 preferred, TLS 1.2 minimum; envelope encryption AES-256-GCM; master keys from KMS or Vault transit; rotation without mass plaintext exposure. Internal ZeroMQ channels use CURVE (D-24).

**SEC-002 OIDC federation.** Jobs request a signed token with an audience, a subject made of organization/project/pipeline/environment/ref, a TTL <= 10 minutes and a unique jti.

**SEC-003 Network.** Step Pods and service Pods get a default-deny NetworkPolicy (ingress closed; egress is DNS, the log collector and the scheduler of the shard, the rest by allow rules derived from plugin capabilities and project policy). VictoriaLogs (the nodes), vlagent and rqlite are reachable only by the services of the shard, and step Pods reach them only through the collector.

**SEC-004 Privileged.** A privileged container, the Docker socket, hostNetwork, hostPID and hostPath are not supported in the MVP (RUN-012); Pod Security `restricted` on the profile's namespace blocks them independently of the platform.

**SEC-005 Audit.** Audit is append-only, hash-chained and exported to WORM/SIEM, and is stored in rqlite or, as an option, in a separate VictoriaLogs circuit (AUD-001); reading or changing credentials and changing variables is logged, without secret values, only when the organization turns that on (`audit.variables`, VAR-006).

**SEC-006 Compliance.** Provide a controls mapping to SOC 2/ISO 27001, data retention, a DPA, tenant export/delete; certification is not an MVP feature.

**SEC-007 Isolation of the pipeline executor.** The worker is a separate unprivileged process or container: a seccomp profile, a read-only file system (except a limited tmpfs), no network and no database access, rlimits on CPU and memory, one Lua state per run destroyed when the run finishes; there are no shared tables or global state between runs.

**SEC-008 Journal integrity.** Every journal record contains the hash of the previous one; on replay the chain is verified, and a violation moves the run to `infrastructure_error` with the code `journal_corrupted`.

**SEC-009 The C boundary.** External C libraries (Lua, TLS, codecs) are used at pinned versions and built in CI with sanitizers, and the parsers of untrusted data (report XML, Protobuf from plugins, HTTP/2 frames) have input limits and fuzz tests.

**SEC-010 Job token and controller rights.** A step Pod gets only a projected ServiceAccount token (audience `cicd-shard`, TTL 10 minutes, bound to the Pod), mounted in the shim's service directory; `automountServiceAccountToken` is off for the step's ServiceAccount and it has no rights in the Kubernetes API. The collector and the scheduler verify the token's signature against the cluster's published keys and match the Pod's name with the expected attempt of the step (fencing). The job controller uses a Role only in the profile's namespace (pods, persistentvolumeclaims, secrets, services, leases, events), without cluster-wide rights; the bootstrap token is exchanged for a key pair (IAM-003), and all its actions are audited. `pods/exec` is granted only for collecting a spool that was not delivered (DAT-001).

**SEC-011 Env file.** The files `CICD_ENV` and `CICD_OUTPUT` are parsed by a dotenv-subset parser, not by a shell; names are checked against the deny-list (STO-004), sizes are limited (STO-003), values with control sequences are rejected; a violation ends the step with the code `env_rejected`.

**SEC-012 Tenant isolation in the cluster.** Pods of different tenants do not share a namespace `[recommendation]`: the namespace `<prefix>-<shard>-<org>` of every organisation (SHD-007) or a profile with ResourceQuota, LimitRange and NetworkPolicy; for untrusted pipelines (forks) the profile uses a RuntimeClass with a kernel sandbox (gVisor or Kata) and separate nodes.

# 12 Non-functional requirements

| **ID** | **Metric** | **Target** |
|:---|:---|:---|
| NFR-001 | API availability | >= 99.95% monthly for an HA deployment, excluding agreed maintenance |
| NFR-002 | Webhook acceptance | p95 < 500 ms to durable persistence; heavy processing is asynchronous |
| NFR-003 | Queue latency | p95 < 2 s from a step being ready to run to the Pod being created, when the cluster has free resources |
| NFR-004 | Cancel latency | p95 < 5 s until Pod deletion starts; < 30 s until forced termination |
| NFR-005 | Log latency | Live tail p95 < 5 s from output in the Pod to appearance in the browser window (a lag of a couple of seconds is acceptable, D-20); log window p95 <= 300 ms from request to ready HTML; writes to VictoriaLogs >= 5 MiB/s per job with back-pressure |
| NFR-006 | Scale target | One shard: 1 000 concurrent steps (Pods), 100 000 runs/day, 200 runs per executor worker. Platform capacity grows linearly by adding shards; the target without architectural change is 10 shards (10 000 concurrent steps, 1 million runs/day). Neither target has been measured yet: the single-shard one is confirmed by the benchmark of stage M1 (500 concurrent steps in the MVP) and the ten-shard one by that of stage M4 |
| NFR-007 | Recovery | RPO <= 5 min for state (rqlite), RTO <= 30 min per shard; RPO of logs: close to zero when one VictoriaLogs node is lost, <= 1 h (the backup interval) when both nodes of a shard's log circuit are lost (Appendix A.11); a documented restore drill |
| NFR-008 | Accessibility | WCAG 2.2 AA for the main UI flows and keyboard-only operation |
| NFR-009 | Browser | The last 2 major versions of Firefox/Chrome/Edge; the server-rendered core is usable without JS except live updates and the iframe log viewer |
| NFR-010 | Upgrade | Rolling upgrade within a minor version; schema migrations are backward compatible for at least one release |
| NFR-011 | Localization | UI strings are externalized; the baseline is English; further languages need no code changes |
| NFR-012 | Resource baseline | A small installation (one shard, one replica of each service, one rqlite node, two VictoriaLogs nodes and vlagent, no fault tolerance for the other services): 8 vCPU/10 GiB; an idle Nim service process < 30 MiB RSS; the job controller < 50 MiB RSS with 500 watched Pods; the shim < 15 MiB RSS |
| NFR-013 | Memory stability | A 72 h soak at 50% of the Standard profile load: the RSS of each process grows by no more than 2% after warm-up; the integration suite under LeakSanitizer reports no leaks; every process has a hard memory limit and on exhaustion restarts correctly and replays; the shim's RSS does not grow with the log volume |
| NFR-014 | Executor | Replay of a 10 000-record journal <= 2 s p95; preflight of a script with up to 1 000 `ci.job` calls <= 2 s p95 |
| NFR-015 | VictoriaLogs | The Pod's memory limit and `-memory.allowedBytes`, the reference consumption, the write and window-query latencies (DAT-008) and the vlagent queue volume are recorded in Appendix A.7; window, search and export queries are limited in size and time; disk amplification <= 3× (measured 0.39×); reads switch to the second node without losing queries |
| NFR-016 | Client memory | Every UI page: JS <= 50 KiB gzip, JS heap after load <= 10 MiB, DOM nodes <= 3 000, HTML <= 300 KiB; the log viewing page: heap <= 5 MiB for a log of any size (DOM nodes <= 1 500). Checked by automated tests (UI-008) |

# 13 UI and user scenarios

The UI is built as an MPA, not an SPA: the HTML is produced entirely on the server, and client code is only progressive enhancement. The reasoning is the usage profile: CI/CD is looked at rarely and briefly, so the permanent client memory costs (state, virtual DOM, a client router, large bundles) are not justified, while the server cost of rendering on demand is small and scales together with the stateless API service. Permanent URLs and correct Back/Forward behaviour follow from this choice. HTMX is used for filters, actions and panels; SSE for status and logs. WebSocket is allowed only where two-way traffic is really needed. Every action is available through REST and the CLI.

**UI-001 Permanent links.** Every entity (organization, project, pipeline, run, stage, job, step, artifact, test case, environment, deployment, execution profile, shard, plugin, audit event) has a stable URL; meaningful sub-elements are anchors (`#step-3`, `#L120`, `#test-<fingerprint>`). The state of filters, sorting, page and expanded panels is encoded in the URL. Every element has a "copy link" action. A link opens for another user with the same result within their permissions.

**UI-002 Extension points.** The UI provides a registry of extension points modelled on Jenkins: `dashboard.widget`, `project.tab`, `run.tab`, `job.tab`, `environment.panel`, `list.column`, `parameter.control`, `nav.item`, `page.banner`. A contribution is either declarative (an administrator's setting with no code: a list column from run fields, a banner, a saved view) or a plugin panel in an iframe (PLG-007). The MVP implements `run.tab`, `dashboard.widget` and `parameter.control`; the other points belong to stage 3.

**UI-003 Views.** A user and an administrator save list views (filters, columns, grouping); a view is addressed by a URL and can be shared by a project or an organization.

**UI-004 Dynamic lists.** The lists of runs, jobs, tests and execution profiles are updated in place: SSE for statuses only on a visible tab and only while the entity is active (the connection is closed on a terminal state and when the tab is hidden), polling with back-off as a fallback; cursor pagination on the server; an update does not reset expanded elements, selection or scroll position.

**UI-005 Dynamic elements.** The launch form is built from the parameter types (PIP-012) with dependent fields and validation; retry, cancel and approve run without a page reload and without JS work as ordinary POST forms.

**UI-006 Charts.** Charts (duration, queue, success rate, flaky tests, use of execution profiles and storage) are drawn on the server as SVG without JS; enhancement (hover, zoom) is a small script served from the same server. Every chart has an alternative table and a permanent link to its state (range, filters).

**UI-007 Run graph.** The DAG and the timeline with the critical path are built from the journal (PIP-007) as SVG, with an alternative table for accessibility.

**UI-008 Client memory budget.** Saving client memory is a priority equal to the server's. Every page fits the budget of NFR-016: JS <= 50 KiB gzip (including HTMX), JS heap after load <= 10 MiB, DOM nodes <= 3 000, response HTML <= 300 KiB; the log viewing page (iframe) has heap <= 5 MiB and DOM nodes <= 1 500 for a log of any size. Rules: (a) no client state except the URL and form fields; no frameworks and no client routers; (b) all lists and tables are paginated on the server (50 records by default), with no "infinite" scrolling that accumulates DOM; (c) charts are server-side SVG with at most 500 points per chart; the run graph has at most 300 SVG nodes, the rest is grouped by stage and expanded by a separate request; (d) logs only in windows (DAT-007), at most three windows in the DOM, a window of at most 500 lines and 256 KiB; (e) SSE subscriptions are closed on a hidden tab and on a terminal state, at most one subscription per page; (f) plugin iframes are created lazily when a tab is expanded and destroyed when it is closed, and their contribution to the heap is limited by the same budget. An end-to-end test opens the reference pages (a run with 1 000 jobs, a log of 100 million lines, a list of 10 000 runs) in Chromium, measures the heap through CDP and the DOM size, and fails when the budget is exceeded.

**UI-009 Server rendering.** The UI service keeps no session state in memory and renders pages as a stream (a chunked response, without assembling the whole HTML in memory): the memory per request is limited (8 MiB by default) and does not depend on the data size. The pages of finished runs and jobs are immutable: they are cached by ETag, and the fragments for HTMX are served by the same templates as the full pages. Every screen must work without JS, except live updates and the iframe log viewer (NFR-009).

| **Screen** | **Required content** |
|:---|:---|
| Dashboard | Pinned projects, failing default branches, running/queued, deployments, the state of shards and execution profiles; extension-point widgets |
| Project | Pipelines, variables with their levels and effective values, recent runs, repository status, environments, schedules, settings; saved views |
| Pipeline | The script with highlighting, the `check` result, parameters, triggers, library versions, the call journal of the last run |
| Run graph | DAG, critical path, duration, retries, approvals; a table alternative for accessibility |
| Job | Steps (Pods), a log window with search and live tail (iframe, DAT-007) and a "download" button (DAT-009), timestamps, profile, namespace and Pod name, resources, storage, artifacts, tests, retry/cancel |
| Tests | New failures, flaky tests, slowest, history, owner, baseline diff |
| Environment | Current deployment, history, locks, checks, variables metadata, rollback |
| Profiles and shards | Execution profiles and their settings (D-34), the state of the job controllers (one per organisation), the organisations of the shard, quotas, storage use, the queue, the state of the log circuit (VictoriaLogs nodes and vlagent queues) and the reason a launch is suspended, drain (the Platform admin role) |
| Backups | One section for rqlite and logs: the policy (schedule, retention, verification), manual start, history and statuses, the state of VictoriaLogs nodes and vlagent queues, the progress of automatic recovery and the loss journal (the Platform admin role, BKP-002) |
| Plugin catalog | Publisher, version, digest, permissions, compatibility, security status, approved UI contributions |
| Audit | Actor/action/resource/time filters, a details diff, export; the store and the chain verification status (AUD-004) |

# 14 CLI and local development

- The CLI `cicd` (one static Nim binary) supports login, project, pipeline check/run, run watch/cancel/retry, logs (window and download), artifacts, profiles, shards and admin diagnostics.

- `cicd pipeline check` performs the metadata phase and the static analysis of the script (PIP-016) locally in an embedded Lua, resolves libraries through the lockfile and needs no server; its output suits an IDE problem matcher.

- `cicd run --local` is a developer tool `[recommendation]`: it runs the same script locally, starting every step as a Docker or Podman container with the same shim contract and a local directory in place of storage; it states explicitly which server features are not emulated (approvals, OIDC federation, environments, NetworkPolicy). It is not a supported runtime of the platform (4.2).

- All commands have `--help`, machine-readable `--output json`, stable exit codes and never print tokens or secrets.

- SDK: a client library in Nim (from OpenAPI and `.proto`); for plugin authors, the `.proto` contracts, a plugin template and standard code generation for Go, Python, TypeScript and Rust; Lua type annotations for IDEs (PIP-017); a conformance test container for the plugin protocol.

# 15 Observability and operations

| **Signal** | **Minimum set** |
|:---|:---|
| Metrics | Run/step counts, queue depth and age, the delay from a step being queued to the Pod being created and to the process starting, the number of Pods by phase, the job controller's lag, storage use, log ingest rate, API latency and errors, log window latency, rqlite write latency and leader changes, the vlagent queue size per node, the state of VictoriaLogs nodes, the time the launch gate has been closed, the status of log backups (`uploaded`, `verified`, `bad`), journal size and replay time, the RSS and `getOccupiedMem` of every process, per-shard metrics, the resource and application metrics of the steps in flight (docs/metrics.md) |
| Tracing | Webhook -> preflight -> queue -> Pod -> steps -> reports; the W3C trace context is passed to the Pod through the shim's environment without sensitive baggage |
| Logs | Structured JSON, request/run/job/step/shard IDs, sampling for success, full for errors; PII/secrets filtering |
| Health | /live is the process only; /ready checks critical dependencies; detailed admin diagnostics are protected |
| Alerts | Oldest queue age, no schedulers, loss of contact with a job controller, a Pod in Pending longer than a threshold, PVC creation failures, orphaned resources, rqlite write latency and frequent leader changes, vlagent queue growth, the launch gate closed (no node available) longer than a threshold, a VictoriaLogs node volume or vlagent queue filling up, no successful or verified backup on time and no node for a snapshot (BKP-006), a node recovery in progress and record loss during it, replay errors (`script_nondeterminism`, `journal_corrupted`), RSS growth trend, error budget burn, storage saturation, backup failure |

- The platform learns the state of the log circuit (nodes, vlagent queues, backups) by itself: the log-circuit module (in the shard core) polls the nodes and vlagent (DAT-010) and shows them in the "Backups" section, on administrative pages and in its own metrics.

- Every `/metrics` endpoint, the core's and the router's, can be turned off in Helm with the value `metrics.enabled` (on by default); when it is off the route does not exist (404). A Prometheus that scrapes an installation with metrics off simply gets nothing from it.

- The backup of each shard (rqlite and logs) is scheduled by the core's scheduler, carried out by its log-circuit module and managed from one UI section (BKP-001--BKP-006); in addition, object-storage versioning/lifecycle, encryption keys and a configuration export are copied; the vlagent queue holds only lines not yet delivered and is not a source of truth. Logs have no other source, so the logs' RPO is set in NFR-007 (open question Q-13).

- An upgrade runs a preflight check, then backward-compatible schema migrations, rolling services and a postflight. A down migration is not promised for a destructive schema; a binary rollback is supported within the compatibility window.

- The shim image is versioned together with the control plane, and the job controller creates a Pod only with a shim image compatible with protocol version N or N-1; the server warns and then rejects protocols outside the support window. A controller update is rolling, with a Kubernetes Lease, without losing watched Pods (RUN-002).

# 16 Migration from existing systems

Importers generate Lua scripts (not YAML): the result is a portable draft made of a script, a lockfile and a loss report.

| **Source** | **Imported automatically** | **Needs manual review** |
|:---|:---|:---|
| Jenkins | Declarative stages, agents/labels (into execution profiles), environment, sh/bat, parallel, junit, artifacts | Scripted Groovy, arbitrary plugins, CPS semantics, credentials bindings |
| TeamCity | Projects, build configurations, templates, parameters, VCS roots, artifact/snapshot dependencies | Kotlin custom code, server plugins, agent requirements (mapping to execution profiles), edge cases |
| GitHub Actions | Triggers, jobs/needs, matrix, env, container, run, mapping of common actions | JavaScript actions, permissions differences, expressions, services networking |
| GitLab CI | Stages/jobs, needs, a subset of rules, artifacts/cache, environments, includes | Complex rules, child pipelines, GitLab-specific reports and services |
| CircleCI | Jobs/workflows, executors, matrix, cache/workspace | Orbs without a mapping, dynamic config |
| Travis CI | Languages/images, phases, matrix, cache, a subset of conditions | Deployment providers and addon-specific behaviour |

Importers for Drone, Bitbucket Pipelines, Semaphore and Bamboo are in the backlog after stage 5; for Bamboo this matches the end-of-life date of Bamboo Data Center (2.13).

**MIG-001 Dry run.** An importer does not create production resources at once: it produces a portable draft (a Lua script and a lockfile), a mapping report and a list of unsupported constructs with a severity.

**MIG-002 Differential validation.** For selected pipelines the old and the new system run in parallel; exit status, artifact digests, tests and deployment intent are compared.

**MIG-003 Cutover.** Webhook ownership is switched after a green observation period; a rollback keeps the old configuration and forbids a double deploy through an environment lock.

# 17 Delivery plan

Delivery is a sequence of vertical slices with verifiable exit criteria rather than calendar dates. The estimate assumes reuse of rqlite, S3, an OIDC provider, an OCI registry, BuildKit, Kubernetes and Lua; own replacements enlarge the scope. The technology choices of the platform are already confirmed by measurement (Appendix A), so the plan starts with the working product.

| **Stage** | **Slice (what works end to end)** | **Exit criteria** |
|:---|:---|:---|
| M1 CI MVP | A GitHub/GitLab webhook, run creation, a Lua script with `job`, `sh`, `use`, `parallel`, `matrix`, `input`; the job controller and a Pod per step, shared storage and exchange through .env; logs in VictoriaLogs (two nodes, vlagent, the log-circuit module in the shard core process) with a window in an iframe and download; repeated Pod starts over a volume (RUN-014); artifacts, JUnit, OIDC/RBAC; a server-rendered UI with permanent links and the MVP extension points; a shard with organisations created in its UI (SHD-007), in the `single` and `multi` modes, with the router (SHD-006) | Acceptance criteria 1--9, 11--12, 16--24 and 26--29 within the MVP scope; 500 concurrent steps |
| M2 Managed CD | Environments, approvals, Helm/Kubernetes, Vault/OpenBao, OIDC cloud federation, deployment history and rollback; persistent volumes between runs (STO-008) | Criteria 10, 14 and 25 |
| M3 Ecosystem | The plugin registry and SDK, the conformance container, the remaining 10 first-party extensions, a registry of Lua libraries, the full set of extension points, signing and provenance; session mode (7.4) if SES-001 is met | Criterion 15 for all 20 extensions; N/N-1 verified for `plugin.v1` |
| M4 Enterprise scale | SAML, audit export, HA hardening, quotas and fairness, several shards and organisation transfer (SHD-003), a benchmark of 10 shards | NFR-006 for 10 shards; criteria 13, 22 and 30 |
| M5 Migration | Importers (they generate Lua), shadow runs, admin tooling, compatibility guides | MIG-001--MIG-003 on real projects |

"Stage N" elsewhere in this document means the stage MN of this table.

# 18 Testing

- Unit: the Lua host API, parameter types, state transitions, RBAC, redaction (including a secret split by a chunk boundary), scheduling and fairness, the hash chain of the journal, the dotenv-subset parser and the name deny-list.

- Determinism and replay: property-based tests kill the executor at every point of the journal and check that after replay the graph and the results are identical to a run without failures; separate `script_nondeterminism` tests.

- Contract: OpenAPI backward compatibility, the Protobuf protocol N/N-1, plugin conformance, SCM webhook fixtures, common Protobuf test vectors shared with Go and Python.

- Integration (on kind, k3d or a real cluster): rqlite/S3/Vault/Kubernetes/VictoriaLogs and vlagent, network loss, duplicate events, expired leases, job controller reconnection and Pod reconciliation, re-creation of a Pod with the same name, a rqlite leader change during step queuing, a write block during a snapshot, RWX and RWO storage, routing of `/<org>/` to two shards and `organization_not_found`.

- End-to-end: push/PR/manual/schedule, matrices, artifacts, cache trust boundaries, approval, deploy and rollback, permalinks for every entity.

- Security: SAST/SCA/container/IaC scans, a secret-leak corpus (including the path through an iframe), SSRF, webhook replay, a corpus of Lua sandbox escapes, fuzzing of the host API and parsers, a plugin sandbox escape review, a penetration test.

- Resilience: Pod kills (including the job controller and the step Pod), node drain, PVC provisioning failure, DB failover, object storage throttling, restart and failure of a VictoriaLogs node (reads switch to the second, the vlagent queue catches up without losses or duplicates), stopping both nodes (checking that the launch gate closes and opens), vlagent queue overflow, loss of a VictoriaLogs node volume (automatic recovery by copying a snapshot or from a backup), collector unavailability during a step, clock skew, partial region failure, stopping one shard.

- Performance: step queuing and Pod start latency (RUN-013), a webhook burst, the load of one shard and of 10 shards, 5 MiB/s of logs per job, window queries on 100 million lines, streamed download of a large log, replay of a 10 000-record journal, million-run listing with cursor pagination.

- Soak and memory: a 72-hour run, RSS growth, LeakSanitizer on the integration suite (including the shim and the job controller), checks of the executor's and collector's memory limits.

- Client memory: an end-to-end suite in Chromium measures the JS heap, the DOM and the response size of the reference pages and compares them with the UI-008 budget; the main scenarios are also tested without JS.

- Upgrade: every supported previous version to the current one with a real-sized anonymized DB; rollback within the compatibility window.

# 19 MVP acceptance criteria

1. Exactly one run is created from a GitHub/GitLab push or pull/merge request; a repeated webhook does not duplicate it.

2. A script with 1000 `ci.job` calls and a matrix passes preflight in under 2 seconds p95 (NFR-014); parameter type errors and statically computable matrix overruns give a clear error before queuing, and dynamic limit overruns (PIP-006) end the run in a controlled way with the limit's code.

3. With 500 concurrent steps and free cluster resources the queue latency meets NFR-003; no step is executed by two Pods at once after a race, a channel retry or a controller reconnection (a deterministic Pod name, fencing).

4. Shutting down the scheduler/API pod and killing the pipeline executor at any point do not lose queued/running state: replay restores the script position without re-executing completed calls and without manual database edits.

5. A secret from Vault is available only to the permitted step and is absent from the API, the audit, artifacts, the run journal, the Lua state, VictoriaLogs and the verification log corpus; the ephemeral Secret is deleted with the Pod.

6. A fork PR gets no protected variables, no OIDC production claims and no trusted cache namespace.

7. Cancellation, retry and timeout follow the state machine and leave no Pod, PVC or Secret after the cleanup SLA.

8. JUnit shows suites/cases/failures/durations, a comparison with the default branch and flaky history.

9. Artifact upload/download verifies SHA-256; an expired link does not work; the project ACL applies.

10. A production environment requires the configured approvers and a branch policy; a deployment records an immutable artifact digest.

11. The platform installed on two different Kubernetes clusters (for example kind and a managed cluster) passes the same normative conformance suite, including with RWX and RWO storage.

12. OpenAPI/CLI cover all the main UI actions; browser automation confirms Firefox/Chrome, keyboard navigation and the main scenarios without JS (except live updates and the iframe log viewer).

13. A rqlite backup is restored into a clean cluster within RPO/RTO; audit chain verification succeeds; a VictoriaLogs node with a lost disk is restored automatically (a snapshot copy from the second node or a verified log backup) and catches up the vlagent queue within the logs' RPO (NFR-007).

14. Helm install/upgrade passes on two supported Kubernetes minor versions; the documented rollback works.

15. The 10 MVP extensions (4.1) have a schema, a signed immutable release, a permissions manifest, documentation and integration tests; the other 10 extensions are an exit criterion of stage 3.

16. A 72 h soak (NFR-013) passes for the shard services, the executor, the job controller, the log collector and the shim; LeakSanitizer reports no leaks.

17. A request to the log viewer without a token or with an expired token is refused; VictoriaLogs is unreachable from outside; the log store and the vlagent queue hold no unmasked secrets from the verification corpus.

18. The corpus of escapes and attempts at non-determinism (access to `io`/`os`, `pairs` over table keys, reading addresses, an infinite loop, allocation beyond the limit) is rejected or ends with a controlled error.

19. For every entity and anchor of UI-001, opening the link in a new session gives the same screen (an automated test).

20. Two consecutive steps of one job and a step of a parallel branch see a common `/cicd/workspace`; a value from `$CICD_OUTPUT` is available to the script as `r.outputs` and is reproduced on replay; names from the deny-list, limit overruns and a secret in a value are rejected with the codes `env_rejected` and `secret_in_output` (STO-003, STO-004, SEC-011).

21. A log of 100 million lines opens as a window at a given line and at a found match (window <= 500 lines, p95 <= 300 ms; measured about 10 ms); the full log is served only by the "download" button as a stream with a gateway buffer <= 4 MiB regardless of size; when the collector is unavailable during a step no lines are lost (RUN-007); the failure of one VictoriaLogs node affects neither ingest nor viewing (reads switch to the second node, DAT-010, DAT-011, NFR-015); the unavailability of the shard core (scheduler, log collector, log-circuit module) means the unavailability of the shard, there is no degraded mode (SHD-005).

22. Two shards work independently: the ingress sends `/<org>/` to the shard that holds the organisation, a request for an organisation the shard does not hold gets `organization_not_found`; stopping one shard does not affect the runs of the other (SHD-001, SHD-002).

23. The reference pages (a run with 1 000 jobs, a log of 100 million lines, a list of 10 000 runs) fit the client memory budget of UI-008 and NFR-016 (JS heap <= 10 MiB, <= 5 MiB for log viewing; an automated test), and the main scenarios work without JS.

24. A step Pod killed at any moment (kill Pod, retry, node loss) is re-created over the same volume and continues without losing the data of the previous steps; at most one active Pod per step (RUN-014, RUN-002).

25. A persistent volume between runs (stage M2): a second run of the same branch does not repeat the checkout and uses the volume's contents; a run from an untrusted ref (a fork) gets only a clean volume and the trusted branch's volume is not available to it; a volume is used by one run at a time (STO-008).

26. When both VictoriaLogs nodes or vlagent are unavailable, new Pods are not created, runs and steps stay queued with the reason `logs_unavailable`, and the interface shows the reason; the gate closes in no more than 10 s; running steps are not interrupted and their log arrives after recovery without losses within the shim's spool; after at least one node returns and stabilizes, launching resumes automatically; after a scheduler restart the gate is closed until the state is received (RUN-015, SHD-005).

27. The rqlite and log backups run on schedule from the scheduler and manually from the single UI section; the log snapshot is taken on a node with no delivery lag and stops neither ingest nor job launching; without a suitable node the backup is postponed with an alert; the policy, history and statuses are visible in the UI and the actions are written to the audit (BKP-001--BKP-003, BKP-006).

28. The loss of one VictoriaLogs node volume leads to automatic recovery by copying a snapshot from the second node (a write pause of the order of seconds), the loss of both nodes to recovery from the newest verified backup, with no administrator action; when records are lost the range is written to the audit and shown in the UI; a backup with the status `bad` is not used (BKP-004).

29. Variables of the four levels and the launch parameters reach a step as ordinary environment variables in the precedence of VAR-004; an invalid variable or parameter is rejected by the UI and the API before the run starts; a retry after a variable was corrected uses the new value; the header of the first step shows the effective values and the digest without secrets (VAR-002--VAR-005).

30. With `audit_store=victorialogs` an audited action appears in the Audit screen and its chain verifies against the anchors; the audit nodes have no delete API; with `audit.on_unavailable=deny` an operation that must be audited is refused with `audit_unavailable` while the audit circuit is down and succeeds after it returns; the loss of an audit node is recovered automatically (AUD-001--AUD-006).

# 20 Main risks and mitigations

| **Risk** | **Likelihood/impact** | **Mitigation** |
|:---|:---|:---|
| Trying to repeat all the features of the leaders | High/critical | A strict MVP; CI core + managed CD; the rest through extension points |
| The Nim ecosystem: no mature gRPC, the Protobuf codec is marked experimental, fewer ready TLS/S3/OIDC libraries | High/high | ZeroMQ with CURVE instead of gRPC (D-24, A.4); thin own implementations of the critical parts; common test vectors; the revisit condition of D-01 |
| Leaks and memory growth (ORC with async, C boundaries) | Medium/high | A 72 h soak, LeakSanitizer, limits, RSS metrics, rule E-003, restart with replay |
| rqlite write throughput | High/high | Batching, moving ephemeral data out, sharding (7.3), benchmarks (A.2) |
| Non-determinism of Lua scripts breaks replay | Medium/high | PIP-005, fingerprint checks, property tests, clear diagnostics |
| Sandbox escape, execution of user code | Low/critical | SEC-007, seccomp, fuzzing, an escape corpus |
| VictoriaLogs (upstream): the only source of truth for logs; no replication inside the store, duplicates on repeated delivery, the vlagent queue as the only place for undelivered lines, retention shared per node | Medium/high | Two independent nodes and vlagent, the window excludes duplicates by `ln`, backups and verification (DAT-010), a bounded queue that closes the launch gate, the LogStore interface allows replacing it, the measurements of A.7; the logs' RPO target Q-13 |
| Node recovery and log snapshots in the core module (delivery pause, copy, queue clean-up) | Medium/medium | The order is verified (A.7, A.11), scenario tests of losing one node and both nodes, the write pause is measured at 100 million lines |
| Log ingest and scheduling in one core process: the log load can delay scheduling | Medium/high | Separate threads and memory limits for the modules, a benchmark, and if necessary moving log ingest into its own process (7) |
| A log-circuit failure stops all job launches, including emergency rollbacks | Medium/high | Two nodes, delivery through vlagent, backups, monitoring of the gate closing, open question Q-16 on an emergency bypass |
| Failure or growth of the vlagent queue (disk, overflow) | Medium/high | The `maxDiskUsagePerURL` limit, the queue metric, an alert and closing the launch gate before overflow (RUN-015, `gate_max_pending`), a separate volume |
| Incompatible plugins | High/high | A file contract and out-of-process execution, conformance, N/N-1, digest pinning |
| Secret leaks | Medium/critical | Trust boundaries, short-lived identity, masking in the shim (D-31), ephemeral Secrets, security tests |
| Scheduler bottleneck | Medium/high | A profile's queue belongs to one instance, sharding, benchmarks from the start |
| Pipeline scripts become unmaintainable (the freedom of imperative code) | High/medium | SemVer libraries, `cicd pipeline check`, limits, templates, typed parameters, IDE annotations |
| Kubernetes only: no Windows, macOS, bare metal or Compose | Medium/high | A product decision (D-14); Linux-only conformance; the limitation is recorded in 4.2 |
| A Pod per step slows short pipelines | High/medium | RUN-013, preloading the shim image, coarser steps (multi-line `j.sh`), session mode (7.4) under SES-001 |
| Shared storage: RWX unavailable or slow, RWO limits parallelism | Medium/high | Execution profiles, affinity for RWO, open question Q-11 |
| Load on the Kubernetes API from a Pod per step and the lack of a mature client in Nim | Medium/high | A watch with `resourceVersion` instead of polling, quotas and limits on creation, the official C client behind a thin binding (D-26, A.6) |
| A UI without an SPA does not give the needed interactivity | Medium/medium | HTMX and SSE, extension points through iframes, the client memory budget UI-008, acceptance without JS |
| Migration of arbitrary Jenkins Groovy | High/high | No promise of 100%; a report, compatibility steps, shadow execution |

# 21 Open points

These points are resolved by configuration or by a later product decision. The column "Current position" is the value the design assumes until then.

| **ID** | **Question** | **Current position** |
|:---|:---|:---|
| Q-01 | Product licence; compatibility of the licences of rqlite, Lua, VictoriaLogs and vlagent (Apache-2.0) and the other dependencies | MIT for the platform; a dependency licence check is part of release preparation |
| Q-02 | Delivery model of the control plane | Fully self-hosted in the first version; a hosted control plane must not dictate the job controller's protocol |
| Q-03 | Product name, API group and namespace; after publication `apiVersion` becomes a long-term contract | The working name `cicd.example.io` |
| Q-04 | Supported versions of Kubernetes, rqlite, Nim and the C toolchain, operating systems; the length of the support window | The two latest Kubernetes minor versions; the other versions are pinned in the build files. ValidatingAdmissionPolicy (stable since 1.30) is required by SHD-007; on older clusters the operator can turn it off at their own risk |
| Q-05 | The set of 10 first-party MVP extensions (4.1) | The set from 4.1 |
| Q-06 | Whether WASM extensions are allowed in the MVP | No, OCI only |
| Q-07 | Policy engine: Lua policies or a mandatory OPA/Rego | Lua policies; OPA is an optional adapter |
| Q-08 | The format of the external API and manifests: REST/JSON and JSON manifests, or Protobuf/gRPC for the external API | REST/JSON and JSON manifests |
| Q-09 | The target load of the first commercial installation | One shard; its capacity is set by measurement (NFR-006), a second shard is added under SHD-003 |
| Q-10 | The update policy for VictoriaLogs, vlagent and vmauth versions (pinned versions, a data-format compatibility check on upgrade) | A pinned version, updated quarterly with a recovery test |
| Q-11 | Which StorageClasses are available in target clusters: whether `ReadWriteMany` exists; whether persistent volumes between runs (STO-008) and volume snapshots for restart from a stage (STO-006) are acceptable | RWX preferred; without it RWO with the run's Pods pinned to a node; persistent volumes from stage M2; snapshots off |
| Q-12 | Moving an organisation between shards: whether an online transfer is needed (SHD-003) | Offline transfer in the MVP, online in stage M4 if needed |
| Q-13 | The log storage topology: two VictoriaLogs nodes and vlagent as the minimum pair (a single node is not supported), the backup interval, the logs' RPO target and whether an archive of finished logs in S3 is needed (DAT-010) | Two nodes, an hourly log backup, RPO close to zero when a node is lost and no more than 1 h when both are lost; the archive is off |
| Q-14 | The start-up acceleration model: a Pod per step, repeated Pod starts over a persistent volume (RUN-014, STO-008), session mode (7.4) only if SES-001 is met | A Pod per step with volumes as in 7.4; session mode is not developed because condition (a) of SES-001 is not met in the measured environment (A.6); the RUN-013 target is p95 <= 10 s |
| Q-15 | Whether separate subdomains for iframes (`logs.`, `x.`) and a wildcard certificate are acceptable in target installations | Yes |
| Q-16 | Whether an emergency bypass of the launch ban is needed when the log circuit is unavailable (for example a production rollback): a limited break-glass for the Platform admin with audit, during which the step's log accumulates in the shim's spool and is sent after recovery | No bypass, the ban always applies (RUN-015) |
| Q-17 | How image builds run (RUN-012, A.13): a build profile with its own namespace under Pod Security `baseline`, a `Localhost` seccomp profile that allows user namespaces (to be installed on the nodes and measured; `Unconfined` worked) and user namespaces enabled on the nodes (`user.max_user_namespaces`), with rootless BuildKit or Buildah; or Kaniko in that namespace (works without the sysctl and the seccomp profile); or a privileged builder outside the organisation namespaces | Open; measure the `Localhost` profile and choose the tool |

## A.13 Container image builds in a restricted namespace

Measured on the TESTING cluster (Talos, Kubernetes 1.34, containerd 2.1, kernel 6.12) in a namespace made by the core for an organisation (SHD-007: Pod Security `restricted`, default-deny network policy with only the registry opened for the test, quota and limit range), and in two namespaces made for comparison with Pod Security `baseline` and `privileged`. The build is a three-line Dockerfile (a `RUN` that adds a user, a `COPY`) from a base image and to a registry inside the cluster.

The nodes have `user.max_user_namespaces = 0` (Talos default). A Pod with `hostUsers: false` therefore does not start (the sandbox cannot be created), and nothing that needs a user namespace works, which is the error that rootless BuildKit reports (`[rootlesskit:parent] /proc/sys/user/max_user_namespaces needs to be set to non-zero`, `fork/exec /proc/self/exe: operation not permitted`).

| Tool and way of running | Namespace policy | Result | Why |
|:---|:---|:---|:---|
| BuildKit rootless (`moby/buildkit:rootless`, `--oci-worker-no-process-sandbox`), user 1000 | `restricted` | fails | rootlesskit needs a user namespace |
| Buildah, user 1000, `vfs`, `chroot` isolation | `restricted` | fails | `unshare(CLONE_NEWUSER)`: user namespaces are off |
| Kaniko, user 1000 | `restricted` | fails | `chown /kaniko/Dockerfile: operation not permitted`: Kaniko needs root |
| Kaniko, root, default capabilities | `baseline` | **works** (build and push, only the registry reachable) | no user namespace, no extra capability |
| Buildah, root, default capabilities | `baseline` | fails | without `CAP_SYS_ADMIN` Buildah falls back to a user namespace |
| Buildah, root, `CAP_SYS_ADMIN`, `--ulimit nproc=... --ulimit nofile=...` set to the current values | `privileged` | **works** | `RLIMIT_NPROC` cannot be raised without `CAP_SYS_RESOURCE`, so the limits are passed explicitly |
| BuildKit rootful (`privileged: true`) with an insecure-registry `buildkitd.toml` | `privileged` | **works** | a privileged container |

**After the sysctl was raised.** `user.max_user_namespaces` was set to 11255 on the nodes (the value of the Talos guide). The same builds, in a scratch namespace with Pod Security `privileged` where a setting of the namespace policy was the thing being tested:

| Tool and way of running | Result | Why |
|:---|:---|:---|
| A Pod with `hostUsers: false`, user 1000, `restricted` | starts | the sandbox can be created; inside, `unshare -Ur` fails because the default seccomp profile forbids nested user namespaces |
| The same with `runAsUser: 0` | refused by `restricted` | `restricted` forbids root even when the Pod has a user namespace (Kubernetes 1.34) |
| BuildKit rootless, user 1000, `hostUsers: false`, default seccomp | fails | rootlesskit cannot create its namespace |
| Buildah, user 1000, `hostUsers: false`, default seccomp | fails | `unshare(CLONE_NEWUSER)` is refused by seccomp |
| BuildKit rootless, user 1000, seccomp `Unconfined`, no privilege escalation (as `restricted` demands) | fails | `newuidmap` is a setuid binary and needs privilege escalation and `CAP_SETUID` |
| BuildKit rootless, user 1000, seccomp `Unconfined`, the rest as `baseline` (escalation allowed, default capabilities) | **works** | |
| Buildah rootless, user 1000, seccomp `Unconfined`, the rest as `baseline` | **works** | |
| Buildah, root in a `hostUsers: false` Pod, seccomp `Unconfined`, default capabilities | **works** | root of the Pod's own user namespace maps the ids itself |
| BuildKit rootful in a `hostUsers: false` Pod, root, seccomp `Unconfined`, `CAP_SYS_ADMIN` (not `privileged`) | **works**; without `CAP_SYS_ADMIN` it fails at `mount` | the capability is scoped to the Pod's user namespace |
| Buildah, user 1000, `restricted`-style settings, seccomp `Unconfined`, single id mapping with `ignore_chown_errors` | fails | the image is pulled, the `RUN` step fails with `error setting supplemental groups list` (needs `CAP_SETGID`) |

What follows. (1) No tool runs in the `restricted` namespace of an organisation, with or without user namespaces on the nodes: the rootless tools need `newuidmap` (a setuid binary with `CAP_SETUID`/`CAP_SETGID`) or root in the Pod, and `restricted` forbids both. The statement of RUN-012 (a rootless buildkitd in the organisation's namespace) therefore holds only for a namespace with a weaker policy. (2) The weakest policy that worked is `baseline` plus a seccomp profile that allows the user-namespace calls: rootless BuildKit and rootless Buildah run as user 1000 without any added capability and without `privileged`. `baseline` forbids `Unconfined`; a `Localhost` seccomp profile is allowed, but it has to exist as a file on every node, and it was not measured (`Unconfined` was used as its upper bound). (3) Kaniko needs only `baseline` (root, default capabilities, default seccomp) and works with the cluster as it was; it needs no sysctl. (4) Rootful BuildKit and Buildah with `CAP_SYS_ADMIN` or `privileged` need a `privileged` namespace, which contradicts SEC-012 for namespaces that hold untrusted pipelines. (5) A build step needs an egress allowance to the registry that holds the base image and receives the result, beyond the default-deny policy (SEC-003: allow rules by project policy); the measurement used exactly one rule, the registry's port. Which way the platform takes is open question Q-17: a build profile (an execution profile with its own namespace, `baseline`, a seccomp profile and the registry allowance) with Kaniko or a rootless builder.

# 22 Sources

The sources for systems 11--20 and for the choice of the stack were checked on the level of the documentation overview pages; details marked `[verify]` are not confirmed by them. The facts about VictoriaLogs come from its documentation (cluster, vlagent, snapshots, deletion) and the flags of the v1.52.0 binary, and are confirmed by the measurements of Appendix A.7. The links to the Kubernetes and htmx documentation are pointers for implementation: the statements tied to them in sections 6--7 and 11 (volume access modes, the projected token, Leases, the limits of ephemeral containers) are confirmed by the measurements of Appendix A.6.

- TeamCity Documentation: https://www.jetbrains.com/help/teamcity/teamcity-documentation.html

- Jenkins Pipeline: https://www.jenkins.io/doc/book/pipeline/

- GitHub Actions Documentation: https://docs.github.com/en/actions

- GitLab CI/CD Documentation: https://docs.gitlab.com/ci/

- Azure Pipelines Documentation: https://learn.microsoft.com/en-us/azure/devops/pipelines/

- CircleCI Documentation: https://circleci.com/docs/

- Travis CI Documentation: https://docs.travis-ci.com/

- Buildkite Documentation: https://buildkite.com/docs

- Tekton Documentation: https://tekton.dev/docs/

- Woodpecker CI Documentation: https://woodpecker-ci.org/docs/intro

- Argo Workflows Documentation: https://argo-workflows.readthedocs.io/en/latest/

- Argo CD Documentation: https://argo-cd.readthedocs.io/en/stable/

- Drone Documentation: https://docs.drone.io/

- Bamboo, End of support announcements (Atlassian): https://confluence.atlassian.com/spaces/BAMBOO/pages/289276775/End+of+support+announcements+for+Bamboo

- Bamboo End of Life (JetBrains Blog, June 2026): https://blog.jetbrains.com/teamcity/2026/06/bamboo-end-of-life/

- Spinnaker Documentation: https://spinnaker.io/docs/

- Harness Developer Hub: https://developer.harness.io/

- Semaphore Documentation: https://docs.semaphore.io/

- Bitbucket Pipelines: https://support.atlassian.com/bitbucket-cloud/docs/get-started-with-bitbucket-pipelines/

- AWS CodePipeline User Guide: https://docs.aws.amazon.com/codepipeline/latest/userguide/welcome.html

- Concourse CI Documentation: https://concourse-ci.org/docs/

- Dagger Documentation: https://docs.dagger.io/

- rqlite, Performance guide: https://rqlite.io/docs/guides/performance/

- rqlite, Queued Writes: https://rqlite.io/docs/api/queued-writes/

- VictoriaLogs documentation: https://docs.victoriametrics.com/victorialogs/

- VictoriaLogs Cluster (no replication; HA through independent instances): https://docs.victoriametrics.com/victorialogs/cluster/

- vlagent (buffering and delivery to several nodes): https://docs.victoriametrics.com/victorialogs/vlagent/

- VictoriaLogs releases: https://github.com/VictoriaMetrics/VictoriaLogs/releases

- Nim, Memory Management: https://nim-lang.org/docs/mm.html

- Nim issue 15076, leaks with async under ORC: https://github.com/nim-lang/Nim/issues/15076

- ZeroMQ: https://zeromq.org/ and the CURVE mechanism: https://rfc.zeromq.org/spec/25/

- GuildenStern: https://github.com/olliNiinivaara/GuildenStern

- Kubernetes C client: https://github.com/kubernetes-client/c

- nim-protobuf-serialization: https://github.com/status-im/nim-protobuf-serialization

- Kubernetes, Pods: https://kubernetes.io/docs/concepts/workloads/pods/

- Kubernetes, Ephemeral Containers: https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/

- Kubernetes, Persistent Volumes (access modes, VolumeSnapshot): https://kubernetes.io/docs/concepts/storage/persistent-volumes/

- Kubernetes, Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/

- Kubernetes, Leases: https://kubernetes.io/docs/concepts/architecture/leases/

- Kubernetes, Configure Service Accounts (projected token): https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/

- htmx Documentation: https://htmx.org/docs/

- OpenTelemetry Specification: https://opentelemetry.io/docs/specs/

- SLSA Specification: https://slsa.dev/spec/

- OCI Image Specification: https://github.com/opencontainers/image-spec

- Sigstore Documentation: https://docs.sigstore.dev/

# Appendix A. Design rationale and measurements

This appendix holds the evidence behind the decision log (the decisions that rest on measurements). Every number was measured on the stack described in the decision; where a measurement was taken on a different setup, that is said.

## A.1 Method and environment

- **Test cluster.** Kubernetes 1.34 (Talos), 3 control-plane and 3 worker nodes, node-local storage (`ReadWriteOnce`, `WaitForFirstConsumer`), no `ReadWriteMany`. The cluster is shared and noisy; absolute latencies are therefore pessimistic and relative comparisons are reliable. Components are installed from their official Helm charts.
- **Dedicated host.** A 4-core host next to the cluster is used for long runs (soak tests) and for the core process when step Pods must reach it.
- **Local runs.** Log-store and HTTP-server comparisons ran locally in containers, one candidate at a time, on the same generated CI-like log lines.
- **Rules.** Every number is a median of repeated runs unless stated; a probe that shows "growth" is first checked for a bug of its own (a leaking probe produced a false 12.8 KiB per connection once).

## A.2 State store: rqlite

Setup: rqlite 10.x, 3 nodes, persistent volumes. The queue query is `UPDATE … WHERE id=(SELECT … LIMIT 1) … RETURNING` (section 7.2).

| Check | Result |
|:---|:---|
| Claiming a step, 300 steps, 8 concurrent clients | Every step received exactly once, no double claim |
| `CAS WHERE version=?` | Of two racing writes exactly one wins |
| Transaction "state + journal batch" | Atomic: an error in the last statement rolls back the whole batch |
| Batching | 500 rows per request: about 4 000 rows/s against about 15 single writes/s through a port-forward (about 260×); inside the cluster a 500-row batch reaches 14 800 rows/s |
| Single write latency | about 40 ms on the leader, 70 ms through a follower |
| VACUUM of about 20 MB under continuous writes | Writes block: worst stall 1.1--2.6 s, p50 50--100 ms |
| Killing the leader during writes | 35 runs, 0 lost acknowledged writes; write unavailability 0.13--1.6 s, median 0.24 s |

Findings that became rules: (1) rqlite answers HTTP 200 with `{"error":"leadership transfer in progress"}` on a leader change, so the client must check the top-level `error` and the `error` of every result; (2) `rows_affected` is absent from the JSON when it is 0; (3) single-row claiming gives about 60 claims/s, so the scheduler claims a batch with one `UPDATE … LIMIT n RETURNING`; (4) VACUUM and snapshots stall writes for seconds and are scheduled outside peaks, and only state is kept in rqlite.

**Comparison with Percona XtraDB Cluster** (PXC 8.4, Galera, HAProxy; three nodes each, measured from a Pod inside the cluster, the same Python client; MySQL has no `RETURNING`, so PXC uses `SELECT … FOR UPDATE SKIP LOCKED` + `UPDATE`):

| Check | rqlite | PXC |
|:---|:---|:---|
| Claim of 300 steps, 8 clients | 45/s | 4--5/s (12/s through a stored procedure) |
| Single write p50 / p95 | 6.3 / 89.7 ms | 5.9 / 398.8 ms |
| Batch insert of 500 rows | 14 778 rows/s | 38 249 rows/s |
| 500 rows inserted one by one | 37/s | 8/s |
| Node failure during writes | 0 lost, 1.49 s gap | 0 lost, 6.20 s gap |
| Memory of the process, three nodes at idle | about 90 MiB in total | about 1.7 GiB in total |
| Disk, same data | 108 MiB | 400 MiB |

Against PXC rqlite is 4--10× faster on the dominant write pattern (frequent claims of single steps), recovers four times faster and is an order of magnitude lighter; the strength of PXC (batch inserts) is not the scheduler's pattern. The single-shard scaling ladder of section 7.3 (batching, then a smaller shard) stands.

**Comparison with PostgreSQL** (CloudNativePG 1.30, PostgreSQL 16.15, three instances with 200m CPU and 900 MiB each, `shared_buffers` 128 MB, quorum synchronous replication `ANY 1` with required data durability, writes through the `-rw` service; rqlite as above through its ClusterIP service). Measured later, in the same session and from the same client Pod, in interleaved runs; the test cluster is shared and noisy, so the table gives the median of three runs and, in brackets, the range. PostgreSQL, like rqlite, can claim a step in one statement (`UPDATE … WHERE id = (SELECT … FOR UPDATE SKIP LOCKED) RETURNING id`); the three-step form is measured too.

| Check | rqlite | PostgreSQL |
|:---|:---|:---|
| Claim of 300 steps, 8 clients, one statement | 46/s (28--52) | 118/s (57--119) |
| The same, `SELECT … FOR UPDATE SKIP LOCKED` + `UPDATE` in a transaction | — | 98/s (57--98) |
| Single write p50 / p95 | 21.8 / 82.7 ms (16.9--26.1 / 81.0--84.8) | 47.9 / 128.6 ms (10.7--78.2 / 16.0--131.1) |
| Batch insert of 500 rows in one statement | 5 022 rows/s (2 808--24 262) | 22 349 rows/s (2 185--26 549) |
| 500 rows inserted one by one | 32/s (32--33) | 84/s (28--86) |
| Exactly one winner in 100 CAS races | yes | yes |
| Primary/leader killed during writes: acknowledged writes lost | 0 (five runs) | 0 (six runs) |
| The same: writes unavailable | 0.17--0.21 s (three runs) | 27.6, 31.7 and 33.1 s (default operator settings) |
| Memory of the processes, three nodes | about 33 MiB in total | about 130 MiB in total |
| Disk per node | about 108 MiB | about 255 MiB (preallocated WAL included) |

PostgreSQL claims steps faster than rqlite when the clients contend (about 2.5×), and inserts batches about four times faster; its single-write latency is no better and noisier. The decisive differences are elsewhere: after the primary is killed, writes were unavailable for about half a minute with the operator's default failover settings (rqlite: a fifth of a second), the three processes take about four times the memory, and a PostgreSQL shard needs an operator and its own backup tooling where rqlite is one binary with built-in S3 backup (A.11). A tuned failover would shorten the gap but is not shown here. The conclusion of D-02 stands; PostgreSQL is the named alternative if rqlite fails the single-shard targets of NFR-006.

## A.3 Lua executor, journal and contracts

- Lua 5.4.8 is vendored and compiled from Nim; the sources of `io`, `os`, `debug`, `package` are not part of the build. Open libraries: `base`, `table`, `string`, `utf8`, `math`, `coroutine`. The string hash seed is fixed. Limits come from a custom allocator (memory) and a count hook (instructions); once exceeded the hook fires on every instruction so that `pcall` cannot hold the loop, and the exceeded flags are sticky, so the limit's code is returned even if the script caught the error.
- The journal is append-only, `(seq, kind, payload, result, hash)` with SHA-256 over the previous hash and the length-prefixed fields; any edit is found by `verify`. Hashes are computed over canonical JSON of `payload` and `result`, not over Protobuf bytes, because field order on the wire differs between the Nim codec and `protoc`.
- Replay: scripts run in a coroutine; the host-calling functions yield, and the driver takes the result from the journal or calls the host and appends a record. A mismatch gives `script_nondeterminism` with the sequence number, the expected and the actual call.
- Result: killing the executor at each of 7 journal points, before and after the side effect, gives a result and a journal (including hashes) identical to a clean run; the same with a real `_exit(9)` of a child process; replay of 10 000 records is within 2 s (NFR-014).
- Finding: `lua_error` raised from a Nim hook jumps through a Nim frame without removing the trace frame (AddressSanitizer reports `stack-use-after-return`). The hook is compiled with `stackTrace: off, lineTrace: off`; code that calls `lua_error` must hold no trace frames or objects with destructors.
- **Protobuf codec** (`protobuf_serialization`, marked experimental): encoding is byte-identical with the reference implementation for scalars, negative int32, nested messages, packed repeated, enums, oneof and maps; unknown fields of a future version are skipped (N/N-1); truncated and garbage input does not crash. The recursive `google.protobuf.Struct` does not compile in the Nim codec, so for Nim the plugin contract carries Struct fields as `bytes` with the same field numbers (identical on the wire). The `.proto` files pass `buf lint`, and `buf breaking` against the previous release's image catches field removal, type and number changes, enum and message removal.
- **Template engine.** `nimja` compiles templates at build time (about 10 µs for a 100-row page) and does not escape HTML automatically; `mustache` escapes by default but renders the same page in 2.5 ms (250× slower). The choice is `nimja` with mandatory explicit `h(...)` (escape) or `raw(...)` (trusted HTML), enforced by a test that fails the build on any expression outside them.
- **State machines.** Transition tables for run, step, launch gate and input live in one module; the documentation is generated from them and tests check that terminal states are final, every state is reachable, and any non-terminal state can be cancelled and finished.

## A.4 Transport between services

The candidates were measured in one topology (server and client on different worker nodes, a real node-to-node network, the same certificates), reference values:

| Metric | ZeroMQ + CURVE | NNG + mTLS | MQTT (Mosquitto + Paho) | NATS + JetStream |
|:---|:---|:---|:---|:---|
| Client RSS after connect | 4.9 MiB | 3.3 MiB (1.3 MiB static musl) | 6.9--7.0 MiB | 7.0 MiB |
| Server side RSS | 5.3 MiB | 5.1 MiB | 6.8 MiB + broker 8.0 MiB | 19.2 MiB (with JetStream) |
| Request/reply | **2 005/s** | 1 254--1 299/s | 1 869--2 025/s (through topics) | 719/s |
| Stream of 256 MiB | **258 MiB/s** | 63--65 MiB/s | 108--211 MiB/s | 310--326 MiB/s |
| 1 000 connect/close cycles with encryption | fast (the whole run 11.8 s) | about 24 ms per cycle | about 260 ms per cycle | about 13 ms per cycle |
| Memory after 5 000 connect/close | flat | flat | flat | flat |
| Broker on the hot path | no | no | **yes** | **yes** |

Other candidates: the HTTP/2 server on Nim (`hyperx`) leaks about 830 B per connection in release (8.1 KiB in debug) because of exceptions raised and caught inside async procedures under ORC; gRPC C-core is correct and fast (477 MiB/s) but a client takes 15.8 MiB RSS after the first call (52 shared libraries, glibc only, no static build), which exceeds the shim's budget. On loopback ZeroMQ reached 18 697 requests/s and 923 MiB/s.

Decisions that follow (D-24): ZeroMQ REQ/REP with CURVE; the client relaxes and correlates REQ (`REQ_RELAXED` + `REQ_CORRELATE`) so that a request that timed out can be repeated and a late reply is dropped. A message is one Protobuf message. CURVE has no certificate authority or revocation, so identities are key pairs issued at registration (IAM-003); the server accepts the known client key and clients pin the server's public key. libzmq must be built with libsodium (a build without it silently has no CURVE). Sockets are bound to a thread, so each service uses blocking sockets in dedicated threads. The Nim binding (`nim-zmq`) loads libzmq at run time; CURVE support and the correct width of integer socket options were contributed upstream. The static shim links libzmq and libsodium in (0.49 MB with UPX, 1.4 MB without) and fits a ConfigMap.

## A.5 HTTP layer

Servers were compared on the same routes (a 100-row page as a chunked stream, a handler exception, a streamed N MiB response, SSE) and the same load (k6):

| Metric | civetweb 1.16 (C) | GuildenStern 9.0 (pure Nim, after patches) | Mongoose 7.23 (C) | mummy / httpbeast (Nim) |
|:---|:---|:---|:---|:---|
| Idle RSS | 2.2 MiB | 3.2 MiB (8 workers) / 11.1 MiB (64 workers) | 1.6 MiB | 2.5 / 2.2 MiB |
| Growth after 20 000 keep-alive requests | +0.6 MiB, then flat | +1.5 MiB, then flat | +0.1 MiB | +0.7 MiB / not measured |
| 20 000 handler errors | no crash | no crash | no crash | httpbeast: process exits |
| Streaming response, SSE, back-pressure | yes | yes (after patch) | yes | mummy: no streaming; httpbeast: no back-pressure |
| 128 MiB to a 2 MB/s reader | 62.1 s, flat 3 MiB | 63.7 s, flat 11.5 MiB | 62.6 s, flat 1.9 MiB | — |
| Requests/s, 100-row page, 10 clients | 10 244 | 20 471 | 10 472 | — |

GuildenStern is chosen: no C pointer or foreign handle in handler code, the compiler refuses a handler that may raise (`raises: []`), memory is flat, and its licence is MIT without obligations on the binary (Mongoose is on par but GPL/commercial). Two patches are vendored: the byte counter of chunked replies was corrupted under back-pressure, and the final chunk was sent with `MSG_MORE`, delaying every response by about 200 ms. `threadpoolsize` is a hard ceiling of concurrent requests (one worker serves one connection), so it is sized by expected concurrency.

## A.6 Kubernetes: client, Pod start latency, storage

**Client.** There is no mature Kubernetes client for Nim. The official C client (`kubernetes-client/c`) is used through its generic JSON API with a thin Nim binding. A thin client built on `std/httpclient` was compared on the same load (7 cluster-wide list calls, 30 cycles):

| Variant | RSS (MiB): start, cycle 1, 10, 30 | Cycle time |
|:---|:---|:---|
| Thin client, a new `HttpClient` and `SslContext` per request | 5.6 → 13.5 → 18.1 → 21.5, grows about 170 KiB per cycle | 1.6--2.7 s |
| Thin client, one shared `HttpClient` | 5.6 → 13.5 → 16.4 → 16.4 | 0.32 s |
| C client as is | 6.6 → 10.8 → 12.0 → 12.0 | 1.3--1.6 s |
| C client with the shared connection cache | 6.8 → 10.8 → 11.9 → 11.9 | 0.42--0.56 s |

`std/httpclient` cannot read a body as a stream, so a watch with `resourceVersion` cannot work in real time with it; the controller needs the C client, always with the connection cache enabled and one API client per thread. The C client has no request timeout by default (a watch once hung for 8.5 minutes): timeouts are set through its pre-invoke hook. Nim tables and strings must not be shared between threads under ORC (only plain structures under a lock).

**Behaviour verified on Pods, PVCs, Secrets and Leases:** re-creation of a Pod with the same deterministic name gives `409 AlreadyExists`; a watch resumes from `resourceVersion` and delivers exactly the missed events; the server closes a watch after `timeoutSeconds`; a Lease update with a stale `resourceVersion` is rejected with `409` (fencing); a Secret with an `ownerReference` to the Pod is removed with it; a run's `ReadWriteOnce` volume lets the next step's Pod read the previous step's file, and the scheduler places the Pod on the volume's node; a Pod forced to another node stays `Pending`. The projected token has `aud=["cicd-shard"]`, TTL 600 s, RS256 signed and bound to the Pod's name and uid; a forged Pod name or a foreign audience is rejected by independent verification. Deleting a namespace with 150 finished Pods takes about a minute, so cleanup is asynchronous. Memory of the controller: 9.3 MiB after connecting, 11.3 MiB with 200 watched Pods (about 10 KB per Pod).

**Pod start latency** (from the create call to the container reported running; warm image, restricted profile):

| Series | p50 | p95 |
|:---|:---|:---|
| Sequential | 0.9 / 1.7 / 1.7 s | 1.8 / 2.9 / 7.0 s |
| Batch of 50 Pods | 8.4--8.7 s | 11.2--11.8 s |
| Sequential with an init container delivering the shim | 2.8 s | 6.1--6.6 s |
| Sequential with `nodeName` preset | 1.6 s | 3.6 s |

Creation to assignment takes 0.15--0.25 s (the scheduler is not the bottleneck); the time is in the kubelet, with a tail up to 7 s, and the status reaches the API about 1.2 s after the process starts. Volume reuse, persistent volumes and image preloading do not shorten the kubelet time in this environment. The shim is delivered by mounting a ConfigMap (limit 1 MiB), not an init container (which adds about 1 s to the median and a heavy tail). A cold shim image takes about 8 s. The RUN-013 target of p95 ≤ 10 s is met; batch starts and weaker clusters are to be re-measured, hence the condition for session mode (SES-001).

**Shim.** The static musl shim is 150 KiB without logging (0.49 MB with the ZeroMQ log client) and about 1.8 MiB RSS; the termination message holds the result (≤ 4 KiB), the exit code is passed through, `env_rejected` is exit code 70, and the env file is visible to the next Pod through the shared volume. The env-file parser (12 tests) rejects comment lines, single quotes and `\r` escapes, and its deny-list covers interpreter and loader variables (`PYTHONHOME`, `NODE_PATH`, `RUBYOPT`, `PERL5OPT`, `JAVA_TOOL_OPTIONS`, `GLIBC_*`, `DYLD_*`, `BASH_FUNC_*`, `PS4`, `PROMPT_COMMAND` and others).

## A.7 Log store

Five million CI-like lines (459 MiB of text, 5 jobs of 1 million lines), one candidate at a time, the driver being the limit of ingest:

| | VictoriaLogs | Quickwit | ClickHouse | Loki |
|:---|:---|:---|:---|:---|
| Disk relative to text | **0.39×** | 2.0× | 2.1× | 1.7× |
| Memory at idle after ingest | 427 MiB | 530 MiB | 787 MiB | 561 MiB |
| Window of 200 lines p50 / p95 | 6.0 / 11 ms | 48 / 63 ms | 7.5 / 8.3 ms | 21.5 / 29 ms |
| Frequent word, first 200 in a job | 8 ms | 74 ms | 10 ms | 23 ms |
| Rare token in a job of 1 M lines | 47 ms | 73 ms | 47 ms | 1.5 s |
| Visible after ingest | about 2 s | about 10 s | immediately | only after flush |
| Licence | Apache-2.0 | Apache-2.0 | Apache-2.0 | AGPL-3.0 |

Raw outputs are in `docs/evidence/`. VictoriaLogs is a single Go binary with built-in search and multi-tenancy; Elasticsearch-class engines were excluded by their memory use.

**VictoriaLogs at 100 million lines on one node:** ingest about 1 million lines/s (about 100 MiB/s); disk 3 563 MiB for 9.2 GiB of text (0.39×); window of 200 lines p50 6.8 ms, p95 9.7 ms, max 32 ms; window of 500 lines p95 10.1 ms; first 200 matches of a frequent word in a 1 M-line stream 10 ms; a rare token in a stream / across all 100 M lines 105 ms / 586 ms; counting a frequent word 270 ms / 2.0 s; memory 2.0 GiB after ingest, 1.4 GiB after queries; first query after a restart in 0.5 s; lines visible after ingest in about 1--2 s. Tenants (`AccountID`) are isolated; deleting all lines of a tenant takes 0.5 s, deleting one 1 M-line stream among 100 M lines 8.1 s.

**What the product does and does not do** (documentation and binary flags, v1.52): it has no replication in the store (the cluster mode shards but does not replicate), snapshots are `POST /internal/partition/snapshot/create|list|delete`, deletion is `-delete.enable` and `POST /delete/run_task`, retention (`-retentionPeriod`, `-retention.maxDiskSpaceUsageBytes`) is shared per node, client certificates (mTLS) exist only in the enterprise edition, so TLS plus a login and password protect the chain. High availability is therefore two independent single nodes fed by **vlagent** (a ready agent with a disk buffer per destination) and read through a node chosen by the gateway.

**Two nodes, vlagent (2 million lines per step):** both nodes receive data within 2 s; with node B stopped, writing 2 million lines and starting B again, the counts converge in 6.6 and 18.7 s with no loss and no duplicates (the vlagent buffer empties); with node A killed, reads switch to B with no failed probe; after a lost disk of A (pause of the agent, snapshot of B in 0.02 s, copy in 0.13 s for 143 MiB, clearing A's queue in the agent, start) A starts with all 4 000 000 lines, the write pause totals 1.5 s and the windows on A and B are byte-identical. The order matters: A's vlagent queue must be cleared, otherwise lines that are in both the snapshot and the queue are duplicated (VictoriaLogs does not deduplicate). Live tail: the default `/tail` has p50 5.5 s lag, with `offset=0s` p50 1.5 s (max 2.0 s), a poll query every 50 ms shows a new line within p50 1.0 s (max 2.0 s).

The window key is the line's time with millisecond precision; to keep the order inside one millisecond and to address "by line number" the field `ln` is stored and sorted as `(_time, ln)`, and the shim assigns a monotonic time `base + ln` ms inside a job attempt (DAT-001).

## A.8 Log delivery: spool and blocks

A live vlagent accepts `Content-Encoding: gzip` and `zstd` on `/insert/jsonline`, and several independently compressed blocks glued into one body are read as one stream (2+2 and 3 lines kept whole). A spool is therefore a sequence of independent NDJSON blocks that the core forwards as they are, without decompressing or recompressing. On a CI-like log (100 000 lines, 64 KiB blocks): gzip level 1 gives 12% of the original at 286 MB/s, zstd level 1 10%. A 10 MiB spool is therefore about 80--100 MB of text. The codec is written in each block's header, so a switch to zstd is not a protocol change. gzip level 1 was chosen because it is pure Nim (`zippy`), with no new C code in the static shim.

Layout: the shim assembles records `{"_msg","_time","ln","job","run"}` in blocks of about 64 KiB or once per second, compresses each separately and appends it to the spool (an `emptyDir` whose `sizeLimit` equals the spool size; a block has a header [codec, first `ln`, line count, length, `seq`]). The shim hands blocks to the core over LogIngest in order; the core forwards the body to vlagent with the right `Content-Encoding`, answers after a 2xx (DAT-001), and takes each block once (a repeated block carries the same `seq` and `ln`). A 4xx answer other than 429 marks the block corrupt for good: it is skipped and the stream is marked `corrupt`. When the spool fills up, the shim stops reading the child's pipe, which is back-pressure as in RUN-007; the spool holds only what is not yet delivered, so it is nearly empty in normal operation. After the process exits the shim keeps delivering until the spool is empty, up to `log_hold_timeout` (600 s), then exits with `logs_undelivered`. The Pod's `resources.limits.ephemeral-storage` is the spool plus a margin for the step's working files; the shim limits itself slightly below the `sizeLimit` because the kubelet would otherwise evict the Pod. Invalid UTF-8 bytes are replaced one by one by U+FFFD and long lines are cut between characters.

Because the core proxies each write itself, every error or timeout of vlagent is seen by the core, and a series of failures closes the launch gate without waiting for the next poll (A.10). Delivery from a Pod that the core no longer needs uses `pods/exec`: the controller runs `cicd-shim --read-spool --after-seq N` and receives whole blocks. Measured properties of the exec client: each call costs about 17 s regardless of volume, and a fast stream loses frames (half a megabyte of zeros arrived), so the shim writes in 4 095-byte frames with a pause and lingers before exit, reads proceed in chunks of up to 400 KB with checksums, and the controller caps the whole read at 120 s.

## A.9 Shim, completion handshake and liveness

Silence is not proof of loss: a step is lost only when the Kubernetes API confirms it (Pod 404, a terminal phase, a lost node, eviction); silence alone gives the status `unreachable`. The shim keeps running the command when the link breaks, accumulates logs in the spool and reconnects with back-off; on return it sends its full state, and the core reconciles it by event number (D-30): a step still `running` or `unreachable` returns to normal; a step handed to a retry whose new attempt has not started accepts the returned attempt; if the new attempt already runs, the old one gets `CancelStep` and keeps its own log stream (the `job` label includes the attempt number).

The shim starts the command with `nice 10` and `oom_score_adj 500` (inherited by everything the build starts): when the CPU is short the shim can still read the pipe, send heartbeats and deliver the log, and the OOM killer picks the build. The result comes from the shim, not from the Pod status: after the command and the delivery of logs the shim sends `StepReport` (exit code, reason, log delivery outcome, outputs) and waits for `may_exit`; the core records the result idempotently by `(run, seq, attempt)` through the same transition path as a result read from a Pod, and answers with a disposition `recorded`, `superseded` or `retry_later`. If the core is unreachable for longer than `log_hold_timeout`, the shim exits with the code and the termination message, and the controller reads the Pod status and the tail of the Pod log. The Pod's own log carries only shim events, one line `CICD-SHIM {…}` per transition with the whole accumulated state and a growing event number; the build's output never appears there. A finished Pod is kept until the core has recorded the result and the log is delivered (or the retention time passed, several hours for failed and short for successful Pods). A step lost only to infrastructure is repeated if it never started (`lost_never_started`, up to `infra_retries`); the sign of a start is one of two: the container was seen running, or the shim opened a log stream in the core; everything unknown counts as started. A step with an OOM kill gets the verdict "out of memory", not an infrastructure loss. Container metrics (cgroup, `/proc`) are always collected by the shim; application metrics are declared in the Lua script (`metrics = {…}`, docs/metrics.md); Prometheus scrapes only the core.

## A.10 Launch gate

The gate is a pure function of the polled state: a node is `up`, `catching_up` or `down` (after `fail_threshold` = 3 failed polls in a row); the gate may open when at least one node is alive, vlagent accepts writes, and vlagent's queue for that node is within `gate_max_pending` (256 MiB) and not blocked; it opens only after the condition held for `gate_stabilize` (10 s) and closes in the same poll; after a restart, and when the poller falls silent, it is closed. The poll reads `/health` of each node and `/health` and `/metrics` of vlagent (`vlagent_remotewrite_pending_data_bytes`, `vlagent_remotewrite_queue_blocked` per destination, labelled by position in the `remoteWrite` list, so the order of nodes in the configuration must match). In addition, the core's own failed write to vlagent closes the gate at once. Measured: with VictoriaLogs scaled to zero the gate closed in 4.5 s, a run created in the meantime waited with `logs_unavailable` and no Pod was created; after VictoriaLogs returned the gate opened, the queue continued and the run finished `SUCCEEDED`. With spools on the Pods, the gate is a control of intake rather than a fast emergency switch: without it a log-circuit outage would accumulate running Pods, each waiting up to `log_hold_timeout` while holding resources; the queue costs nothing.

## A.11 Backup and restore

**rqlite.** It has built-in `-auto-backup` and `-auto-restore` flags with a JSON config (`type: s3`, interval, keys, endpoint, region, bucket, path): only the leader backs up, and only when data changed; restore happens at node start, before joining the cluster; the official chart supports it through `extraArgs` and `extraFiles`. So no tool of our own and no restore command are needed. Measured: each upload 6--17 ms (the first 507 ms); no effect on writes during the upload on a clean test bed (p50 11.6 ms, p95 18.5 ms over 5 000 writes in 2 minutes); restore into a clean node `node loaded in 7.9 ms`, serving data a second after start; RPO equals the backup interval (a backup at T, five writes after, the node destroyed at T+13.5 s: the restored state equals T exactly).

**Logs.** Scenario: a node standing for both nodes of a shard lost together, 20 000 lines, a partition snapshot (0.02 s), upload to S3 (under 1 s), 3 000 lines of drift after the snapshot, the Pod destroyed, and restore into a new Pod whose init container downloads the snapshot into `<-storageDataPath>/partitions/<partition>/` before VictoriaLogs starts. The restored node holds exactly the 20 000 lines from before the snapshot and none from after: the logs' RPO with both nodes lost equals the snapshot interval (1 hour by default). A new Pod was Running in 16 s (a small volume; the time grows with the size of the snapshot, the copy being bounded by network and disk). Both real nodes are synchronised through vlagent, so a snapshot can be taken from any available node.

## A.12 Memory stability

The soak harness is a single process with worker threads under constant load: the transport (REQ/REP with encryption and Protobuf, half of the requests on new connections, half on a permanent client) and Lua sandbox cycles (create, run with a journal, kill, replay, destroy). Once a minute it writes RSS and the Nim occupied heap to a CSV file and at the end compares RSS with the end of warm-up. Two variants run in parallel: a release build (continuous, 1 h warm-up, RSS growth limit 2%) and an AddressSanitizer + LeakSanitizer build (hourly runs, LeakSanitizer reports at every exit; the RSS limit is off because ASan's allocator does not return memory).

Findings that became rules: a shared TLS library must be built with its threading support (without it parallel handshakes fail in about 99% of cases); a permanent client must reconnect after a link break and a shutdown watchdog must exist (120 s, then a forced exit with code 4); certificates are read once and cached (a stray `git checkout` once rewrote them under a running process).

**The leak in the transport binding.** An RSS growth of about 25 MiB/hour appeared in the ZeroMQ path. It was not libzmq, CURVE, malloc arenas or `REQ_RELAXED`: splitting the harness into server and client processes showed a flat server (+0.11% in 20 minutes) and a growing client; a bare libzmq with the same pattern (also with four threads, a context per connection) was flat; `heaptrack` under `-d:useMalloc` showed the whole leak as one allocation per connection, `result.sockaddr = address` in `connect()`: the binding's custom `=destroy` did not destroy the `sockaddr` field (about 30 bytes per connection). The one-line fix with a regression test was merged upstream (nim-lang/nim-zmq#59) and reaches the dependency branch through upstream master. After it, 313 000 connections in 10 minutes moved the client's RSS from 7.81 to 7.76 MB. The 72-hour acceptance run of NFR-013 on the final build is the measurement that closes this item.
