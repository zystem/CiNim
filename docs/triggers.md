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
    ci.job({ image = "alpine" }, function(j)
      j:sh('echo "building $BRANCH with $JOBS jobs for $TARGET"')   -- an ordinary environment variable
    end)
    if run.params.RELEASE then ... end                                -- typed in the script
  end,
})
```

Start it with values:

```
POST /api/v1/runs
{"organization": "acme", "project_id": "p1", "script": "...", "params": {"TICKET": "CI-7", "JOBS": 8, "RELEASE": true}}
```

What happens:

* The API checks only what it can without the script: a name is an environment variable name (`[A-Z_][A-Z0-9_]*`, not `PATH`, `LD_*`, `CICD_*` and the like), a value is a string, number or boolean of at most 1 KiB, 64 parameters and 4 KiB in all. Anything else is `400 invalid_params`.
* The executor then checks the values against the script's declarations, **before `main` runs**: a missing required parameter, a number out of range, a value that is not one of the choices, or a parameter the script does not declare ends the run as failed, with the parameter's name and the rule in the message (`GET /api/v1/runs/{id}` shows the state `FAILED`, no steps, and `failure: {code, message}`, here `script_error` and `parameter JOBS must be at least 1`). (Checking at the API, before the run exists, needs the metadata phase and preflight, PIP-016; not built yet.)
* The complete set, defaults included, is journaled once and kept with the run (`GET /api/v1/runs/{id}` shows it as `params`). A replay after an executor restart gets the same values from the journal.
* Every step of the run gets them as plain environment variables of the container. They are in the Pod's specification, so **a parameter is not a place for a secret**: a step asks for those by name (`secrets = {"NAME"}`, `docs/secrets-masking.md`). A secret of the same name wins.

Not built: `ci.list`, `ci.map`, `ci.secret` parameters, the variables of the four levels (organisation, group, project, pipeline; VAR-001), the log header with the effective values (VAR-005).

## Triggers

All calls are an administrator's: `Authorization: Bearer <admin token>`.

### Schedule

```
POST /api/v1/organizations/acme/triggers
{"name": "nightly", "kind": "schedule", "schedule": "0 2 * * *", "project_id": "p1",
 "script": "...", "params": {"TARGET": "staging"}, "concurrency": "skip"}
```

Five fields, **UTC**: minute hour day-of-month month day-of-week. `*`, lists `1,15`, ranges `9-17`, steps `*/15` and `10-50/10`, names (`jan`, `mon`), and `@hourly @daily @weekly @monthly @yearly`. If both day fields are restricted a day matches when either does (as in Vixie cron). Core looks every 20 seconds. A core that was down fires a schedule **once** when it is back. Switching a schedule off and on again starts its clock from that moment.

### Webhook

```
POST /api/v1/organizations/acme/triggers
{"name": "on-push", "kind": "webhook", "project_id": "p1", "script": "..."}
→ 201 {"id": "s1_…", "hook": "/api/v1/hooks/s1_…", "secret": "<shown once>", …}

POST /api/v1/hooks/s1_…
Authorization: Bearer <the secret>
{"params": {"BRANCH": "feature-x"}}
→ 201 {"id": "<run id>", "trigger_id": "s1_…", "state": "RUNNING"}
```

The secret is only for this hook and starts only this trigger's script; it is not an API token. Lost or leaked: `POST …/triggers/{id}:rotate-secret` gives a new one and the old one stops at once. Only the bearer form is supported; a forge that signs the body (GitHub's `X-Hub-Signature-256`) needs a recoverable secret and is not built, so put the hook behind a small relay or use a forge that can send an `Authorization` header.

### Manual, switching, deleting

```
POST /api/v1/organizations/acme/triggers/{id}:fire      {"params": {…}}   # a run now, also of a switched-off trigger
POST /api/v1/organizations/acme/triggers/{id}:disable   (or :enable)
GET  /api/v1/organizations/acme/triggers                                   # the list; last_fired_at, last_run_id, last_result
DELETE /api/v1/organizations/acme/triggers/{id}
```

### Concurrency

`"concurrency": "allow"` (default) starts a run for every firing; `"skip"` skips a firing while an earlier run of the same trigger is still running and says so in `last_result`. Cancelling the earlier run instead needs run cancellation, which is not built.

### What a trigger stores

The project, the **script** and the parameters (until pipelines are read from repositories). The script is up to 256 KiB. A trigger of an organisation that is switched off starts nothing; deleting the organisation deletes its triggers.

## Checked on the TESTING cluster

Parameters (a run with `JOBS=8` and `BRANCH` given: the step printed the given values and the default of `TARGET`; `JOBS=0` ended the run `FAILED` before any step; `PATH` as a parameter was `400`), a webhook (wrong secret, no secret and an administrator token all `404`, the right secret `201` with a parameter, `LD_PRELOAD` as a parameter `400`), a schedule (`* * * * *` started a run in the first minute; switched off afterwards), `:fire`. Not checked: `concurrency = skip` against a long run, two cores at once, a core that was down over a firing.
