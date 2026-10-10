# Parallel branches: `ci.parallel`, `ci.matrix` (design)

Requirements: PIP-003 (call journal), PIP-004 (replay), PIP-006 (limits), PIP-009 (matrix), RUN-006 (cancellation), RUN-008 (lease), STO-001 (run volume).
**Status: a design, nothing of it is built.** Where the place of the conductor matters (waiting, the queue of steps, the lease) `docs/conductors.md` decides and this document follows it. It is the first of the open items of the roadmap (stage M1, "pipeline breadth") and the base of `ci.spawn`, cancellation and `ci.finally`.

## 1. Why the present model cannot take it

Four things in the code assume that a run does one thing at a time:

1. **The identity of a call is its position.** `replay.execute` numbers the host calls 0, 1, 2 … and answers call *n* from journal entry *n*; the step of that call is `steps.ordinal = n`, and so are the name of its Pod and its log URL.
   Two branches that start together would both be call 0.
2. **A call that cannot be answered suspends the whole run** (`HostCallProc` returns `none`, `execute` returns `esSuspended`). There is no "this one waits, go on with the other".
3. **The core leases a run only when it has no step in flight** (`nextRunnableRun`: no step `PENDING`, `STARTING` or `RUNNING`). With branches there is always a step in flight while another branch could already go on.
   (There is no real lease either: the token is `t-<run id>` and is not checked, RUN-008.)
4. **Counters that the script keeps** (the key `job-N` of `ci.job`) count in the order in which the script runs, which with branches depends on timing.

## 2. What the script sees

```lua
local r = ci.parallel({
  unit = function() ci.job({image = "alpine"}, function(j) j:sh("make unit") end) end,
  lint = function() ci.job({image = "alpine"}, function(j) j:sh("make lint") end); return "clean" end,
}, { fail_fast = true, max_parallel = 3 })
-- r.unit.ok == true; r.lint.value == "clean"; a failed branch: r.x.ok == false, r.x.error == "step failed with code 3"
```

* A **branch** is a function with the same powers as `main`: `ci.job`, `j:sh`, `ci.log`, another `ci.parallel` (depth at most 4). Branches are a table `name = function` (or a list, named `1`, `2`, …); the order of `pairs` is the stable one of PIP-005.
* The **result** is a table, name → `{ok = true, value = <what the branch returned>}` or `{ok = false, error = <message>}`. A value must be plain data (a string, a number, a boolean, a table of those): it is journaled.
* **Failure.** Without `fail_fast` all branches run to the end; with `fail_fast` the first failure **cancels** the branches still running (their steps are stopped, section 6). Then `ci.parallel` raises `parallel: branches failed: a, b`, as a failed step raises, so that
  `pcall` and `ci.finally` work as they do now; `keep_going = true` returns the table instead. The error carries the table (`err.results`).
* `max_parallel` limits the branches that run at a time (default: the width, bounded by the execution profile's `max_parallel`, RUN-004). The next branch starts, in the order of declaration, when one has finished.
* `ci.matrix{axes = {...}, include = {...}, exclude = {...}, max_parallel = n, fail_fast = b}` builds the Cartesian product and calls `ci.parallel`; a branch is named `os=linux,arch=amd64` and receives its combination as the argument. It is pure (not journaled), and the expansion limit is checked at the call (PIP-006: a run has at most 200 steps in all, so the width is at most 200; `docs/conductors.md`).
* **Not in this design:** `ci.spawn` / `h:wait()` / `h:cancel()` (they use the same machinery and come after it), and run cancellation (RUN-006; only the cancellation of the steps of one run is needed here).

## 3. The identity of a call: a key, not a position

Every execution context has a **path**: `m` for `main`; the *k*-th `ci.parallel` call in a context `C` is `C.pK`, and its branch `b` is `C.pK[b]`. The *n*-th host call in a context is `C#n`. So `m#3` is the third call of `main`, and `m.p1[unit]#2` is the second call of
the branch `unit` of the first `ci.parallel`. The key of a `ci.job` is its path and its own counter: `m.p1[unit]/job-1`.

A key is a function of the **structure of the script** (which branch, which call in it) and never of timing, so a replay finds the same keys whatever order the answers came in. The counters (`job-N`, the number of calls) are per context, not global.

## 4. The journal

* `run_journal` gets a column `call_key` (unique per run). `seq` stays the position in which an entry was **appended**, which is the order of completion; the hash chain is over that order, as now, and `verify` is unchanged.
* **Replay** looks up the entry by key and checks that its kind and payload are what the script calls now (the `script_nondeterminism` of PIP-004, per key: `m.p1[unit]#2: the journal has job_sh(…), the script called j:sh(…)`).
* `ci.parallel` writes its own entries: `par_begin` (the names of the branches, so a script that changes its branches is caught) and `par_end` (the outcome of each). A cancellation that `fail_fast` decides is an entry too (`par_cancel`, with the branch that failed), so a replay makes the same decision.
* **Existing runs.** A row without a key is read as `m#<seq + 1>`: a script that never used a branch is sequential, and that is exactly the old numbering. Nothing is rewritten.

## 5. The branch scheduler (in the sandbox, Lua)

`ci.parallel` runs each branch as a coroutine of the same Lua state. A deterministic loop, in the order of declaration:

```
round: for each branch that may run (started, not parked, not finished): resume it until it makes a host call (key, kind, payload)
  ask the host: an answer  -> hand it to the branch, which goes on in this round
                pending     -> park the branch (it will ask the same call again in the next round)
  a branch that returns or raises is finished
after a round: if some branch moved, go on;  if all unfinished ones are parked, and nothing moved -> ask Nim to suspend the run
```

* The host answers a call in one of three ways, not two: **a result**, **pending** (the step waits or runs: park this branch) and, for the whole run, **suspend** (no branch can go on and the wait is long). Today `none` means suspend; it is split. With the conductor of `docs/conductors.md` a parked branch waits **in memory**: the run process blocks on its supervisor, to which the core pushes the run's events; suspension is only for waits longer than `run_wait_seconds` and for a wait on a child run. A sequential script (no `ci.parallel`) is the same loop with one branch.
* **Determinism.** The sequence of calls of **one** branch depends only on the results of its own earlier calls, so it is the same in every replay; the interleaving of the branches does not matter, because the identity of a call is its key. The two places where branches touch each other
  are `fail_fast` (journaled, above) and `max_parallel` (the next branch to start is always the first not started, in the order of declaration, so the set and the order of starts do not depend on timing either).
* Starting a branch is not an RPC; only the host calls inside it are.

## 6. The core

* `HostCall` gets `key`. The step of a `job_sh` is found or made **by key**: `steps.call_key` (unique per run) is new and `ordinal` is allocated by the core (the next integer of the run) instead of being the journal position; Pod names and the log URL keep using the ordinal.
* The answer of `job_sh`: the step finished → the result (and the journal entry, with the key); the step is in flight → **pending**; there is none → make it and answer pending.
* **The lease (RUN-008)** is that of `docs/conductors.md` section 6: a token and an attempt number per run, carried by every call; the core refuses a call of an older attempt, which closes the case of two conductors on one run. `runs` gets `lease_token`, `lease_attempt`, `lease_until` and `dirty`; `dirty` marks a suspended run whose wait has ended (a timer, an approval, a child run), which may be leased again. The present rule ("lease a run that has no step in flight") goes away.
* **Cancelling a step of a run** (`cancel_step`, a new host call, journaled): a `PENDING` step becomes `CANCELED` at once; one that runs is marked and the controller is told by the `CancelStep` it already knows (the Pod is deleted with a grace period, the shim receives SIGTERM, RUN-006); its result for the script is the error `canceled`.
  The run-level `POST /api/v1/runs/{id}:cancel` is the same operation for every step plus the end of the script (later).
* The controller takes the steps the core admits under the limits of `docs/conductors.md` section 4 (`pod_limit`, `job_pod_limit`, the run with the fewest steps in flight first) pushed to it by the core; the run volume's claim is still created once (idempotent).

## 7. Storage and shared files

* All branches share `/cicd/workspace` and `/cicd/state`. Writing the same file from two branches is the script's business; `workspace = "isolated"` (STO-002, not built yet) gives a job a directory of its own.
* With a `ReadWriteOnce` class the Pods of a run are kept on one node (pod affinity over the run label), so the parallelism of a run is that of the node; a `ReadWriteMany` class (NFS) spreads it, but a build Pod cannot mount such a volume (idmapped mounts, docs/deployment.md).
* **`$CICD_ENV` under parallelism.** A step reads the file when it starts; the lines that parallel branches append are interleaved and a later step sees all of those written before it started. To bring a value back to the script use `outputs` (`$CICD_OUTPUT`), not the env file.

## 8. Tests

* **Sandbox** (`tests/unit/tparallel.nim`, a fake host): the same script gives the same journal keys and the same result for every order of completion of its branches (all permutations of 3); the journal order differs, the keys do not; a script whose branches changed between a run and its replay is `script_nondeterminism` with the key;
  `fail_fast` cancels and the decision is replayed; `max_parallel` starts in the declared order; nesting and the depth limit; the width limit; a branch that raises; `pcall` around `ci.parallel`.
* **Journal** (`tjournal.nim`): the key lookup, the hash chain over the completion order, rows without a key.
* **Core** (integration against rqlite): a suspended run is leased again when its wait ends and not before; a call of an older attempt is refused; `job_sh` by key is idempotent; `cancel_step` on a pending step and on a running one.
* **A cluster:** three branches of `sleep 60` finish in about 60 s, not 180 s; a run whose conductor is killed in the middle continues without starting a step twice; `fail_fast` stops a running Pod; the logs and the graph of the steps are those of each branch.

## 9. Phases

1. **Identity.** Keys in the journal and the steps, the migration of old rows, per-context counters. The lease with token and attempt, the stored hash chain and the queue of steps with limits come from phase 1 of `docs/conductors.md`. Sequential scripts are unchanged; every present test must pass.
2. **`ci.parallel` and `ci.matrix`** with the pending answer, without `fail_fast`.
3. **`cancel_step` and `fail_fast`.**
4. After that: `ci.spawn`, run cancellation, `ci.finally`.

## 10. Questions for the owner

1. Is **raising** after the branches have ended (and `keep_going` to get the table) the right default for a failed branch? The alternative is to return the table and let the script look.
2. Is the **depth 4** of nesting and `max_parallel` = the profile's setting a good default?
3. Should the argument of a branch be only the combination (matrix), or a context object too (its name, its index)?
4. Is **phase 1 alone** worth a release first (it changes the journal and the lease, and nothing else), or should phases 1 and 2 go together?
