# Triggers and launch parameters

Two things that make a run start by itself and with different inputs: **launch parameters** (the values a run is given when it starts) and **triggers** (a stored way to start a run by the clock, by a webhook call, or by hand). Requirements: PIP-012, VAR-002, VAR-003, TRG-001 to TRG-004 in `docs/specification.md`.

## Parameters

The script declares them, and a start gives values:

```lua
return ci.pipeline({
  params = {
    BRANCH  = ci.string{ default = "main", max_length = 60, pattern = "[%w%-_/.]+" },   -- a Lua pattern, matched against the whole value
    JOBS    = ci.number{ default = 4, min = 1, max = 64, integer = true },
    RELEASE = ci.bool{ default = false },
    TARGET  = ci.choice({ "staging", "production" }, { default = "staging" }),
    TICKET  = ci.string{ required = true },
  },
  main = function(run)
    ci.single["a"] {
      image = "alpine",
      steps = { step.sh["1"] { cmd = 'echo "building $BRANCH with $JOBS jobs for $TARGET"' } },     -- an ordinary environment variable
    }
    if run.params.RELEASE then ... end                                -- typed in the script
  end,
})
```

Start it with values:

```
POST /api/v1/runs
{"organization": "acme", "project": "team/backend", "commit": "main", "path": ".ci/pipeline.lua", "params": {"TICKET": "CI-7", "JOBS": 8, "RELEASE": true}}
```

What happens:

* The API checks only what it can without the script: a name is an environment variable name (`[A-Z_][A-Z0-9_]*`, not `PATH`, `LD_*`, `CICD_*` and the like), a value is a string, number or boolean of at most 1 KiB, 64 parameters and 4 KiB in all. Anything else is `400 invalid_params`.
* The executor then checks the values against the script's declarations, **before `main` runs**: a missing required parameter, a number out of range, a value that is not one of the choices, or a parameter the script does not declare ends the run as failed, with the parameter's name and the rule in the message (`GET /api/v1/runs/{id}` shows the state `FAILED`, no steps, and `failure: {code, message}`, here `script_error` and `parameter JOBS must be at least 1`). (Checking at the API, before the run exists, is the next section.)
* The complete set, defaults included, is journaled once and kept with the run (`GET /api/v1/runs/{id}` shows it as `params`). A replay after an executor restart gets the same values from the journal.
* Every step of the run gets them as plain environment variables of the container. They are in the Pod's specification, so **a parameter is not a place for a secret**: a step asks for those by name (`secrets = {"NAME"}`, `docs/secrets-masking.md`). A secret of the same name wins.

Not built: `ci.list`, `ci.map`, `ci.secret` parameters, the log header with the effective values (VAR-005).

## Checking before the run exists (PIP-016)

`POST /api/v1/runs` (and `POST /api/v1/pipelines:check`, which only checks) hands the script (read from git; `:check` may also be given a script to look at, since it runs nothing) and the parameters to a conductor of the organisation, which runs the script once against a stub host and tells what it found (docs/conductors.md, "The check of a script"). What is **certain** is refused with `400` and the code and words of the failure, as a run would end - `script_error` `parameter JOBS must be at least 1`, a syntax error, a forbidden global, `step_limit`, `duplicate_id` - and no run is made.

```
POST /api/v1/pipelines:check   {"organization": "acme", "script": "...", "params": {"JOBS": 0}}
-> 200 {"checked": true, "ok": false, "steps": 0, "failure": {"code": "script_error", "message": "parameter JOBS must be at least 1", "certain": true}}
-> 200 {"checked": true, "ok": true, "steps": 12, "params": {"JOBS": "8", "TARGET": "staging"}}      (the parameters a run would have, defaults completed)
-> 200 {"checked": false, "skipped": "no_conductor"}     (or busy, timeout, unavailable)
```

`dev`, `rw` and `admin` may check. A finding after a step has run on the stub (a script that branches on a step's result) is shown by `pipelines:check` as `certain: false` and does not stop a run. The check is skipped when the organisation has no conductor connected; the run then fails at its start as before. A **trigger** (schedule, webhook, manual) does not check when it fires: it makes the run directly.

## Triggers

All calls are an administrator's: `Authorization: Bearer <admin token>`.

### Schedule

```
POST /api/v1/organizations/acme/triggers
{"name": "nightly", "kind": "schedule", "schedule": "0 2 * * *", "project": "team/backend",
 "ref": "main", "params": {"TARGET": "staging"}, "concurrency": "abort_newest"}
```

Five fields, **UTC**: minute hour day-of-month month day-of-week. `*`, lists `1,15`, ranges `9-17`, steps `*/15` and `10-50/10`, names (`jan`, `mon`), and `@hourly @daily @weekly @monthly @yearly`. If both day fields are restricted a day matches when either does (as in Vixie cron). Core looks every 20 seconds. A core that was down fires a schedule **once** when it is back. Switching a schedule off and on again starts its clock from that moment.

### The script is read from git (D-63, D-73)

A script comes from git and from nowhere else: a run or a trigger that carries one in its body is refused (`script_not_accepted` for a run, "a script is read from git" for a trigger), so that every run has a history in git. A run and a trigger are of a **project** (D-68): the path of a leaf of the group tree that has a main repository, for example `cinim` or `ci/cinim` (`ci` is a group, a folder, never a project). The repository is the project's and is read at every firing, so changing it changes what the triggers read; a request that names a `repository` or a `group` is refused (`repository_not_accepted`, `group_not_accepted`). What a run or a trigger gives is the `project`, and the `ref` (a branch, a tag or a SHA; the commit a firing runs when the call names none) and the `path` of the script if not the default. A group and a project are made apart: `PUT /api/v1/organizations/acme/groups/ci` makes a folder, `PUT /api/v1/organizations/acme/projects/ci/cinim {"repository": "https://git.example/org/cinim.git"}` makes a project (the same call again changes its repository; a group that is there stays a group, `already_a_group`; nothing is made below a project).

```
POST /api/v1/organizations/acme/triggers
{"name": "main-push", "kind": "webhook", "project": "cinim", "ref": "main", "params": {"REGISTRY": "…"}, "concurrency": "abort_previous"}
POST /api/v1/runs   {"organization": "acme", "project": "ci/cinim", "commit": "v1.2", "path": ".ci/pipeline.lua", "params": {…}}      # by hand, no trigger
POST /api/v1/pipelines:check   {"organization": "acme", "project": "ci/cinim", "commit": "main"}        # reads and checks it; the answer names the commit
```

### Poll (D-76)

```
POST /api/v1/organizations/selfci/triggers
{"name": "main-poll", "kind": "poll", "project": "cinim", "ref": "main", "params": {"REGISTRY": "…"}, "concurrency": "abort_previous"}
```

The core looks at the `ref` (a branch or a tag; the head of the repository when empty) **once a minute** and starts a run when the commit it is at is not the one the trigger saw last. The first look has seen none: it starts a run on the commit the ref is at, so a new poll trigger runs at once. The look is `git ls-remote` by a **conductor of the organisation**, nothing is fetched and no script is read; only when the commit is new does the firing read the script at that commit (the same conductor, as for any run from a repository), so a new Lua in the commit is the one that runs. The run is started on the SHA, not on the name of the branch, and `concurrency` is as for the other triggers (`abort_previous` for a branch that is built at every commit).

* With no conductor connected (`conductor_min` 0 and nothing running), a busy one or a repository that does not answer, the look starts nothing, keeps the commit it saw, and says why in `last_result` (`not looked at: no_conductor`); the next look is a minute later. A commit is remembered whatever its firing came to: a script that cannot be read at it is said in `last_result` and is not tried again every minute.
* At most four triggers look in one pass of the loop (a look is a git of up to half a minute); the others are taken at the next pass (every 20 seconds). A trigger that is off does not look; switching it on starts from what the ref is at then.
* The view of the trigger has `seen_commit`, `last_checked_at` and `polls_every_seconds`. Only public https repositories: credentials for a private one are not built (PRJ-002..004).

### Webhook

```
POST /api/v1/organizations/acme/triggers
{"name": "on-push", "kind": "webhook", "project": "team/backend", "ref": "main"}
→ 201 {"id": "s1_…", "hook": "/api/v1/hooks/s1_…", "secret": "<shown once>", …}

POST /api/v1/hooks/s1_…
Authorization: Bearer <the secret>
{"commit": "3f2c1a9…"}                 # the commit, branch or tag to run (the trigger's `ref` when left out)
→ 201 {"id": "<run id>", "trigger_id": "s1_…", "state": "RUNNING"}
```

A webhook carries **no launch parameters** (`params` in its body is a 400): the parameters are the trigger's own, fixed when it was made. What a call may say is the commit, and, if it likes, the repository, which must be the trigger's (anything else is a 400: a call cannot point the trigger at another server). A manual `:fire` may still give `params`, and `commit`.

The secret is only for this hook and starts only this trigger's script; it is not an API token. Lost or leaked: `POST …/triggers/{id}:rotate-secret` gives a new one and the old one stops at once. Only the bearer form is supported; a forge that signs the body (GitHub's `X-Hub-Signature-256`) needs a recoverable secret and is not built, so put the hook behind a small relay or use a forge that can send an `Authorization` header.

### Manual, switching, deleting

```
POST /api/v1/organizations/acme/triggers/{id}:fire      {"params": {…}, "commit": "…"}   # a run now, also of a switched-off trigger
POST /api/v1/organizations/acme/triggers/{id}:disable   (or :enable)
GET  /api/v1/organizations/acme/triggers                                   # the list; last_fired_at, last_run_id, last_result
DELETE /api/v1/organizations/acme/triggers/{id}
```

### Concurrency

What a firing does when an earlier run of the same trigger has not ended (it is in any state that is not final: created, queued, running, waiting):

* `"concurrency": "parallel"` (default) starts a run for every firing at once, whatever the earlier ones are doing; when the organisation has no room for more (its `pod_limit`, RUN-004) the runs wait for room in turn, which is the queue. Jobs that must not run together - one test environment - are held back by a `lock` (see below), not by the trigger.
* `"abort_newest"` **aborts the new firing**: no run is started while an earlier run has not ended, and `last_result` says so (`aborted the new firing: the previous run has not ended`; a manual `:fire` answers 409 `still_running`). A slow nightly never overlaps itself.
* `"abort_previous"` **aborts the earlier runs that have not ended** (`POST /api/v1/runs/{id}:abort`, their Pods are removed) and starts the new one; `last_result` says which runs it cancelled (`started; cancelled the earlier run <id>`). The answer to a push storm: only the newest commit is built.

Only the runs of the same trigger count; a run that has ended is never touched.

### Jobs that must not run together: `lock`

The scenario: every commit has to be tested, a new commit does not cancel the test of the one before it (it brought other changes), but the test environment exists once and can be used by one job at a time. The trigger is `parallel` (a run for every firing); the **job** names a lock:

```lua
ci.single['02']{ image = "registry/tests:1", lock = "stand", body = function(j)
  j:run(step.sh['1']{ cmd = "deploy-to-stand" })
  j:run(step.sh['2']{ cmd = "run-the-tests" })          -- the deploy and the tests that follow it stay together
 end }
```

The jobs of an organisation with the same lock run **one at a time, in turn** (first come, first served), whatever runs they belong to. A run that waits is suspended - it takes no place of a conductor and no Pod - and `GET /api/v1/runs/{id}` says `waiting_for_lock: {name, held_by}`. **Which jobs have the lock:** `GET /api/v1/organizations/{slug}/locks` (every lock that is held or waited for) and `.../locks/{name}` (one) answer with the job that holds it (`run_id`, `job`, `since`) and the jobs that wait, in the order they will get it (`place`). The lock is let go when the job's function ends (also with an error), when the run ends, and when it is cancelled. Different names do not meet; a job in a job with the same name does not wait for itself. A queue is not limited by the lock; the organisation as a whole may have 65000 runs that have not ended (`CINIM_MAX_UNFINISHED_RUNS`), then a new run is `429 queue_full`.

### What a trigger stores

The **project** (the path of a leaf of the group tree that has a repository, docs/variables.md; the repository is the project's), the ref and the path of the script, and the parameters (the script itself is read at every firing, D-73). A trigger of an organisation that is switched off starts nothing; deleting the organisation deletes its triggers.

## Checked on the TESTING cluster

Parameters (a run with `JOBS=8` and `BRANCH` given: the step printed the given values and the default of `TARGET`; `JOBS=0` ended the run `FAILED` before any step; `PATH` as a parameter was `400`), a webhook (wrong secret, no secret and an administrator token all `404`, the right secret `201` with a parameter, `LD_PRELOAD` as a parameter `400`), a schedule (`* * * * *` started a run in the first minute; switched off afterwards), `:fire`. Not checked: `concurrency = abort_newest` against a long run, two cores at once, a core that was down over a firing.
