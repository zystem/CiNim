# Pipeline conductors in the organisation's namespace (design)

Requirements touched: RUN-004 (limits), RUN-008 (lease), RUN-009 (density), RUN-016 (liveness), PIP-003/004/006 (journal, replay, limits), SEC-007 (isolation of the pipeline logic), SEC-010 (rights in the cluster), SHD-008 (reconciliation), D-49 (the core is the source of settings), T-03 (journal tampering).
**Terminology.** This component is called the *pipeline executor* in the specification and in the code (`src/executor`, `src/executorsvc`, `ExecutorChannel`, `LeaseRequest.executor_id`; RUN-008, RUN-009, SEC-007). The owner named it the **conductor** (in Russian, *дирижёр*). This design uses the new name; the specification and the code take it over when it is built.
**Status: a design, nothing of it is built.** The decisions are the owner's, taken on 2026-10-10 after a comparison with the competitors (`docs/prior-art-queues-sandboxes.md`). `docs/parallel.md` follows this document where the place of the conductor matters.

## 1. Today

* One **shared executor service** (`src/executorsvc`, a Deployment of the shard) serves **every organisation**; `LeaseRequest.run_id` empty means "the next run of any organisation".
* It leads **one run at a time** (RUN-009 density is not built) and dials the core directly (ZeroMQ + CURVE, port 19741) with the shared client key.
* It sits in the platform-trusted zone (Z2): a user's Lua runs next to the code of the platform and next to the Lua of other organisations.
* The lease token is `t-<run id>` and is not checked. The hash chain of the journal is rebuilt by the executor from the rows; the core stores no hash (`executorsvc/main.nim: toJournal`), so T-03 holds only on paper.
* Steps: the core makes a step row (`PENDING`) when the executor calls `job_sh`; the controller polls the core about once a second and takes steps; `free_pod_slots` is the constant 20 per poll (`jobcontroller/main.nim`) and bounds one poll, not the Pods in flight. There is no limit per organisation.

## 2. Decisions

1. **Queues are in the core**: the queue of runs (the `runs` table) and the queue of steps (the `steps` table, a row in `PENDING` from the moment the script asks for the step). The core applies every limit; the UI and `/metrics` see every waiting step.
2. **The limit of an organisation is a number of step Pods in flight**, `pod_limit`, **20 by default**. A run (the owner's "job" is a run) may hold at most **20 %** of it by default (`job_pod_limit`; settable on groups and builds, never above `pod_limit`). Conductor Pods are **not** counted in `pod_limit`.
3. **Active runs of an organisation are at most `pod_limit`**: a run needs at least one Pod to make progress, so more active runs would only hold processes and wait. The others wait in the queue of runs.
4. **Conductors are Pods in the organisation's namespace**, made by the controller. **Their number is computed**, not set: `ceil(active runs / runs_per_conductor)`, at least `conductor_min`, so at most `ceil(pod_limit / runs_per_conductor)`.
5. **One conductor leads up to `runs_per_conductor` runs (10 by default), each in its own process** inside the Pod: a supervisor process and one run process per run.
6. **`conductor_min` is a setting of the organisation, 1 by default**: one warm conductor, so the first run does not wait for a Pod. 0 is allowed (scale to zero).
7. A conductor with no run for the **idle time (5 minutes, a setting of the shard)** is stopped, down to the minimum.
8. A conductor is **replaced by memory and age**, not by a count of runs: when the supervisor's RSS passes its request, and after a maximum age (24 h, with jitter); a count of runs is the fallback when RSS cannot be read.
9. The conductor **talks to the core directly**, with a credential the core issues and the controller hands over in a Secret, as a step's shim does; it has no rights in the cluster.
10. A run has **at most 200 steps in all**, parallel and sequential together (a limit of the Lua sandbox, PIP-006); a **`ci.run` is one of the 200** (a child run counts in its parent's limit and has its own 200), and the **depth** of runs started by runs is limited by the same number. Work that needs more is split into **other runs** with `ci.run`.
11. **Two calls make a child run** (PIP-010): **`ci.run(ref, params)`** starts it and **waits**: the parent is suspended **at once** until the child ends and gets the child's result, so a step such as `build` can run `deploy` as a run, wait for it and fold its status into its own; **`ci.start(ref, params)`** starts it and returns a **handle** (`h.id`, `h:wait()`, `h:cancel()`) at once: the parent goes on, the child lives on its own (even after the parent ended), and `h:wait()` suspends the parent like `ci.run` does. A child run is an ordinary run: it counts in the organisation's active runs and waits in the queue of runs. A run that waits for an approval or for `ci.sleep` stays in its conductor for **up to 5 minutes**; a longer wait suspends it (the journal) and frees its place.
12. **The core pushes work** over the connection the controller or the conductor opened (no polling, no request held open, the core never dials a client): steps to make, conductors to start or stop, leases of runs, results of steps, settings, drain and cancellation; with credits, acknowledgements, a resync after a reconnect and heartbeats (section 12). Also borrowed from the competitors: a **version of the Lua API recorded in the run** (replay uses it); **fairness**: a free slot goes to the run with the fewest Pods in flight, and the priority of a waiting step grows with its age.

## 3. Picture

```
core: queue of runs, queue of steps, limits, journal (with its hash chain)
  │
  ├══ stream opened by the controller ══ controller (organisation namespace)
  │     core → controller: steps to make, conductors wanted, settings, cancel
  │     controller → core: Pod states, acknowledgements        │ makes Pods:
  │                                                             ├─ step Pods (shim), as now
  │                                                             └─ conductor Pods
  └══ stream opened by the conductor ══ conductor Pod
        core → conductor: leases, step results, drain           supervisor ──pipe── run process × up to 10
        conductor → core: host calls, run states, acks          (Lua, no network, own rlimits)
```

* The **core decides**; the controller makes Pods (SEC-010, D-49). The conductor never makes a Pod.
* A **step**: the run process calls `j:sh` → the supervisor sends the host call `job_sh` with the call's key (`docs/parallel.md`) → the core makes the step row `PENDING` (or finds it by key) and answers *pending* → the core pushes the step to the controller when the limits allow → the controller makes the Pod → the shim reports to the core → the core pushes the result to the conductor, which hands it to the run process.
* Nothing waits in the conductor except Lua coroutines: there is no queue of steps there and no `accepted`/`busy`.

## 4. Queues and limits in the core

* **Admission of a run**: a run is leased to a conductor of its organisation when the organisation has fewer active runs than `pod_limit`; otherwise it waits in the queue of runs (first in, first out, then by priority).
* **Admission of a step** (the core pushes admitted steps to the controller): steps `PENDING` of the organisation, taken while the organisation has fewer than `pod_limit` steps in flight and the step's run fewer than its `job_pod_limit`. "In flight" means admitted and not finished (it has a Pod or is being given one); a retry of a step uses the step's slot.
* **Order**: first the run with the **fewest steps in flight** (as GitLab prefers the projects with the fewest running jobs), then the **oldest waiting step**, whose priority grows with its waiting time (as TeamCity's queue ages priorities), so no run starves.
* **`job_pod_limit`**: 20 % of `pod_limit` by default, rounded up, at least 1; can be set on a **group** and on a **build** as a number or a percentage; the nearest level wins (build, group, organisation); a value above `pod_limit` is refused when saved and clamped when read.
* **The controller keeps its own cap** (`pod_limit` as it last heard it) and refuses a step above it: defence in depth. A Kubernetes ResourceQuota on the namespace (`count/pods`) is an optional third line and must leave room for the conductors.
* **Push**: the core sends an admitted step to the controller at once, within the controller's credit (the Pods it is ready to make); see section 12.

## 5. The conductor Pod

* **Supervisor**: one process that holds the connection to the core (conductor credential), takes leases, starts a **run process** per leased run (fork and exec of the run binary), relays host calls and answers over a pipe, reports the runs' state, and exits when drained. It runs no Lua.
* **Run process**: one Lua state, the run's journal for replay, the branch scheduler of `docs/parallel.md`; **no network** (seccomp denies `socket`), read-only file system, its own rlimits (memory, CPU), exits when the run ends or is suspended. A crash, an out-of-memory failure or a sandbox escape stays in this process; the other runs go on.
* **Number of conductors**: the core sends `desired_conductors` in the answer to the controller: `clamp(ceil(active runs / runs_per_conductor), conductor_min, ceil(pod_limit / runs_per_conductor))`. The controller creates Pods with deterministic names (`cond-<n>`) and adopts them after its own restart, as it does for steps.
* **Idle**: a conductor above the minimum with no run for the idle time (300 s) is drained by the core: the core stops giving it runs and says `drain`; it exits with 0; the controller deletes the Pod after the exit. The controller never kills a conductor on its own timer.
* **Replacement** (a new image, a change of resources, RSS over the request, the maximum age): the same drain; the runs it holds are **suspended** and taken by another conductor with a replay of their journals (short: at most 200 steps). Below the maximum number the new conductor starts first; otherwise the old one goes first and its runs wait a few seconds.
* **Lost conductor** (node lost, Pod evicted): its leases expire, the core gives the runs to another conductor, replay goes on. A run that has lost `conductor_max_losses` (3) conductors **in a row** ends as `infrastructure_error` with the code `conductor_lost`, so that a run that kills its conductor does not loop. A run process that dies alone is the same case for its one run.
* **Cold start**: with `conductor_min = 1` the first run finds a conductor ready; a Pod is started only when the warm one is full (10 runs), so most runs never wait for one.

## 6. A run inside the conductor

* **Lease**: a run is leased to a conductor with a token and an **attempt number**; every call carries both, and the core refuses a call of an older attempt (a conductor that was believed lost and comes back cannot act). The lease is renewed by the traffic of the run.
* **Waiting**: a branch that waits for a step waits **in memory** (the run process is blocked on the supervisor, to which the core pushes the run's events). An approval or `ci.sleep` may wait up to `run_wait_seconds` (300); a longer wait **suspends** the run: the run process exits, the core keeps the run `RUNNING` and takes it again when the wait ends. Waiting for a child run (`ci.run`) suspends at once (otherwise parents could hold every place and no child could start).
* **Limits of a run**: 200 steps and `ci.run`/`ci.start` calls in all, a nesting depth of 200, the Lua heap (64 MiB) and the instruction budget (PIP-006); the journal record limit stays as a safety net (2 000 proposed); the size of a step's result is to be limited (STO-003).
* **Version of the Lua API**: a run records the version of the host API it started with; a conductor declares the versions it supports (**the current one and the two before it**); the core leases a run only to a conductor that supports its version, and replay uses that version. An upgrade of the platform does not change the meaning of a running run's calls. **Memory:** a version is the Lua prelude of its host API (`bootstrap.lua`, about 27 KB of source today) and its Nim glue; a run process loads **only the prelude of its own run's version** (the supervisor runs no Lua), so a conductor that supports three versions pays about 80 KB of preludes in the binary and nothing per run; the real cost of a version is to keep it working and tested, which is why the supported set is small and a version leaves it after two newer ones.

## 7. Security

* **Credentials**: the core issues a conductor credential per conductor Pod (scoped to the organisation and to that conductor), the controller puts it in an ephemeral Secret; leases are per run. A conductor's calls are refused for runs not leased to it and for other organisations: a compromised conductor cannot name another organisation's run.
* **Network**: NetworkPolicy lets a conductor Pod reach only the core's conductor port; the run processes have no network at all; no service-account token is mounted.
* **Journal**: the core computes and **stores** the hash chain and verifies it on every lease (T-03), so the party that may be hostile is not the one that keeps the history. This is new work.
* **SEC-007** holds: separate processes, seccomp, read-only file system, rlimits, one Lua state per run, destroyed with the process. The threat model gets the conductor as a component in the organisation's zone (not Z2), its flow to the core, and the threats of a process escape (bounded to its own run's lease and the Pod).
* Step Pods and conductors reach the core the same way (a credential and a port); if a gateway for the Pods of tenants is wanted later, it is for both at once.

## 8. Memory and sizing (estimates, to be measured)

| Part | Estimate | Bound |
|---|---|---|
| Supervisor | about 10-15 MB (the soak harness, transport and Lua, holds 13.4 MB) | none; watched, replaced by RSS |
| Run process, typical | a few MB (Nim runtime, a small Lua state, a short journal) | |
| Run process, worst | Lua 64 MiB + journal a few MiB + runtime | PIP-006 allocator + per-process rlimit |
| Pod, typical with 10 runs | under 100 MB | |
| Pod, worst with 10 runs | about 700-800 MiB | the sum of the run limits |

* **Request and limit**: the request is the typical figure once measured; the limit must hold the sum of the run processes' limits plus the supervisor, or the per-process rlimit must be lower. On cgroup v2 Kubernetes kills the **whole container** on an out-of-memory event by default since 1.28 (to be checked for the clusters in use): the per-process rlimit must make a greedy run fail alone before the container reaches its limit.
* **Recycling**: per-run memory is freed when the run process exits; only the supervisor is long-lived, so it is replaced by RSS and age (decision 8). The count of runs is a fallback, not a design input.
* **What to measure** (the second test cluster, the real binaries): idle RSS of the supervisor and of a run process; a run process after a replay of 200 steps with results of 1 KiB and 1 MiB; 10 runs with 200 parallel branches each; the supervisor's RSS over a day of runs (the slope that sets the replacement threshold); the start of a conductor Pod with the image cached and not; Pods per node and API-server load with the expected number of conductors; a run killed by its rlimit three times ends `conductor_lost`.

## 9. What it changes in `docs/parallel.md`

* The journal **keys** and the **branch scheduler** stay: replay is needed after a lost conductor, a replacement and a suspension.
* `pending` is the normal answer to `job_sh` while the step waits or runs; the run process parks the branch and the core pushes the run's events to the supervisor. Suspension is for long waits only.
* The **lease** of that document is the lease of section 6 (token and attempt). `dirty` becomes "a suspended run whose wait has ended": the condition for leasing it again.
* The **ordinal** of a step is allocated by the core when the row is made; the key finds the step again after a crash, so none is made twice.
* The width of `ci.parallel`/`ci.matrix` is bounded by the 200 steps of a run.

## 10. Tests

* **Core** (integration against rqlite): a run is leased only to a conductor of its organisation and only while active runs are below `pod_limit`; a call of an older attempt is refused; steps are admitted under `pod_limit` and `job_pod_limit`, the run with the fewest steps in flight first, an old step before a new one; a retry uses its step's slot; overrides on group and build, clamping; `desired_conductors` follows active runs, the minimum and the maximum; the hash chain is stored and a tampered row fails the lease.
* **Controller** (logic with a fake Kubernetes): creates and adopts conductors; deletes only a drained Pod after its exit; refuses a step above its cap; takes pushed work only within its credit, acknowledges after the Pod exists, and resyncs after a reconnect.
* **Channel:** the core never sends above a client's credit; an unacknowledged message is sent again after a reconnect and its action happens once; after a reconnect the inventory makes the database and the client agree (a Pod the core does not know is deleted, a step the client never got is sent); a client that disappears is seen by heartbeat within seconds; 300 clients reconnect and resync after a restart of the core.
* **Conductor**: a run process per lease; a run process that crashes or hits its rlimit ends only its run; seccomp denies a socket in a run process; drain suspends the runs it holds and exits; replacement by RSS and by age.
* **Parallel and waiting**: two branches in one run process wait in memory; a 5-minute approval suspends the run and frees its place, a shorter one does not; a parent waiting for a child is suspended at once; replay after a lost conductor makes no step twice (the property tests of the specification).
* **API version**: a run started under version N is replayed under N by a conductor that supports N and N-1, and is not leased to one that does not.
* **Cluster**: 10 runs share one conductor Pod; the warm conductor serves the first run without a Pod start; idle conductors above the minimum go after 5 minutes; a second organisation cannot reach the first one's runs; a conductor Pod reaches nothing but the core; killing a conductor Pod and the controller Pod in the middle of runs ends with the same journals as clean runs.

## 11. Phases

1. **The core**: queue of steps with limits and order (`pod_limit`, `job_pod_limit`, fairness), the push channel to the controller (ROUTER in the core, section 12), the stored hash chain, leases with token and attempt, the version of the API in a run. The shared executor service keeps working as "a conductor of the platform".
2. **The conductor**: supervisor and run processes, the conductor credential, its push channel; tested with a conductor started by hand.
3. **The controller**: `desired_conductors`, create, adopt, drain, replace; chart and provisioning (RBAC of the controller for conductor Pods, NetworkPolicy, seccomp profile).
4. **`docs/parallel.md`** phases 1-3 on top of this.
5. The shared executor service goes away; specification (RUN-008, RUN-009, NFR-006, PIP-006, SEC-007), threat model, deployment and the mirrors are updated; the soak runs on the new path.

## 12. The channel between the core and its clients (push)

* **Shape.** The client (the controller, the conductor) dials the core and keeps the connection; both sides send at any time. In ZeroMQ the core's socket becomes **ROUTER** (today it is REP, which answers strictly one request at a time and can neither hold a request nor start a message) and the client's **DEALER**; CURVE as now. The core **never dials a client**: no ingress into the tenants' namespaces, nothing changes for NetworkPolicy. It is the pattern of Buildkite's streaming dispatch, of Harness's outbound delegate connection and of a Kubernetes watch.
* **From the core:** to the controller `Settings` (ControllerConfig, D-49), `MakeStep`, `CancelStep`, `Conductors` (the computed number), `ReleaseStorage`; to the conductor `Lease` (a run, its token and attempt, script, journal, API version), `CallResult` (the answer to a host call, the result of a finished step among them), `Drain`, `CancelRun`.
* **To the core:** from the controller `Hello` with its inventory (its Pods by name and state), `PodState`, `Ack`; from the conductor `Hello` with its inventory (the runs it holds with their attempts, the API versions it supports, its free places), `HostCall`, `RunState` (finished, suspended), `Ack`.
* **Credits.** A client says how much it can take: the controller how many Pods it is still ready to make (its own cap minus what it has), the conductor its free places (of 10). The core never sends above the credit, and the credit is renewed by the client's messages (as AMQP prefetch). This also keeps clear of a ROUTER's habit of silently dropping messages to a peer whose queue is full.
* **Acknowledgement and redelivery.** Every message from the core has an id; the client acknowledges it when it has acted (the Pod exists, the run process is up). An unacknowledged message is sent again after a reconnect; a duplicate is harmless because the actions are idempotent (deterministic Pod names, step keys, run attempts).
* **Resync** (the list-and-watch of Kubernetes): after a connect or a reconnect the client sends `Hello` with its inventory; the core compares it with the database and sends what is missing or stale (a step to make, a Pod to delete, a run to lease again or to drop). The database stays the source of truth; messages in flight are not persisted.
* **Heartbeats** on the connection (ZeroMQ's own `ZMQ_HEARTBEAT_IVL`; whether the nim-zmq binding exposes it is to be checked): a client that disappears is seen within seconds (RUN-016). A conductor's leases still expire only after the lease TTL, not on one missed heartbeat.
* **A restart of the core** drops every connection at once: clients reconnect after a random delay and resync. The test "kill the core in the middle of 300 runs" is acceptance criterion 4 of the specification, on the new channel.
* **The conductor and the shim use the same transport** (`common/stream.nim`, kinds of their own: `conductor.*`, `shim.*`). The conductor is built on it from the start (phase 2). The shim's **control** messages (its state, the permission to exit, cancellation) move to it in a later step, which gives instant cancellation (RUN-006) and an instant permission to exit (D-29); its **log and artifact streams stay on their own channels** (LogIngest, ArtifactIngest): they are bulk data with a flow control of their own (the spool, back-pressure), a different thing from control messages.

### As built (the controller's channel, 2026-10-11)

* **Code.** `src/common/stream.nim` (CURVE ROUTER for the core, DEALER for a client; the envelope `u8 version | u64 id | u64 ack | u64 re | session | kind | payload`; ZeroMQ heartbeats 3 s / 10 s and `ROUTER_MANDATORY` are set), `src/common/streamstate.nim` (numbering, cumulative acknowledgement, resending, credit), `src/core/workkick.nim` (thread-safe "there is work for this organisation", fixed arrays), `src/core/streamhub.nim` (the core's thread on port **19745**, `CINIM_STREAM_PORT`), and the controller's `Push` in `src/jobcontroller/main.nim`, used when `CINIM_CORE_STREAM_ADDR` is set (the core's provisioning sets it for every controller); without it the controller polls as before.
* **Kinds.** `controller.report` (a PollRequest, numbered, not resent: a snapshot), `controller.work` (a PollResponse, numbered, acknowledged), `ping`, `resync`. The answer to a report carries `re` = the report's number, so the controller knows which frame answers it and which was pushed; pushed work arriving meanwhile is applied with the answer.
* **What the core does.** A report is handled by the same `handlePoll` as a poll (so every rule of the poll holds). Besides, a **kick** (a step made by the executor, a changed limit) makes the hub look at that organisation's controller at once with a request that carries no news (`push = true`: no heartbeat, no inventory) and the credit of the last report; what it finds is pushed. A safety pass every 3 s catches the rest (a pause that ended, a step the watchdog put back). Work is pushed only when there is something the controller does not have (a command, a release, an identity matter, a changed setting or gate).
* **Credit.** The free slots of the last report, less the steps pushed since; the controller renews it in every report.
* **Identity.** A controller that does not prove itself, or is being given its credential, is not registered and gets no pushes; it reports again with the credential.
* **Checked.** Unit tests of the envelope, the sockets (CURVE over localhost, a wrong key, a peer that is gone), the bookkeeping and the kicks across threads; integration tests against a real rqlite and real sockets (an answer like a poll, a push after a kick, credit not exceeded, resend after a reconnect and none after the acknowledgement, resync of an unknown session, no work of another organisation); and a run of the real core and the real controller binary, the controller against a throwaway namespace of the TESTING cluster: the controller received a pushed `start` and made the step's Pod.
* **Not checked.** The delay from a kick to the controller in a cluster (here the database was reached over a port-forward, so the figure would mean nothing); ZeroMQ heartbeats in action; many controllers at once; the restart of the core under load. A step claimed by the core whose frame is lost across a **restart of the core** is still recovered by the liveness timeout (`start_timeout`), not by a resend; a resync that sends again the steps claimed for a controller but absent from its inventory is open.

## 13. Open

Decided on 2026-10-11: a job is a run; `pod_limit` is 20; a `ci.run` or `ci.start` counts in the 200 of its run, the depth is bounded by the same number; `ci.run` waits and `ci.start` does not; a conductor supports the current Lua API version and the two before it; the settings (the limits and their overrides) are kept in the database like all the others; the measurements of section 8 are agreed; the work starts with the core (phase 1) and its first piece is the push channel (section 12).

1. **Overrides**: which objects carry the overrides of `job_pod_limit` ("group" and "build" are the group and the project of PRJ-001?). They are kept in the database like the other settings; until the objects are named phase 1 has the organisation level only.
2. **The journal record limit** (2 000 proposed, a safety net).
