# Variables

A **variable** is a name and a value that a step finds in its environment as an ordinary variable: `$URL` in a shell, `os.environ["URL"]` in Python (VAR-002). Two kinds exist (VAR-001):

* a **plain** variable, an ordinary text that is shown to whoever may read it - this page;
* a **secret**, whose value is kept sealed and never shown again, and which a step asks for by name (`secrets = {"NAME"}`, docs/secrets-masking.md).

## The structure and the levels

The structure is **shard, organisation, group, job** (PRJ-001, D-54). There is no project. A **group** belongs to an organisation and may contain groups, up to 8 levels; the organisation itself is the root. A run, and a trigger, belongs to a group, or to the organisation if it names none. Plain variables are set at three places, and each is inherited by everything below it:

| level | whose | who writes |
|:---|:---|:---|
| the shard | every step of every organisation | an administrator |
| an organisation | the organisation's runs | `rw`, `admin` |
| a group | the runs in it and in the groups below it | `rw`, `admin` |

```
GET    /api/v1/variables                                                    the shard's  → {"level": "shard", "variables": [{"name", "value"}]}
PUT    /api/v1/variables/{NAME}            {"value": "..."}                  (admin)
DELETE /api/v1/variables/{NAME}                                              (admin)

GET    /api/v1/organizations/{slug}/variables                               an organisation's  → {"organization", "variables": [...]}
PUT    /api/v1/organizations/{slug}/variables/{NAME}   {"value": "..."}      (rw, admin)
DELETE /api/v1/organizations/{slug}/variables/{NAME}                         (rw, admin)

GET    /api/v1/organizations/{slug}/groups                                  the groups (folders)  → {"groups": [{"path", "depth"}]}
PUT    /api/v1/organizations/{slug}/groups/{path}                           make the group, a folder (201; 200 if it is there; 409 already_a_project); the parent has to exist     (rw, admin)
GET    /api/v1/organizations/{slug}/projects                                the projects  → {"projects": [{"path", "depth", "repository"}]}
PUT    /api/v1/organizations/{slug}/projects/{path}   {"repository": "https://..."}   make the project, a leaf with its main repository (201; 200 if it is there, and the repository is changed; 409 already_a_group); the parent group has to exist; nothing is made below a project     (rw, admin)
GET    /api/v1/organizations/{slug}/groups/{path}                           → {"path", "kind": "group" | "project", "repository"}  (also under /projects/{path}: a node is one or the other, and what is under it is under either)
DELETE /api/v1/organizations/{slug}/groups/{path}                           only an empty group: no group below, no run, no trigger (409 group_not_empty); its variables go with it
GET|PUT /api/v1/organizations/{slug}/groups/{path}/settings                  the cache limits of a group: cache_quota_bytes, cache_retention_days (docs/cache.md)   (PUT: rw, admin)
GET    /api/v1/organizations/{slug}/groups/{path}/variables                 a group's  → {"organization", "group", "variables": [...]}
PUT    /api/v1/organizations/{slug}/groups/{path}/variables/{NAME}   {"value": "..."}      (rw, admin)
DELETE /api/v1/organizations/{slug}/groups/{path}/variables/{NAME}          (rw, admin)
```

* A group is named by its **path**, the names from the top joined by `/`, for example `team/backend`. A name is lowercase letters, digits and `-`, starting with a letter, at most 40 characters, and not `variables` or `settings`; a group is at most 8 levels down; an organisation has at most 1000 groups. A refusal is `400 invalid_group`.
* A run is started in a **project** by `"project": "ci/cinim"` in `POST /api/v1/runs` (with `organization`): the path of a leaf of the tree that has a repository (D-68); an unknown one is `404 project_not_found`, a group with no repository `409 project_has_no_repository`. A trigger names its project the same way. `GET /api/v1/runs/{id}` shows the run's `group`.
* A variable's name is capital letters, digits and `_`, not starting with a digit, at most 64 characters, and not one of the names a step's environment may not set (`PATH`, `LD_*`, `CICD_*`, ... STO-004). A value is at most 8 KiB, and has no control character but a newline and a tab. One place (the shard, an organisation, a group) has at most 100 variables and 64 KiB of values in all. A refusal is `400 invalid_variable` with the reason.
* A step gets the **current** values at the moment its Pod is made (VAR-002): a variable changed while a run is under way is seen by the steps that start after the change.

## Precedence (VAR-004)

From the lowest: the variables of the **shard**, of the **organisation**, and of the **groups from the top one down to the run's own** (the nearer wins); the **launch parameters** of the run (docs/triggers.md), which override a variable of the same name; the **`env` of the pipeline and of the job**; what the steps write to **`$CICD_ENV`** (STO-003); and the **`env` of the step**, the highest. `GET /api/v1/runs/{id}` shows what the steps see of the first two and where each value came from, so that an override is not hidden:

```json
"variables": [{"name": "LOG_LEVEL", "value": "info", "source": "shard"},
              {"name": "REGION", "value": "eu", "source": "organization"},
              {"name": "REGISTRY", "value": "r.example/team", "source": "group", "group": "team"},
              {"name": "TARGET", "value": "staging", "source": "launch"}]
```

The `env` levels are in the script, and are about a step, not about the run, so they are not in that list:

```lua
return ci.pipeline({
  env = { LOG_LEVEL = "info" },                        -- every step of every job
  main = function(run)
    ci.single["a"] {
      image = "alpine",
      env   = { REGION = "eu-west" },                  -- every step of this job
      body  = function(j)
        j:run(step.sh["1"] { cmd = "echo $LOG_LEVEL $REGION" })
        j:env({ LOG_LEVEL = "debug" })                 -- the steps of this job that follow (no Pod is started)
        j:run(step.sh["2"] { cmd = "echo $LOG_LEVEL", env = { LOG_LEVEL = "trace" } })     -- this step only, above $CICD_ENV
      end,
    }
  end })
```

* The pipeline's `env`, the job's and `j:env` are added in that order (the later wins) and reach the step as ordinary variables of its Pod, above the launch parameters and below `$CICD_ENV`: a step that writes `$CICD_ENV` deliberately overrides them. The `env` of a step is applied by the shim after the env file, so it overrides that too. A secret (`secrets = {...}`) of the same name wins over all of them.
* A value is a text, a number or a boolean (shown as text), at most 8 KiB, with no control character but a newline and a tab; a name is capital letters, digits and `_`, at most 64 characters. At most 100 variables and 64 KiB of values in one place. The script is refused before the run goes on when it breaks this, and the core refuses a step whose `env` names what a step may not set (`PATH`, `LD_*`, `CICD_*`, ... STO-004) with `script_error`.
* They are plain: they are in the specification of the Pod and in the log header of the first step. A secret goes by `secrets`.

## The header of the first step (VAR-005)

The log of the **first step of a run** begins with the values the run was given and a digest of them, so that the log answers the question which values a run used:

```
cicd-shim: variables (digest c1f0203c784f)
cicd-shim:   REGION=eu-west
cicd-shim:   TARGET=staging
cicd-shim:   REGISTRY_PASSWORD=***
```

The digest is the first 12 hex digits of the SHA-256 over the sorted `NAME=value` lines joined by a newline. A secret is listed by name with `***` and is not in the digest. The core names the variables for the first step only (`CICD_VARIABLES`, which the shim removes from the command's environment); the shim reads the values from its own environment, so the header tells what the command is really given, and the lines go through the ordinary log pipeline, masking included. Two steps claimed together may both print it; a step that is run again does not.

## Checked on the TESTING cluster (2026-10-12)

The shard that was there before the groups (its `runs` and `triggers` had `project_id`) migrated at the start of the new core and went on serving. Groups `team` and `team/backend` were made (a second `PUT` answered 200, a missing parent and a bad name were refused with `invalid_group`); the same name `LVL` was set at the shard, the organisation, `team` and `team/backend`, and a pipeline with `ci.job{env = {JOBENV = "j"}}` printed it from a run in `team/backend` (`LVL=backend`, with `TEAMONLY` inherited from `team` and `SHARDONLY` from the shard), in `team` (`LVL=team`) and in the organisation (`LVL=org`, no `TEAMONLY`); `GET /api/v1/runs/{id}` named the source and the group of each. An unknown group in `POST /api/v1/runs` was `group_not_found`, a group with a group below was `group_not_empty`. The levels of `env` (pipeline, job, `j:env`, step, `$CICD_ENV`) were checked in one run: a pipeline `env` above a launch parameter, a job `env` above the organisation's variable and the pipeline's, `j:env` for the steps after it, `$CICD_ENV` seen by the next step, the step's own `env` above `$CICD_ENV`; a script naming `PATH` was refused with `script_error`. Not checked: the roles of rw/dev/ro against these routes on the running core (only the rules, `trbac`), a group of 8 levels through the API (through the module, yes).

## The audit of changes (VAR-006)

Off by default. The setting `audit_variables` of the organisation's profile (`PUT /api/v1/profile?organization=<slug>`, docs/settings.md) turns it on in one of two modes, and then every change is a row of the audit (`GET /api/v1/audit`, the administrator's):

* **`full`**: a plain variable's change (`variable.set`, `variable.delete`) has the old value in `before` and the new one in `after`, in full.
* **`digest`**: the same, but a value of 256 characters or more is written as its digest (`hmac:` and 12 hex digits); the value itself is in the log header of a step that used it (VAR-005).
* A **secret** (`secret.set`, `secret.delete` for `PUT`/`DELETE .../secrets/{NAME}`) is never written, in either mode: the row has who, when, the new version (`version 3`) and a digest of the value in `after`. The digest is an HMAC-SHA256 under a key made of the core's secret key and the tenant, not a plain hash, so that a short or guessable secret cannot be found by trying values against the audit; the name is part of what is signed.
* The `target` of a row names the level and the variable: `organization acme/REGION`, `group acme/team/backend/REGION`, `shard/REGION`. The variables of the **shard** belong to no organisation: their changes are always written, in full (the operator makes them, and they are plain).
* Launch parameters are not changed by anybody afterwards, so they have no rows; a run's view shows what it was given.

Checked: `tvaraudit` (off writes nothing, full and digest, the secret never in a row, the digest keyed by tenant, name and key, the setting validated and saved). Not checked on a cluster.

## Not built

A UI.
