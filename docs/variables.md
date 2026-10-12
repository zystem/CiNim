# Variables

A **variable** is a name and a value that a step finds in its environment as an ordinary variable: `$URL` in a shell, `os.environ["URL"]` in Python (VAR-002). Two kinds exist (VAR-001):

* a **plain** variable, an ordinary text that is shown to whoever may read it - this page;
* a **secret**, whose value is kept sealed and never shown again, and which a step asks for by name (`secrets = {"NAME"}`, docs/secrets-masking.md).

## Variables of an organisation

An organisation keeps plain variables that every step of every run of it gets. Groups and projects, which the specification puts between the organisation and the run, do not exist yet, so the organisation is the one level above the launch parameters.

```
GET    /api/v1/organizations/{slug}/variables          → {"variables": [{"name", "value"}]}   (every role that reads)
PUT    /api/v1/organizations/{slug}/variables/{NAME}   {"value": "..."}                        (rw, admin)
DELETE /api/v1/organizations/{slug}/variables/{NAME}                                           (rw, admin)
```

* A name is capital letters, digits and `_`, not starting with a digit, at most 64 characters, and not one of the names a step's environment may not set (`PATH`, `LD_*`, `CICD_*`, ... STO-004). A value is at most 8 KiB, and has no control character but a newline and a tab. An organisation has at most 100 variables and 64 KiB of values in all. A refusal is `400 invalid_variable` with the reason.
* A step gets the **current** values at the moment its Pod is made (VAR-002): a variable changed while a run is under way is seen by the steps that start after the change.

## Precedence (VAR-004)

From the lowest: the variables of the organisation, then the **launch parameters** of the run (docs/triggers.md), which override a variable of the same name. `GET /api/v1/runs/{id}` shows what the steps see and where each value came from, so that an override is not hidden:

```json
"variables": [{"name": "REGION", "value": "eu", "source": "organization"},
              {"name": "TARGET", "value": "staging", "source": "launch"}]
```

## The header of the first step (VAR-005)

The log of the **first step of a run** begins with the values the run was given and a digest of them, so that the log answers the question which values a run used:

```
cicd-shim: variables (digest c1f0203c784f)
cicd-shim:   REGION=eu-west
cicd-shim:   TARGET=staging
cicd-shim:   REGISTRY_PASSWORD=***
```

The digest is the first 12 hex digits of the SHA-256 over the sorted `NAME=value` lines joined by a newline. A secret is listed by name with `***` and is not in the digest. The core names the variables for the first step only (`CICD_VARIABLES`, which the shim removes from the command's environment); the shim reads the values from its own environment, so the header tells what the command is really given, and the lines go through the ordinary log pipeline, masking included. Two steps claimed together may both print it; a step that is run again does not.

## Not built

The levels group and project (there are none), the `env` of the pipeline and of the job in the precedence (VAR-004), the audit of changes of variables (VAR-006, off by default), a UI.
