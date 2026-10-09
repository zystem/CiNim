# Prior art: queues, schedulers and sandboxes for pipeline logic (research dossier)

Purpose: give a reviewer (a person or a model) the facts needed to choose the scheme for **where pipeline logic runs and where work is queued**, and to decide whether the owner's scheme in `docs/conductors.md` should be kept, changed or replaced by a solution copied from the competitors.
Collected on 2026-10-10 from the products' own documentation; every fact is marked by how it was checked (section 9). **This is a dossier, not a decision.**

**Coverage.** Section 2 of the specification lists 20 products; all are here: TeamCity 3.9, Jenkins 3.4, GitHub Actions 3.1, GitLab 3.2, Azure Pipelines 3.5, CircleCI 3.5, Travis CI 3.12, Buildkite 3.3, Tekton 3.6, Woodpecker 3.5, Argo Workflows 3.6 (Argo CD is a GitOps reconciler, outside queues and sandboxes), Drone 3.5, Bamboo 3.10, Spinnaker 3.7 (Orca), Harness 3.11, Semaphore 3.11, Bitbucket Pipelines 3.10, AWS CodePipeline 3.12, Concourse 3.5, Dagger 3.13. Beyond that list: Temporal, Azure Durable Functions, Dagster, Prefect, Airflow, Kueue and the sandboxes of section 5. The first version of this dossier missed eight of the 20; they were added after the owner's remark.

## 0. Brief for the reviewer

**The task.** Compare the scheme S0 (section 1) with the architectures of the products in sections 2-5 and with the alternatives S1-S6 (section 7). Choose the scheme that best meets the criteria of section 8, or propose a better one. The owner is ready to drop S0 completely and to copy a competitor's solution if that is better. Say what is wrong with S0 and what it does better than the others.

**Answer, please, in this form:** (1) the chosen scheme, in one page, with the data flow of a run from creation to the last step; (2) for each criterion of section 8 how it is met; (3) what is taken from which product; (4) what is thrown away of S0 and why; (5) what must be measured before building; (6) the risks.

**Fixed by the specification** (`docs/specification.md`; they can be argued with, but only with a reason):
* A pipeline is a Lua 5.4 script in a sandbox; every host call that has a side effect is written to an append-only **journal**, and a script that is restarted **replays** it (PIP-003/004/005). `ci.parallel`, `ci.matrix`, `ci.spawn`, `ci.run` exist or are planned.
* Every step is a Pod made by the **job controller** of the organisation, the only component with rights in the cluster (SEC-010). The controller has a pull channel to the core (ZeroMQ + CURVE, D-24).
* **The core knows and controls everything** (D-49): permanent modules take their settings from the core.
* A shard lives in one Kubernetes cluster; an organisation belongs to one shard; **no permanent agents on nodes**; no registration of agents (section 6.4 of the specification).
* Scale targets: 1 000 concurrent steps and 100 000 runs a day per shard (NFR-006, not yet measured); a Pod starts a step in a time to be measured (RUN-013); 72 h soak without RSS growth (NFR-013).
* Images small (the project's bound is Alpine); the shim is a static binary delivered to step Pods in a ConfigMap, the other services link libraries.

## 1. The owner's scheme (S0), as designed in `docs/conductors.md`

*After this dossier the owner decided a revised scheme (queues in the core, a conductor Pod leading up to 10 runs in separate processes, a direct link to the core, limits in Pods); `docs/conductors.md` holds it. S0 below is the scheme that was compared.*

* A **queue of runs in the core**. The core hands runs to the **controller of the organisation**.
* The controller starts **conductors** (today called "pipeline executors"): Pods in the organisation's namespace. One conductor leads **one run** at a time and holds the run's Lua state **in memory** (no replay while it lives; replay only after a loss or a long wait). Minimum 0, limit per organisation 3, idle conductors stopped after 5 minutes, a conductor is replaced after 50 runs.
* A conductor talks **only to the controller** (a relay), never to the core directly; it has no rights in the cluster. It reports to the core through the relay.
* A run has at most **200 steps in all**; more work is another run (`ci.run`). The conductor holds a **queue of its steps**: a step is requested, accepted if below the limits, otherwise it waits in the conductor's queue.
* Limits of step Pods: per organisation, and per run (20% of the organisation's by default; settable on groups and builds).
* A wait of up to 5 minutes (approval, `ci.sleep`) stays in the conductor; a longer one suspends the run (journal) and frees the conductor; a run that waits for a child run is suspended at once.
* Open inside S0: who admits a step (controller or core, `docs/conductors.md` section 12), the memory of a conductor (section 13), the Pod count of a Pod-per-run model.

**What CiNim has today** (checked in the code): one **shared executor service** for all organisations (`src/executorsvc`), one run at a time per process, connected straight to the core (REQ over ZeroMQ), pulls "the next run of any organisation"; the lease token is not checked; the core makes a step row when the executor makes the host call `job_sh`, and the controller **polls** the core and takes steps (`free_pod_slots` is the constant 20 per poll); the hash chain of the journal is built by the executor. Measured: a soak harness process (transport + Lua sandboxes with journals) holds 13.4 MB RSS, growth 0.09% in 34 h (spec A.12).

## 2. Taxonomy

| Class | Where the logic of a run lives | Where work waits | Who dispatches | Products |
|---|---|---|---|---|
| **A. Central scheduler, pull agents** | in the server (declarative YAML, or a script on the server) | in the server's database/queue | agents **long-poll** the server | GitLab CI, GitHub Actions (+ARC), Buildkite, Azure Pipelines, CircleCI runners, Woodpecker, Drone, Gitea Actions, Concourse (workers register), TeamCity, Bamboo, Bitbucket Pipelines, Travis CI, Semaphore, AWS CodeBuild, Harness (delegate) |
| **B. Script on the server** | a user script in a sandbox **on the controller** | build queue + executors on agents | server assigns | Jenkins (Groovy CPS) |
| **C. Kubernetes-native controller** | in a controller that reconciles custom resources | no queue of its own; limits by parallelism settings; optional external admission queue | controller creates Pods | Tekton, Argo Workflows (+Kueue as an add-on) |
| **D. Durable-execution engine** | user code in **workers** that replay a history | **task queues**; workers pull | server matches tasks to polling workers | Temporal, Azure Durable Functions, Cadence; Spinnaker Orca (message queue, no user code) |
| **E. Run worker per run** | in a **Pod made for the run**; steps in the same pod or in other pods | a **run queue** with limits, in a daemon | a launcher creates the Pod | Dagster (K8sRunLauncher), Prefect (Kubernetes worker) |
| **F. Programmable engine** | user code in containers inside the engine, calling its API | the engine's DAG and cache | the engine | Dagger |

S0 is a hybrid of **E** (a process per run in a Pod, a run queue with limits) and **A/D** (pull from a central queue, ARC-like min/max scaling), with the relay through the controller as its own addition.

## 3. Product data sheets: queues and dispatch

Marks: **[V]** read in the product's documentation in this research; **[S]** from a search-result summary only; **[K]** general knowledge, not re-checked; **[C]** checked in the CiNim code or spec.

### 3.1 GitHub Actions and Actions Runner Controller (class A)

* The workflow engine and the queue are inside GitHub's service; the logic of a run is **declarative** (YAML and expressions), no user code runs in the service. [K]
* **ARC runner scale sets:** a *controller manager* Pod, one *listener* Pod per scale set, and *ephemeral runner* Pods, **one Pod per job**. The listener keeps an **HTTPS long poll** to the Actions service; on a "Job Available" message it computes the desired replicas and **patches** an EphemeralRunnerSet; the EphemeralRunner controller gets a JIT registration token, creates the Pod (retries creation up to 5 times), the runner registers and receives the job; after the job the Pod is deleted. A job unassigned for 24 h is cancelled. [V]
* **Scaling knobs:** `minRunners` is "the min number of idle runners"; the target is *minRunners + jobs assigned*, capped by `maxRunners`. The listener's scaler has `qps: 50`, `burst: 100`. [V]
* **Limits:** concurrent jobs on hosted runners 20 / 40 / 60 / 500 (Free / Pro / Team / Enterprise); a matrix makes at most **256 jobs**; a self-hosted job waits at most **24 h** in the queue; a workflow run lasts at most 35 days; 50 re-runs. [V]
* Relevance: this is the scale-to-min/max-on-demand pattern of S0 (listener + ephemeral Pods), with the queue in the vendor's service and a **long-poll** instead of the core pushing.

### 3.2 GitLab CI (class A)

* The pipeline is YAML, expanded on the server; no user code runs in the server. [K]
* **The queue is a PostgreSQL table**, `ci_pending_builds`, a denormalised copy of what is needed to match a job (tags, protected flag, project); rows are inserted when a build becomes pending and deleted when it leaves that state. It replaced a greedy query on the very wide `ci_builds` table that ran on every runner request and made partitioning impossible. [V epic 5909] An earlier proposal (issue 218640) was a Redis queue per set of matching criteria, filled by a background worker, with a `LPOP` on request; the table was what was built. [V]
* **Dispatch:** the runner **long-polls** `POST /api/v4/jobs/request` (Workhorse holds the request, 50 s by default). [V] `check_interval` (default 3 s) is divided among the runner's configured sections.
* **Fair scheduling:** "prefer projects that do not have any CI jobs running first" (done in the query). [V]
* **Runner side limits:** `concurrent` (global, must be set), `limit` (per runner, 0 = unlimited), `request_concurrency` (default 1). A `concurrent` too low for the number of runners makes a "worker starvation" bottleneck. [V]
* **Kubernetes executor:** a pod per job (build + helper + service containers); `poll_interval` 3 s, `poll_timeout` 180 s; a Pending pod is waited for up to that timeout and the job then fails; optional **pause pods** to pre-warm capacity; pod disruption budgets; user namespaces; cleanup tool for orphans. [V]

### 3.3 Buildkite and agent-stack-k8s (class A)

* Agents **poll** the Buildkite API with jitter; since agent 3.122.0 **streaming dispatch** pushes jobs to idle agents (`--ping-mode auto` default, falls back to polling). [V]
* **agent-stack-k8s:** a controller "watches for scheduled jobs assigned to the controller's queue" with the Agent API and creates a Kubernetes **Job per Buildkite job**. Defaults: `max-in-flight` **25** (counts pods Running **and Pending**: unschedulable, pulling an image or terminating), `poll-interval` 1 s, `job-ttl` 10 min, `job-active-deadline-seconds` 21 600. Several controllers can serve one queue (`controller id`). [V]
* **Dynamic pipelines:** `buildkite-agent pipeline upload` runs a user's own program in an agent and uploads the YAML it prints; the logic runs in the customer's environment, never in the vendor's. [K]
* Relevance: `max-in-flight` is exactly "the limit of step Pods in the controller", **counting Pending Pods**; a pull-from-queue controller with a bound.

### 3.4 Jenkins (class B)

* The **whole Pipeline script runs on the controller** in a **flyweight executor**, which is a thread in the controller's JVM; flyweight executors are **unlimited** and made on demand; heavyweight executors (agent slots) are limited by node configuration and are taken only inside `node {}` blocks. The cost on the controller is "moderate" and grows with the complexity of the pipeline. [V]
* **Durability:** the program state is written to disk very often so that a restart continues the build; three modes (maximum survivability, performance-optimised that "greatly reduces disk I/O" but may lose data on a sudden stop, and a middle one). [V] The script is transformed to continuation-passing style (Groovy CPS) so that its state can be saved. [V]
* **Sandbox:** Script Security, a Groovy sandbox with an **allow-list of method signatures**; an administrator can approve more (in-process script approval); the documentation says to deviate from the default only when necessary. [V] There is a long history of sandbox bypass advisories for it. [S]
* **Kubernetes plugin:** a pod per agent, stopped after the build, or kept for `idleMinutes` for reuse; `containerCap` / `instanceCap` limit pods; the agent connects **to** the controller (WebSocket or JNLP). [V for pod per agent and idleMinutes; caps by search snippet]
* Relevance: the orchestration of a run is **free of any executor limit**, the logic and its state sit in the central process; the price is controller memory and disk I/O. The opposite of S0.

### 3.5 Azure Pipelines, CircleCI, Woodpecker, Drone, Gitea, Concourse (class A)

* **Azure Pipelines:** agents are pulled-from: "this communication is always initiated by the agent", which listens with an **HTTP long poll** on the job queue of its pool; when a job is available it downloads the job and a job-scoped OAuth token. Concurrency is a count of **parallel jobs** granted or bought; further jobs queue. [V search]
* **CircleCI container runner:** a pod per task; several **resource classes**, each with a token and a pod spec; a *constraint checker* periodically checks that each class can still be scheduled in the cluster, "to ensure pods can be scheduled" (so as not to claim a task that cannot run). [V] The container agent "polls CircleCI for jobs, spins up ephemeral pods with an injected task-agent" and tears them down after the job [V]; concurrency is the organisation's limit of self-hosted runner tasks [V], and the agent's own `maxConcurrentTasks` defaults to 20 [S]; a healthy agent logs "Started polling for tasks" every minute [S].
* **Woodpecker:** agents connect to the server over **gRPC**; `WOODPECKER_MAX_WORKFLOWS` default **1** per agent; the server's filters decide what an agent may take (they take precedence over the agent's own labels). [V]
* **Drone:** a pipeline can be written in **Starlark**, converted by an extension service (section 5). [V search] A runner **long-polls** the server's queue for 30 s and reconnects; `DRONE_RUNNER_CAPACITY` limits the pipelines a runner runs at once (2 by default for the Docker runner); Kubernetes runners can be added side by side and the server spreads work. [S]
* **Gitea Actions (act_runner):** the runner polls Gitea for queued jobs; labels decide the execution mode. Capacity per runner not read. [V partly]
* **Concourse:** the web node (ATC) holds the **checker, scheduler, build tracker and garbage collector**; several ATCs share one PostgreSQL and coordinate by locks; workers register through the TSA (an SSH server) and run Garden (containers) and Baggageclaim (volumes). Pipelines are declarative. [V]

### 3.6 Tekton and Argo Workflows (class C)

* **Tekton:** a PipelineRun can be created **pending** (`spec.status: PipelineRunPending`), which prevents it from starting until cleared. The documentation read gives **no queue or concurrency limit**; the order of tasks is a DAG (`runAfter`), `finally` tasks run last. [V]
* **Argo Workflows:** controller-wide `parallelism`, per-namespace `namespaceParallelism` (a namespace label can override), **pending workflows are queued by priority** (higher number first, default 0); mutexes and semaphores; "workflows that are executing but restricted from running more nodes ... still count toward parallelism". [V] **The controller cannot be scaled horizontally** (a hot standby is supported); sharding is by namespace or by `instanceID`; API rate `--qps` 20 / `--burst` 30; `resourceRateLimit` bounds Pod creation; the controller's memory is the informer caches. [V]
* **Kueue** (an add-on for Kubernetes jobs): a workload is held *suspended*, **no Pods exist** until the quota admits it; **LocalQueue** (namespaced) and **ClusterQueue** (a pool with quotas), fair sharing among queues of a cohort; FIFO within a priority. [V search]
* **Kubernetes ResourceQuota:** `pods` / `count/pods` per namespace; when exceeded the API server **rejects the creation with 403 Forbidden** at admission. [V]

### 3.7 Temporal, Azure Durable Functions, Spinnaker Orca (class D)

* **Temporal:** workers **long-poll** task queues "only when they have spare capacity"; workflow tasks and activity tasks have separate queues and are persisted; **4 partitions** per queue by default; a backlog turns off sync-matching. **Sticky execution:** the worker that ran a workflow task caches the workflow state in memory and polls a **worker-specific sticky queue**; if the worker does not start the task within **5 s** the service drops stickiness and reschedules on the normal queue; an evicted workflow is **replayed** on its next task. [V] **History limits:** 51 200 events and 50 MB per execution, a warning at 10 240 events, `Continue-As-New` to reset. [V]
* **Azure Durable Functions:** control queues are **partitioned** (4 by default, 16 max for Azure Storage; 12 and 32 for Netherite); an instance belongs to one partition so "the same worker processes all work items for the same instance" (affinity and caching); partitions cannot be changed after creation. **Instance caching / extended sessions** keep a mid-execution orchestrator in memory for an idle timeout (30 s in the example) to avoid replay. Concurrency throttles apply **per worker** (`maxConcurrentOrchestratorFunctions`); orchestrations waiting for an activity do not count against the throttle. Scale to zero is supported (no workers; only the scale controller and storage remain). [V]
* **Spinnaker Orca (Keiko):** stateless, horizontally scalable; progress is made by **fine-grained messages** (StartStage, RunTask, CompleteExecution...) with a **delay queue** (deliver now or later, reschedule); a single-threaded QueueProcessor polls "ready" messages and fills a worker thread pool; each message type has a handler; messages reference executions by id. [V] There is no per-run process: the run's state is in the store and every message is handled by whichever instance gets it.

### 3.8 Dagster, Prefect, Airflow (class E and relatives)

* **Dagster:** a **run queue** in the daemon; `max_concurrent_runs` (default **10** in the examples, -1 unlimited, 0 stops launching), `tag_concurrency_limits`, FIFO with priorities, a dequeue interval. [V search] **K8sRunLauncher** makes a **Kubernetes Job per run**, an isolated run worker; with **k8s_job_executor** that run worker launches each **step as a Kubernetes Job**, inheriting the pod configuration of the run's Job; `max_concurrent` limits step pods **per run and is not global**, default no limit. [V] A two-tier variant has the run worker submit steps to Celery queues. [V search]
* **Prefect:** a **worker polls a work pool** and creates a **Kubernetes Job per flow run**; tasks run **inside that pod**; concurrency limits are set on work pools and queues. [V]
* **Airflow:** **pools** give N *slots* (`default_pool` has 128); runnable tasks beyond the slots wait *queued*, released by **priority weight**, not strictly FIFO; a task can take several slots. [V]
* Relevance: Dagster is the closest relative of S0 (a Pod per run that leads the run, a run queue with a concurrency cap, a per-run cap on step pods that is not an organisation cap).

### 3.9 TeamCity (class A, with a Kubernetes executor)

* **Queue:** the server's build queue; a build is given to a compatible agent only when one is idle, never pre-assigned; among idle agents the one with the shortest **estimated duration** (history of that agent, five builds by default) wins, then CPU rank. [V]
* **Queue optimisation:** a build with the same changes and properties is not queued twice; newer build chains replace older queued ones; queued builds are replaced by equivalent started ones; builds queued for 15 days with no compatible agent are cancelled. [V]
* **Priority classes** from -100 to 100, and a waiting build's priority **grows with its waiting time**, so low priority never starves. The queue holds 6 000 builds by default; at the limit automatic triggering pauses. [V]
* **Agents** connect to the server: "an agent establishes an HTTP(S) connection to the TeamCity Server, and polls the server periodically for server commands". [V]
* **Multinode:** a main node and secondary nodes on one database and a shared data directory (NFS or SMB); the main node processes the queue; secondary nodes can take the processing of build data, VCS polling, triggers and the UI; agents move to a secondary node after about 10 minutes without the main one; a separate node for builds is needed above about 400 agents. [V]
* **Kubernetes, two ways.** (a) *Cloud profiles:* a pod per agent instance, "Max number of instances" per image, idle termination (`terminateIdleMinutes` 30 in the example). (b) ***Kubernetes executor*** (external executor mode): TeamCity "collects a list of build steps with their parameters, generates a pod definition, and submits it"; **each build step is a container of that pod**; there is no classic agent; "Maximum number of builds" caps the builds in the cluster, beyond it builds stay queued; the licence counts native and executor builds together; RBAC: Pods get/create/list/delete; one Kubernetes integration per project; no Windows, no Docker-in-Docker. [V]
* **Kotlin DSL** runs **only when a settings commit appears**, to produce the project model: "DSL scripts do not have direct control on how builds are executed". On the server it compiles in a sandbox (cannot read outside `.teamcity`, no network, no subprocesses, no native libraries, no internal reflection), at most 10 compilations at once; or it runs on an agent without these restrictions. [V]
* Relevance: the Kubernetes executor is the product shape "the server makes **one Pod per build, one container per step**"; the queue has features CiNim lacks (ageing priority, duplicate suppression, agent choice by estimated duration); the code (DSL) makes configuration, it does not orchestrate a running build.

### 3.10 Atlassian Bamboo and Bitbucket Pipelines (class A)

* **Bamboo:** a server with remote agents; since 9.3 (June 2023) **ephemeral agents**: "short-lived remote agents that start on demand inside a Kubernetes cluster to carry out a single build or deployment", their capabilities and pod layout set by templates. Bamboo Data Center reaches end of life on 28 March 2029. [V search] **Bamboo Java Specs** are run under a Java security manager by default since 6.3: no network, no running other programs, no reading or writing files; one thread is privileged (`BambooSpecsSecurityManager`). [V search] The Java security manager itself has been deprecated and then disabled in recent JDKs, so this sandbox has no future in Java. [K]
* **Bitbucket Pipelines:** YAML; at most **100 steps per pipeline**; 120 minutes per step; self-hosted runners share **one step queue per workspace of up to 1 000 steps**; the number of steps building at once is the plan's runner concurrency (since runner 5.x, further steps queue even when more runners are registered); queue analytics show waiting times; an autoscaler for runners on Kubernetes exists. [V and V search]

### 3.11 Harness CI and Semaphore (class A)

* **Harness:** the **Delegate** runs in the customer's cluster and connects **out** to the Harness Manager (HTTPS/WSS), heartbeat every minute; `DELEGATE_TASK_CAPACITY` limits the tasks a delegate runs at once (without it all run in parallel); about 10 parallel deployments per delegate of 2 GB / 0.5 CPU; scale by replicas, autoscaling discouraged. [V] **CI on Kubernetes: one pod per Build stage**, the steps are containers in it (sequential or parallel), the pod is sized for the stage's maximum including parallel steps; the delegate creates it; a "lite engine" inside talks to the delegate on port 20001; initialisation timeout 8 minutes. [V]
* **Semaphore:** an `agent-k8s-controller` watches the job queue of the agent types whose Secrets are in its namespace and starts agents on demand, scaling to zero; per-job pod details and limits were not read. [S]

### 3.12 Travis CI, AWS CodePipeline and CodeBuild

* **Travis CI:** each job in a fresh VM or LXD container. Architecture (public repositories and a case study, possibly dated): **Hub enqueues jobs and enforces quality of service such as concurrent builds per user**; the scheduler hands job payloads to job-board over HTTP; workers (`POOL_SIZE` jobs each) send heartbeats to job-board to **claim jobs and renew claims**; RabbitMQ connected the components. [S]
* **AWS CodePipeline:** an **execution mode** per pipeline: **SUPERSEDED** (default; a newer execution overtakes an older one), **QUEUED** (one by one in order; V2 pipelines), **PARALLEL** (independent; V2; no stage rollback). [V search]
* **AWS CodeBuild:** a quota of concurrent builds per compute type (some default to 20); above it builds **queue**, the queue holds at most **5x the concurrent limit**, and a queued build that does not start within its queue timeout (default **8 h**, settable 5 min to 8 h) is removed; a project with its own concurrent limit returns an error instead of queueing. [V search]

### 3.13 Dagger (a programmable engine, class F)

* Not a CI server: pipelines are code in Go, Python, TypeScript or PHP SDKs. The CLI opens a session with the engine; each session has its own GraphQL server; **modules (user functions) run in containers inside the engine** and call the same session's API back; every request becomes a DAG of low-level operations, cached. Isolation is by containers; the documentation read gives no sandbox details. [V]

## 4. Comparison tables

### 4.1 Where the logic of a run executes

| Product | Where | Lifetime of the process | State |
|---|---|---|---|
| GitHub Actions, GitLab, Azure, CircleCI, Woodpecker, Concourse | in the server, declarative | no per-run process | in the server's database |
| Jenkins | controller JVM, a thread per run (flyweight) | the run | program state on disk, saved often (durability modes) |
| Buildkite | the customer's agent (dynamic pipelines) or declarative | the upload job | in the SaaS |
| Tekton, Argo | controller reconcile loop | no per-run process | in custom resources (etcd) |
| Temporal, Durable Functions | worker, **replayed** on each task, cached by stickiness | a cache entry | history in the service |
| Spinnaker Orca | any Orca instance, per message | one message | store |
| Dagster, Prefect | **a Pod per run** (run worker / flow-run pod) | the run | in the Pod, plus the instance database |
| TeamCity, Bamboo, Bitbucket, Travis, CodePipeline | in the server, declarative (TeamCity's Kotlin DSL and Bamboo's Java Specs run once to make the configuration) | no per-run process | in the server's database |
| Harness | the Manager (SaaS) plans; the delegate in the customer's cluster executes | a pod per stage | in the Manager |
| Dagger | user functions in containers inside the engine | the session | engine cache |
| **S0** | **a conductor Pod, one run at a time** | the run, or 50 runs of one process | memory + journal in the core |

### 4.2 The queue

| Product | Queue lives in | Pull or push | Fairness / priority |
|---|---|---|---|
| GitLab | PostgreSQL table `ci_pending_builds` | runner long-polls the server | prefer projects with fewer running jobs |
| GitHub ARC | GitHub's service | listener long-polls | by job label match |
| Buildkite | the SaaS queue | agent polls; **streaming push** to idle agents | by queue / agent tags |
| Azure Pipelines | the service's pool queue | agent long-poll | by pool; parallel-job slots |
| Jenkins | the controller's build queue | server assigns to a free executor | by queue order |
| Concourse | PostgreSQL (jobs and builds) | web node schedules to workers | locks among ATCs |
| Argo | the controller's informers | controller | **priority** among pending workflows |
| Kueue | custom resources | admission controller | fair sharing across a cohort, priority |
| Temporal | persisted task queues (4 partitions) | worker long-polls | none by default; sticky routing |
| Durable Functions | partitioned control queues, work-item queue | workers own partitions | by partition |
| Orca | delay queue (Keiko) | instances poll | oldest ready message |
| Dagster | run queue in the daemon | the daemon dequeues | tag limits, priority |
| TeamCity | the server's queue (database) | agent polls; or the server submits a pod (executor) | priority classes with **ageing**, duplicate suppression, agent chosen by estimated duration |
| Bitbucket | one step queue per workspace (up to 1 000 steps) | runners | plan concurrency |
| Travis | Hub and job-board | workers claim with heartbeats | concurrent builds per user (QoS in Hub) |
| CodeBuild / CodePipeline | the service | the service | queue of 5x the limit, 8 h timeout; pipeline modes superseded / queued / parallel |
| **S0** | run queue in the core; step queue **in the conductor** | the controller pulls from the core; the conductor asks the controller | per organisation / run limits |

### 4.3 Concurrency limits

| Product | Global | Per tenant / project | Per run |
|---|---|---|---|
| GitHub | per plan 20-500 jobs | concurrency groups | matrix `max-parallel`; 256 jobs |
| GitLab | runner `concurrent`; instance limits | fair scheduling by project; `resource_group` | `parallel` (200 per [K]) |
| Buildkite | agents available; controller `max-in-flight` 25 | concurrency groups | matrix limits 50 jobs |
| Argo | `parallelism` | `namespaceParallelism` | template/workflow `parallelism` |
| Airflow | pool slots (128 default) | per-DAG settings | per-run settings |
| Dagster | `max_concurrent_runs` 10 | tag limits | executor `max_concurrent`, not global |
| Temporal | worker slots, rate limits | namespaces | history 51 200 events |
| Kubernetes | node capacity | **ResourceQuota** per namespace (403) / Kueue ClusterQueue | none |
| TeamCity | licence; executor "Maximum number of builds" | agent pools, priority classes | build chains |
| Bitbucket | plan runner concurrency; 1 000 queued steps | workspace | 100 steps per pipeline |
| CodeBuild | 20 per compute type (some types), queue 5x | project limit (an error, not a queue) | none |
| Harness | delegate task capacity | none read | the stage pod |
| **S0** | profile `step_pod_limit` (new) | conductors 3 per organisation | `run_pod_limit` 20%; 200 steps |

### 4.4 Pods and scale to zero

| Product | Pod model | Scale to zero / min |
|---|---|---|
| GitHub ARC | ephemeral runner Pod per job; listener always on | `minRunners` idle (0 allowed); max `maxRunners` |
| GitLab K8s executor | pod per job; pause pods to pre-warm | the runner manager always runs |
| Buildkite stack | Job per job; `max-in-flight`; `job-ttl` 10 min | the controller always runs |
| Jenkins K8s | pod per agent, `idleMinutes` reuse | agents scale from 0; the controller always runs |
| Durable Functions | workers | scale to zero supported |
| Dagster / Prefect | **Pod per run** | the daemon / worker always runs |
| TeamCity | cloud profile: pod per agent instance, max instances; **executor: pod per build, container per step** | cloud agents idle-terminated (30 min in the example) |
| Bamboo | ephemeral agent: pod per build or deployment | on demand |
| Harness | **pod per stage, container per step** | the delegate always runs |
| CircleCI | container runner: pod per task with an injected task agent | the container agent always runs |
| Semaphore | agents started on demand by a controller | scales to zero |
| **S0** | conductor Pod per run (one run per conductor) | min 0, idle 5 min |

## 5. Sandboxes for pipeline logic

The purposes differ: **determinism** (so that replay gives the same calls), **security** (so that a tenant's code cannot harm the platform) and **resource limits**. Few products ask the sandbox for all three.

| Product / runtime | Language | Mechanism | Determinism | Security boundary? | Resource limits |
|---|---|---|---|---|---|
| **CiNim (S0, today)** | Lua 5.4 | `io`, `os`, `debug`, `dofile`, `loadfile`, `package.loadlib` removed; `load` text only; fixed string hash seed; ordered `pairs`; `math.random`, time through journaled calls; write-protected globals; process with seccomp, no network, rlimits (PIP-005, SEC-007) [C] | **by construction** | intended yes, defence in depth by process isolation | 64 MiB Lua heap by a custom allocator, 50 M instruction budget by hook (PIP-006) [C] |
| **Redis** | Lua 5.1 embedded | restricted libraries, no `require`, globals blocked, `os` reduced to `os.clock` [V] | via effects replication | the manual says the protection against globals "attempts to prevent accidental misuse"; circumventing it "isn't hard" with the debug functions [V]. **CVE-2025-49844** ("RediShell"): a Lua garbage-collector use-after-free allowing escape and remote code execution, in code about 13 years old; patched 3 Oct 2025 [V search] | script time limit (busy script) |
| **Roblox Luau** | Luau (Lua 5.1 dialect) | libraries `io`, `package`, `debug` removed, `os` stripped; built-in tables **read-only** at VM level; a globals table per script; `getfenv/setfenv` remain a problem; separate VMs for trusted and untrusted code advised [V] | not a goal | designed for untrusted scripts | an **interrupt** callback the VM must call (a 10 s watchdog); memory by the host's allocator [V] |
| **Starlark** (Bazel, Drone, Tilt, Buck2) | Python subset | deterministic, **hermetic**, no recursion or unbounded loops by default, globals **frozen** after load, shared data immutable so interpreters run in parallel threads without data races [V] | **by language design** | hermetic = no I/O; "Python is notoriously difficult to sandbox" is the stated reason for Drone's choice [V search] | starlark-go: `SetMaxExecutionSteps`, `Cancel`; **no memory limit** in the API [V] |
| **Temporal TypeScript SDK** | JavaScript | a V8 context per workflow: first `isolated-vm` (e.g. `memoryLimit: 8` MB in the example), now the Node **`vm`** module; `Date`, `Math.random`, `setTimeout` replaced by deterministic versions; code bundled by webpack; no `fs`/network [V] | **by replacement of APIs** | `vm` is not a security boundary; the point is determinism | memory limit per isolate in the old design |
| **Temporal Python SDK** | Python | a fresh `exec` namespace per run; modules **reloaded for every workflow run** (passthrough for known-safe modules); proxy objects block known non-deterministic calls [V] | partial | "a determinism tool, not a security boundary"; "not completely isolated" [V] | none |
| **Temporal Go / Java SDKs** | Go, Java | no sandbox; rules plus replay and linters [K] | by discipline | none | none |
| **Azure Durable Functions** | .NET, JS, Python... | orchestrator code constraints (no I/O, no threads); analyzers; replay with caching; forced replay in development detects violations [V] | by discipline + replay | none | per-worker throttles |
| **Jenkins** | Groovy | CPS transform + Script Security allow-list sandbox; admin approvals [V] | CPS saves state, not determinism | allow-list; history of bypasses [S] | none (JVM) |
| **TeamCity** | Kotlin DSL | compiled on a settings commit, on the server in a sandbox (no files outside `.teamcity`, no network, no subprocesses, no native libraries, no internal reflection; 10 compilations at once) or on an agent without limits [V] | n/a (makes configuration) | yes, on the server | 10 concurrent compilations |
| **Bamboo** | Java Specs | a Java security manager since 6.3: no network, no running programs, no file access; one privileged thread [V search]; the security manager is deprecated and disabled in recent JDKs [K] | n/a (makes configuration) | yes, while Java allows it | none read |
| **Cloudflare Workers** | JavaScript/Wasm | **V8 isolates**, thousands per process; one isolate serves many requests until it passes the limit [V] | n/a | designed for hostile tenants (plus process layers) | **128 MB per isolate**, CPU time per request (30 s default on paid, 5 min max), subrequest limits [V]; an isolate costs about 2 MB against 30-50 MB for a container [S] |
| **GitHub Actions, GitLab** | YAML + expressions | no user code in the service; GitLab server-side config parsing [K] | n/a | no code to sandbox | limits on matrix, jobs |
| **Buildkite** | any language in the agent | the customer's own process | n/a | the customer's | n/a |

**Observations.** (1) The designs that run tenant code **inside the platform** and replay it (Temporal, Durable Functions, CiNim) all get determinism by **replacing or forbidding** APIs; none relies on the sandbox for security alone. (2) The products that need hostile-tenant security (Workers, Roblox) use **isolates or per-script VMs plus process layers**; Redis shows what a Lua escape means for a server that shares its address space. (3) Starlark gives determinism and hermeticity by language design, but has **no memory limit** in its Go implementation. (4) S0 puts the Lua process in a **Pod of the tenant's namespace**, so the process boundary is a Kubernetes boundary (cgroup, seccomp, NetworkPolicy); this is stronger than what Temporal's workers or Jenkins offer, and comparable to Dagster's run worker.

## 6. Facts for comparison with S0

* **Pod per run is normal in class E.** Dagster and Prefect pay one Pod per run; Dagster additionally has the run worker launch **step Jobs** with a **per-run** cap and **no global cap** by default, and a run queue with `max_concurrent_runs` default 10. S0 differs by an organisation-level and a per-run cap together.
* **Min/max runners with a long-poll listener** (ARC) is the production pattern for "start Pods when the queue has work, keep N idle". Its trigger is a **message from the vendor's queue**, not a periodic poll of the controller.
* **A controller that bounds Pods in flight and counts Pending ones** exists: Buildkite `max-in-flight` 25. A Kubernetes **ResourceQuota** does the same at admission and answers **403**.
* **Running the orchestration for free on the central process** (Jenkins flyweight executors, Orca instances, Temporal workers with sticky cache) has no per-run Pod cost; its price is central memory (Jenkins) or replay cost (Temporal, bounded by sticky caching).
* **State in memory vs replay:** Temporal's sticky queue and Durable Functions' extended sessions exist **precisely** to keep a run on one worker and avoid replay; the fallback is replay. S0's "one run in one process" is that, by construction, with a 5-minute bound.
* **Bounded history:** Temporal 51 200 events / 50 MB; GitHub 256 matrix jobs; Buildkite 50 matrix jobs; CiNim's 200 steps per run is of the same order and `ci.run` corresponds to Temporal's child workflows / `Continue-As-New`.
* **Queue in a database table** (GitLab) works at very large scale after a redesign from a join on a wide table to a narrow denormalised table; a Redis list was considered and not used.
* **Scaling the controller:** Argo's controller cannot scale out; it is sharded by namespace or instance id and has an API rate limit and a Pod-creation rate limit. S0 already has one controller per organisation.
* **Stateless orchestration with a delay queue** (Orca) is an alternative to a process per run: every transition is a message, any instance handles it.

* **One Pod per build, one container per step** (TeamCity's Kubernetes executor, Harness CI's pod per stage) instead of a Pod per step: the steps share the pod's workspace without a volume claim, the scheduler places one Pod per build; the price is a pod sized for the largest step (or the parallel sum) and a build that cannot spread over nodes. CiNim makes a Pod per step and shares a volume.
* **Mature queues** have **ageing priority** (TeamCity), **suppression of duplicate builds** and replacement of older chains (TeamCity), and **execution modes** superseded / queued / parallel (CodePipeline); the last is CiNim's open `concurrency: cancel_previous`.
* **Server-side quality of service plus worker-side capacity** is the usual split: Travis (Hub limits concurrent builds per user, a worker has a pool size), CodeBuild (account quota, a queue of 5x with an 8 h timeout), Bitbucket (plan concurrency, 1 000-step queue), Harness (delegate task capacity).
* **Code that runs only to make configuration** (TeamCity Kotlin DSL, Bamboo Java Specs) runs in a restricted sandbox and **never during the build**. CiNim's Lua runs during the run and steers it: the Jenkins model, not TeamCity's.

## 7. Candidate schemes to evaluate (S0 is the owner's)

* **S0. Conductor Pod per run, in the organisation's namespace, relay through the controller** (`docs/conductors.md`). Borrows: Dagster / Prefect (Pod per run), ARC (min/max, scale on demand), Buildkite (controller bounds Pods in flight).
* **S1. Keep the shared executor service, add keys and a real lease** (`docs/parallel.md` phase 1). Borrows: Temporal workers (shared workers, sticky cache), Jenkins flyweight (no per-run cost). Cheapest; the isolation and per-organisation caps are weakest.
* **S2. Stateless message-driven orchestration in the core** (Orca / Keiko): each state change (step finished, timer, approval) is a queue message; any core instance replays the journal of the run to the next call and sleeps; sticky caching optional. No per-run Pod. Borrows: Orca, Temporal sticky queues, Durable Functions partition affinity.
* **S3. Kubernetes-native**: runs and steps are custom resources; limits by **ResourceQuota** (count/pods) and, if needed, **Kueue**; a controller per organisation reconciles; the Lua logic runs in the controller or a sidecar. Borrows: Tekton, Argo, Kueue.
* **S4. S0 with a pull listener (ARC pattern):** a small always-on **listener** per organisation long-polls the core, and creates conductors on a message; the conductor talks to the core directly (or through the listener). Borrows: ARC. Removes the periodic poll and the question of who admits.
* **S5. Logic in the user's Pod**: the pipeline is a program run in a Pod made for the run (Dagger / Buildkite dynamic pipelines / Prefect flow-run pod); the platform sees steps as API calls. Borrows: Buildkite, Prefect. Gives up the platform's own sandbox and journal.
* **S6. S0 with several runs per conductor** (`runs_per_conductor` > 1) and a shared per-organisation conductor pool of a fixed size: fewer Pods, more state per process. Borrows: Durable Functions workers, Woodpecker `MAX_WORKFLOWS`.

## 8. Criteria (from the specification and the owner)

1. **Isolation of tenant code** (SEC-007) and rights (SEC-010: only the controller holds them).
2. **The core knows and controls everything** (D-49, RUN-016): visibility of queued steps, limits as policy, settings from the core.
3. **Correctness under failure** (PIP-004, T-03): lost executor, lost controller, core restart; no step made twice; the journal and its hash chain trusted.
4. **Scale** (NFR-006): 1 000 concurrent steps and 100 000 runs a day per shard; Pod count, API-server churn, node Pod density.
5. **Latency**: time from run creation to the first step (cold start, polling intervals), step start (RUN-013).
6. **Cost at rest**: Pods and memory for organisations with no runs; with many organisations in a shard.
7. **Fairness and limits**: per organisation / group / build / run; no starvation; no deadlock (a parent waiting for a child).
8. **Simplicity**: the scheme the owner can explain and operate; number of new components and protocols.
9. **Memory and soak** (NFR-013): bounded growth; recycling.
10. **Upgrade path** from today's code (`docs/conductors.md` section 10, `docs/parallel.md`).

## 9. How the facts were checked, and what is missing

* The documents were read through a page-fetch tool that returns a **summary** made by a smaller model; where it returned nothing or contradicted itself the item is marked [S] or [K], or was left out. One summary was wrong on a point of Kubernetes (it said Pods stay Pending when a quota rejects them; the page says the API server rejects the creation with 403), and was not used.
* **Not confirmed, to be checked before relying:** how GitHub's own queue works inside the service; CircleCI runner's polling interval and `maxConcurrentTasks`; Gitea `capacity` and `fetch_interval`; Dagster's `max_concurrent_runs` default (10 in the example configuration, from a search summary); the GitLab `parallel` limit (200) and `needs` details; Jenkins `containerCap` defaults; Temporal's default workflow cache size and `maxConcurrentWorkflowTaskExecutions`; how Drone's conversion extension is sandboxed in practice (the documentation read does not say); Woodpecker's server queue internals; Tekton's real concurrency story (Pipelines-as-Code has a concurrency limit, not read).
* **Not researched:** Cadence, Restate, Inngest, DBOS, Prefect's server queue, Flyte, Kubeflow, Volcano, Knative / KEDA scale-to-zero details, Argo's `Synchronization` internals.
* **Added after the owner's remark and still thin:** Semaphore's controller limits and pod model; Travis CI's present architecture (the sources are older repositories and a case study); limits of Bamboo's ephemeral agents; how Harness bounds the number of stage pods.
* The numbers about the memory of a conductor are **estimates** (`docs/conductors.md` section 13); only the 13.4 MB RSS of the soak harness is measured.

## 10. Sources

* GitHub: [ARC concepts](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller), [runner scale set values](https://raw.githubusercontent.com/actions/actions-runner-controller/master/charts/gha-runner-scale-set/values.yaml), [Actions limits](https://docs.github.com/en/actions/reference/limits)
* GitLab: [epic 5909, pending builds table](https://gitlab.com/groups/gitlab-org/-/epics/5909), [issue 218640, queueing](https://gitlab.com/gitlab-org/gitlab/-/issues/218640), [Runner configuration](https://docs.gitlab.com/runner/configuration/advanced-configuration/), [Kubernetes executor](https://docs.gitlab.com/runner/executors/kubernetes/)
* Buildkite: [job dispatch](https://buildkite.com/docs/agent/self-hosted/configure/job-dispatch), [agent-stack-k8s controller configuration](https://buildkite.com/docs/agent/self-hosted/agent-stack-k8s/controller-configuration), [agent-stack-k8s](https://github.com/buildkite/agent-stack-k8s)
* Jenkins: [scaling Pipeline](https://www.jenkins.io/doc/book/pipeline/scaling-pipeline/), [script approval](https://www.jenkins.io/doc/book/managing/script-approval/), [flyweight and heavyweight executors](https://docs.cloudbees.com/d/kb-360012808951), [Kubernetes plugin](https://github.com/jenkinsci/kubernetes-plugin)
* CircleCI: [container runner](https://circleci.com/docs/guides/execution-runner/container-runner/); Woodpecker: [agent configuration](https://woodpecker-ci.org/docs/administration/configuration/agent); Gitea: [act_runner](https://docs.gitea.com/usage/actions/act-runner); Concourse: [internals](https://concourse-ci.org/docs/internals/); Azure Pipelines: [agents](https://msdn.microsoft.com/library/ee330987)
* Tekton: [PipelineRuns](https://tekton.dev/docs/pipelines/pipelineruns/); Argo: [parallelism](https://argo-workflows.readthedocs.io/en/latest/parallelism/), [scaling](https://argo-workflows.readthedocs.io/en/latest/scaling/); Kubernetes: [ResourceQuota](https://kubernetes.io/docs/concepts/policy/resource-quotas/); Kueue: [introduction](https://v1-34.docs.kubernetes.io/blog/2022/10/04/introducing-kueue)
* Temporal: [task queues](https://docs.temporal.io/task-queue), [sticky execution](https://docs.temporal.io/sticky-execution), [workflow cache](https://docs.temporal.io/develop/worker-performance/workflow-cache), [event history limits](https://docs.temporal.io/workflow-execution/event), [Python sandbox](https://docs.temporal.io/develop/python/best-practices/python-sdk-sandbox), [isolated-vm note](https://temporal.io/blog/intro-to-isolated-vm), [TypeScript workflows](https://docs.temporal.io/develop/typescript/workflows/basics)
* Azure: [Durable Functions performance and scale](https://learn.microsoft.com/en-us/azure/azure-functions/durable/durable-functions-perf-and-scale), [orchestrations](https://learn.microsoft.com/en-us/azure/azure-functions/durable/durable-functions-orchestrations); Spinnaker: [Orca overview](https://spinnaker.io/docs/community/contributing/code/developer-guides/service-overviews/orca/)
* Dagster: [dagster-k8s](https://dagster.io/docs/api/libraries/dagster-k8s), [managing concurrency](https://dagster.io/docs/guides/operate/managing-concurrency); Prefect: [Kubernetes worker](https://docs.prefect.io/v3/how-to-guides/deployment_infra/kubernetes); Airflow: [pools](https://airflow.apache.org/docs/apache-airflow/stable/administration-and-deployment/pools.html)
* Sandboxes: [Redis Lua API](https://redis.io/docs/latest/develop/programmability/lua-api/), [CVE-2025-49844](https://www.wiz.io/vulnerability-database/cve/cve-2025-49844), [Luau sandboxing](https://luau.org/sandbox), [Starlark specification](https://github.com/bazelbuild/starlark/blob/c63d43647e651381fde7fbe004b0ac1a726a4240/spec.md), [starlark-go](https://pkg.go.dev/go.starlark.net/starlark), [Drone Starlark](https://docs.drone.io/server/extensions/starlark/), [Cloudflare Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
* TeamCity: [build queue](https://www.jetbrains.com/help/teamcity/build-queue.html), [Kubernetes setup](https://www.jetbrains.com/help/teamcity/setting-up-teamcity-for-kubernetes.html), [Kubernetes executor](https://www.jetbrains.com/help/teamcity/2026.2/kubernetes-executor.html), [build agent](https://www.jetbrains.com/help/teamcity/build-agent.html), [Kotlin DSL](https://www.jetbrains.com/help/teamcity/kotlin-dsl.html), [multinode setup](https://www.jetbrains.com/help/teamcity/multinode-setup.html)
* Bamboo: [ephemeral agents](https://confluence.atlassian.com/bamboo/ephemeral-agents-1236444139.html), [repository-stored Specs security](https://confluence.atlassian.com/display/BAMBOO0602/Repository-stored+Bamboo+Specs+security), [BambooSpecsSecurityManager](https://docs.atlassian.com/bamboo-specs/10.1.0/com/atlassian/bamboo/specs/maven/sandbox/BambooSpecsSecurityManager.html), [licensing and end of life](https://www.atlassian.com/licensing/bamboo); Bitbucket: [runner concurrency and step queue](https://support.atlassian.com/bitbucket-cloud/docs/configure-runner-concurrency-and-inspect-step-queue)
* Harness: [delegate overview](https://developer.harness.io/docs/platform/delegates/delegate-concepts/delegate-overview), [Kubernetes build infrastructure](https://developer.harness.io/docs/continuous-integration/use-ci/set-up-build-infrastructure/k8s-build-infrastructure/set-up-a-kubernetes-cluster-build-infrastructure); Semaphore: [self-hosted agents](https://semaphore.io/product/self-hosted-agents)
* Travis CI: [build environment](https://docs.travis-ci.com/user/reference/overview/), [worker](https://pkg.go.dev/github.com/travis-ci/worker), [RabbitMQ case study](https://blogs.vmware.com/tanzu/continuous-integration-scaling-to-74-000-builds-per-day-with-travis-ci-rabbitmq/); AWS: [CodePipeline execution modes](https://docs.aws.amazon.com/codepipeline/latest/userguide/execution-modes.html), [CodeBuild builds](https://docs.aws.amazon.com/codebuild/latest/userguide/builds-working.html), [CodeBuild quotas](https://docs.aws.amazon.com/codebuild/latest/userguide/limits.html)
* Dagger: [internals](https://devel.docs.dagger.io/api/internals); CircleCI: [runner concepts](https://circleci.com/docs/guides/execution-runner/runner-concepts); Drone: [runner capacity](https://docs.drone.io/runner/kubernetes/configuration/reference/drone-runner-capacity/)
