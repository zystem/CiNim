# Parallel branches: `ci.parallel`, `ci.matrix` (design)

Requirements: PIP-003 (call journal), PIP-004 (replay), PIP-006 (limits), PIP-009 (matrix), RUN-006 (cancellation), RUN-008 (lease), STO-001 (run volume).
**Status: a design, nothing of it is built; the identity of a step (section 3) was decided on 2026-10-10.** Where the place of the conductor matters (waiting, the queue of steps, the lease) `docs/conductors.md` decides and this document follows it. It is the first of the open items of the roadmap (stage M1, "pipeline breadth") and the base of `ci.spawn`, cancellation and `ci.finally`.

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

* A **branch** is a function with the same powers as `main`: `ci.job`, `j:sh`, `ci.log`, another `ci.parallel` (depth at most 200, inside the 200 steps of the run). Branches are a table `name = function` (or a list, named `1`, `2`, …); the order of `pairs` is the stable one of PIP-005.
* The **result** is a table, name → `{ok = true, value = <what the branch returned>}` or `{ok = false, error = <message>}`. A value must be plain data (a string, a number, a boolean, a table of those): it is journaled.
* **Failure.** Without `fail_fast` all branches run to the end; with `fail_fast` the first failure **cancels** the branches still running (their steps are stopped, section 6). Then `ci.parallel` raises `parallel: branches failed: a, b`, as a failed step raises, so that
  `pcall` and `ci.finally` work as they do now; `keep_going = true` returns the table instead. The error carries the table (`err.results`).
* `max_parallel` limits the branches that run at a time (default: the width, bounded by the execution profile's `max_parallel`, RUN-004). The next branch starts, in the order of declaration, when one has finished.
* `ci.matrix{axes = {...}, include = {...}, exclude = {...}, max_parallel = n, fail_fast = b}` builds the Cartesian product and calls `ci.parallel`; a branch is named `os=linux,arch=amd64` and receives its combination as the argument. It is pure (not journaled), and the expansion limit is checked at the call (PIP-006: a run has at most 200 steps in all, so the width is at most 200; `docs/conductors.md`).
* **Not in this design:** `ci.spawn` / `h:wait()` / `h:cancel()` (they use the same machinery and come after it), and run cancellation (RUN-006; only the cancellation of the steps of one run is needed here).

## 3. The identity of a step: a key inside, a number from a table, an id from the author

Decided on 2026-10-10 with the owner, after a look at how other systems do it (`docs/prior-art-queues-sandboxes.md` section 11).

### 3.1 The key of a call (internal)

Every execution context has a **path**: `m` for `main`; the *k*-th `ci.parallel` call in a context `C` is `C.pK`, and its branch `b` is `C.pK[b]`. The *n*-th host call in a context is `C#n`. So `m#3` is the third call of `main`, and `m.p1[unit]#2` is the second call of
the branch `unit` of the first `ci.parallel`. A key is a function of the **structure of the script** (which branch, which call in it) and never of timing, so a replay finds the same keys whatever order the answers came in. The counters are per context, not global. The journal finds its entries by this key (section 4).

### 3.2 The number of a step (what people and the protocol see)

A step has a number, `StepRef.seq` (`uint32`), which is its identity in the run: in the journal, in the name of its Pod, in the log URL, in the API and the UI. It is **given by a table made before the steps run** (3.4), not by the order in which they happen to start, and numbers need not follow each other.

* **Shape.** A plain integer. The table numbers the places where steps are made **in the order of the tree** (the order in which a deterministic pass meets them, branches in the order of declaration); a place that makes one step gets one number, a place that makes several gets a **block** of numbers (3.4). A sequential script is therefore numbered `0, 1, 2 …` as it is now.
* **Limits, by the owner's decision.** A run has **at most 200 steps**; `ci.parallel` has at most **200 branches**; nesting is at most **200 levels** deep (the same bound as `ci.run`, `docs/conductors.md`). More than 200 steps, found in the table pass or while the run goes, is an **error returned to the user** (`step_limit`) and the run ends. The bounds make the numbers small: at most 200 places with a block of at most 200 numbers, so every table number is below 40 000, and the numbers of the overflow (3.4) start at 100 000. They fit `uint32` (and `int32`) with room to spare, and keep a Pod name short. No structure is packed into the digits, because a nesting of 200 levels cannot be.
* **Stability.** The same script with the same parameters gets the same numbers in every run, and the same numbers in every replay of one run (the table is kept with the run). A script that is edited above a step may move its number; for a step that must keep a handle there is the id (3.3). In the UI a number is shown with the name of its branch or its id beside it (`lint · 3`).

### 3.3 The id of a step (the author's name)

`ci.job{id = "deploy"}` and `j:sh(cmd, {id = "lint"})` give the job or the step a name. It is the handle that outlives edits of the script: the API, the UI and the history of a step across runs can use it.

* **Length and form: 1 to 8 characters, letters and digits** (`A–Z a–z 0–9`), **starting with a letter**, so that an id can never be taken for a number in `GET /api/v1/runs/{id}/steps/{id-or-number}`. Case counts. A longer or otherwise formed id is refused at the call (`script_error`). Eight characters of letters and digits are 62⁸ names, far more than the 200 steps of a run can use.
* **It is an ordinary string that the script computes.** Authors build ids in loops and in nested `ci.parallel` from the loop variables, `id = "l" .. i .. j .. k` (the owner's use). The rule applies to the result: a result of more than 8 characters, or not of letters and digits, is refused at the call with the id in the message, and fitting several loop variables into 8 characters is made easy by `b58x(n)` and `b58xx(n)`: the integer as exactly one (0 to 57) or exactly two (0 to 3363, so 200 fits) characters of the Base58 alphabet (no `0 O I l`), in the order of their codes, so that `"a" .. b58xx(i) .. b58xx(j) .. b58xx(k)` is 7 characters and the ids of a loop sort in the order of the loop. They are pure functions, not journaled; a number that does not fit is an error. Best of all is `b58f(format, ...)`, which builds the whole id from a format that shows the length of every number: `id = b58f("a{xx}{xx}{xx}", i, j, k)` (`{x}` is one character, `{xx}` two). The format is checked as a whole before any number is looked at: at most 8 characters in all (the error says how many the format makes), a letter first, only these placeholders, one argument for each. So the length of an id is seen where it is written, and writing `"a" .. i .. j` by hand, which is the way to a conflict, has no reason left.
* **Unique in the run, and it is the author's business.** The platform does not rename and does not choose: a second step with an id already used fails the run at that call with `duplicate_id` and names both places. The author decides what the steps are called. (The table pass runs the script, so it finds the conflicts that happen on its path before the run starts.)
* The **name of a branch** of `ci.parallel` follows the same rule (it is the id of the branch), because authors compose those in loops too. The branches are the keys of a Lua table, which keeps the last of two equal keys without a word, so two branches of a loop that get the same name leave one branch, not an error. With ids composed of `b58x` and `b58xx` (fixed width) two different sets of loop variables cannot give the same id, and a formula that can is the author's mistake, as any repeated id is; the owner decided (2026-10-10) to keep the plain table and not to add a call that registers branches one by one. A repeated id of a **step** still fails with `duplicate_id`. The branches that `ci.matrix` makes are named by the platform from the values of the combination, are labels, and are not bound by the 8-character rule.
* The id does not change the number: the number says where the step is, the id says what it is.

### 3.4 The table

* **What it is.** Before a run is led, the script is run once in the sandbox against a **stub host**: every step succeeds with an empty result, `now` and `random` give fixed values, the parameters are the given ones completed with the defaults. The calls that `j:sh`, `ci.job` and `ci.parallel` make are recorded with their **place in the text** (line and column). The places are numbered in the order of the tree. A place that made one step gets one number; the pass executes the loops, so every instance that a loop makes with data that does not depend on results of steps (parameters, constants) is **seen with the id it computes** and gets its own number. A place that ran *n* > 1 times (a loop, a helper called more than once, a matrix) also gets a **block** of ⌈(*n*+1)/10⌉·10 numbers (capped at 200), so that a loop whose length depends on results has room (the exact rule is for the tests to settle).
* **Where it runs.** User Lua never runs in the core (SEC-007, `docs/conductors.md`): the table is made by the run process of the conductor before the first real call, sent to the core with the first host call and stored with the run (a record `table` in the journal, before everything else). A new run makes a new table. `POST /api/v1/pipelines:check` (PIP-016) and `cicd pipeline check` make the same table in a sandbox of their own and can show the plan of a run before it exists. More than 200 steps in the table pass is an error returned to the user before anything is made, and so is a repeated id on the path of the pass.
* **How a step finds its number.** The run asks the table for (place in the text, number of the call at that place). If it is there, that is the number. If it is not (a path the stub pass did not take, a loop that went on longer than its block, code made by `load`), the step takes the next free number of the **overflow** (100 000, 100 001 …); with more than 200 steps in all the run ends with `step_limit`. A run is never refused for the numbering alone. Replay does not depend on the table: it finds the entry by the key (3.1) and the number is in the entry.
* **What it cannot do.** The stub pass sees a different run when the script branches on a result of a step (`if r.code == 0`): the other path is found at run time, in the overflow. It costs one more execution of the script (NFR-014: 1 000 calls in 2 s).

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

* `HostCall` gets `key`. The step of a `job_sh` is found or made **by key**: `steps.call_key` (unique per run) is new, and `ordinal` is the **number from the table** (section 3.2) instead of the journal position, not an integer the core allocates; `steps.step_id` (the author's id, section 3.3, unique per run when set) is new too. Pod names and the log URL keep using the ordinal.
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
* **The table** (`ttable.nim`): the same script gives the same numbers on every run; a loop and a helper called twice get a block; a step on a path the stub pass did not take gets a number from the tail and the run goes on; more than 200 steps in the table pass or in the run is `step_limit`; a repeated id is `duplicate_id` and names both places; an id is 1..8 letters and digits starting with a letter; the largest number fits `uint32`; a sequential script is numbered `0, 1, 2 …` as before.
* **Journal** (`tjournal.nim`): the key lookup, the hash chain over the completion order, rows without a key.
* **Core** (integration against rqlite): a suspended run is leased again when its wait ends and not before; a call of an older attempt is refused; `job_sh` by key is idempotent; `cancel_step` on a pending step and on a running one.
* **A cluster:** three branches of `sleep 60` finish in about 60 s, not 180 s; a run whose conductor is killed in the middle continues without starting a step twice; `fail_fast` stops a running Pod; the logs and the graph of the steps are those of each branch.

## 9. Phases

1. **Identity.** Keys in the journal and the steps, the table (the stub pass, the numbers, the tail, the limits), the `id` option, the migration of old rows, per-context counters. The lease with token and attempt, the stored hash chain and the queue of steps with limits come from phase 1 of `docs/conductors.md`. Sequential scripts are unchanged; every present test must pass.
2. **`ci.parallel` and `ci.matrix`** with the pending answer, without `fail_fast`.
3. **`cancel_step` and `fail_fast`.**
4. After that: `ci.spawn`, run cancellation, `ci.finally`.

## 10. Questions for the owner

1. Is **raising** after the branches have ended (and `keep_going` to get the table) the right default for a failed branch? The alternative is to return the table and let the script look.
2. Is `max_parallel` = the profile's setting a good default? (Nesting is bounded by 200, as the owner decided.)
3. Should the argument of a branch be only the combination (matrix), or a context object too (its name, its index)?
4. Is **phase 1 alone** worth a release first (it changes the journal and the lease, and nothing else), or should phases 1 and 2 go together?
