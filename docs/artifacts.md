# Artifacts

A step can leave files for later steps and for people: its **artifacts**. They live in the shard's S3-compatible object store (Garage, D-46), not in the database and not on the Pod. Requirement: DAT-003.

## Setting the store up (an administrator, once per shard)

1. Run the store: `deploy/examples/garage/garage.yaml` (docs/deployment.md). It makes the bucket `cinim-artifacts` and the key `cinim`.
2. Tell the core where it is and give it the key. The secret is sealed in the database like a step secret (D-45) and is never answered again:

```
PUT /api/v1/stores/garage-main
{"default": true, "endpoint": "http://garage:3900", "region": "garage", "bucket": "cinim-artifacts",
 "access_key_id": "GK…", "secret_access_key": "…"}
```

The core tries the settings before it keeps them: it puts, reads and deletes one small object, and answers `400 storage_unreachable` with the store's own words if that fails. A shard holds several **named stores** (D-59: a Garage bucket and/or Caddy nodes); the first one is the default. `GET /api/v1/stores` lists them without the secrets, `POST /api/v1/stores/{name}:check` repeats the round trip, `POST /api/v1/stores/{name}:default` changes the default, `DELETE /api/v1/stores/{name}` forgets one that nothing uses (a store that holds artifacts, caches or an organisation's choice is refused, `409 store_in_use`). Which store an organisation uses for what: `PUT /api/v1/organizations/{slug}/storage` `{"artifacts": "garage-main", "caches": "caddy-main"}` (an empty name is the default; `GET` shows the choice and the stores). A row remembers the store it was written to, so a change affects new objects only. The core needs its secrets set up first (`secrets_unavailable`, docs/hardware-key.md).

## In a pipeline

```lua
ci.job({ image = "alpine" }, function(j)
  j:sh("mkdir -p dist && echo built > dist/app.txt", { artifacts = { upload = { "dist/**" } } })
  j:sh("cat dist/app.txt", { artifacts = { download = { "dist" } } })
end)
```

* `upload` is a list of patterns, relative to the shared workspace `/cicd/workspace` (the same directory in every step of a run: the steps share a volume, docs/deployment.md). A command starts in the workspace (the shim changes to it before the command runs), so relative paths mean files there. `*` is any characters within a name, `**` crosses directories (`dist/**`, `**/*.log`), `?` is one character. **Every pattern must match at least one file**; a pattern that matches nothing fails the step with `artifacts_failed` and says which one. Symbolic links and the shim's own `.run` directory are never taken. At most 1000 files per step and 5 GiB per file.
* Files are put **after the command has succeeded**, before the step's log is closed (the log says `artifact dist/app.txt put (6 bytes)`). A command that failed or was stopped leaves nothing.
* `download` is a list of names: a file or a directory (all artifacts of this run under it). They are fetched into the workspace **before** the command, from the same run only; if one is missing the command does not start (`artifacts_unavailable`, exit 75). The SHA-256 recorded at upload is checked.
* A job's declaration and a step's are added together, as for secrets.
* A path is one artifact of a run: a retry of the step puts it again.

How it works: the step's shim has no key and no address of the store. It sends the files to the core over the authenticated channel `ArtifactIngest` (port 19744, ZeroMQ with CURVE), the way it sends its log, in blocks, each answered, with the step's own credential (as for its secrets). A file of at most 8 MiB is one request; a bigger one is a multipart upload of the store: the core starts it, takes the blocks of 8 MiB one by one and passes each to the store, and completes it. Nothing is kept in the core between the requests but the row of the artifact (state `uploading`, the store's upload id), so a core that restarts in the middle loses nothing and the shim sends the block again. An artifact is `stored` and listed only when the store itself says the object is there with the announced size. Downloading is the reverse: `get_list`, then blocks of 4 MiB (ranged reads), each file checked against the SHA-256 recorded at upload. The core allows only what the step's own options declared, in the step's own run, while its attempt is running.

Limits: 2 GiB per artifact, 10 GiB per run, 1000 files per step, 8 MiB per message.

## When the core cannot be reached (the drain)

What happens to the artifacts (and to the log, D-27) when something on the receiving side is not there:

* **The core is up, the store (or the log store) is not.** The shim does not finish: it keeps asking for the whole `log_hold_timeout` (10 minutes by default, the same for the log and for the artifacts) and the Pod stays Running. When the store is back, the shim delivers and ends as usual.
* **The core is down.** Same wait: the shim holds the Pod for those ten minutes, and the core, when it is back inside them, takes everything from the shim itself. If the wait runs out, the core, which was away and knows nothing of it, restores the whole story from the **Pod's own log**: the shim writes its state there as `CICD-SHIM {...}` lines, and in them, in this order, the command's result (`"result": "success"` or `"failed"`, with `cmd.exit`), then what became of the artifacts (`artifacts_delivered`, `artifacts_undelivered` or `artifacts_failed`, field `arts`), then of the log (`logs_delivered` or `logs_undelivered`, field `logs`), then `done` with the reason; the termination message says the same (`result`, `logs`, `artifacts`). The controller sends the last such line when the Pod ends, and the core records it as if the shim had spoken to it. So a Pod has two outcomes the core must tell apart: the command **succeeded** (then it only remains to catch up: the artifacts, if it declared any, and the log, each according to its own status), or it **failed** (then the log is to be fetched and the artifacts almost certainly do not exist: the shim puts artifacts only after a success). Both undelivered is a possible state and is written as both; the reason of the step is then `logs_undelivered`, and the drain is ordered for both.
* **The wait ran out.** The shim ends with `artifacts_undelivered` (exit code 76) or `logs_undelivered` (72); the command's own result stands. What was not delivered is on **the run's volume**, not in the Pod: the **manifest** of the files (`/cicd/state/drain/<step>-<attempt>/artifacts.manifest`, written before the first block) and the **log spool** (`.../spool`). A Pod that has ended cannot be entered by `exec`, so the volume is what outlives it (the run volume is not optional, D-55).

When the core is available again it **orders the drain** in its answer to the controller of the step's organisation (`DrainStep`: the step, its image, its credential, and what is to be drained: the artifacts, the log or both), and names the order again in every answer until the controller says it is done. The controller makes a **drain Pod** (`cdrain-<run>-<step>-<attempt>`, the step's image, the run's volume mounted as in a step Pod, the keys of the shim, the same security class and policy as a step) that runs `cicd-shim --drain`: the shim reads the manifest and the log spool the step's shim left, and sends them to the core as that shim would have, with the step's credential. A file that is not the one recorded (the workspace is the run's, a later step may have written over it) is refused before anything is sent. Each file is put by the same requests as the shim's own upload (`put_object`, or `put_begin`, `put_part`, `put_end`) and taken off the manifest when the core has it; the log blocks go to LogIngest and off the spool when the core acknowledges them (it takes each sequence number once). The Pod ends with exit code 0 (all delivered), 77 (the core or the store did not answer in `--wait` seconds, 120: to be tried again) or 78 (it cannot be done: the file is not the one recorded, the path is outside the workspace, the store refuses for good, a quota), and says why in its termination message. The controller reads that, removes the Pod, and tells the core: done, given up, or (for 77) to be tried again, which makes the core wait two minutes before it orders again; the controller itself looks at the Pod every few seconds and does not carry the data. The core gives up after a day. ArtifactIngest accepts the files of a step that has ended only while its drain is pending (`step_drains`), and the run's volume is **not released** meanwhile (`core/runstorage.nim`). A drain Pod older than two hours is removed whatever happens.

Why a Pod and not `exec`: the first design read the files through `exec` into a Pod on the volume with the shim's tools. On the TESTING cluster (Kubernetes 1.36) the controller's C client got nothing back from `exec` (not even from `echo`: `kube_exec` and `wsclient_run` both returned 0 with no data, while `kubectl exec` under the controller's account worked), and where `exec` works it costs about 17 s a call. A Pod that delivers by itself carries no data through the controller and needs neither. The same went for the rescue of a log spool out of a running Pod that is cancelled: it is gone (D-55). A Pod that is removed while it runs gets a grace period of 50 s, in which the shim stops the build (SIGTERM to its process group, SIGKILL after 20 s), delivers the log (up to 15 s) and leaves; and what it could not deliver is on the volume.

The run volume is not optional (D-55): the spool and the manifest are always on it. **Not checked:** a drain Pod under a Pod Security policy stricter than the step's.

## Reading them

```
GET /api/v1/runs/{id}/artifacts          → {"artifacts": [{"path", "size", "sha256", "step", "created_at"}]}
GET /api/v1/runs/{id}/artifacts/{path}   → the file (up to 64 MiB; the core reads it from the store and passes it on)
```

An organisation's token sees its own runs only.

## How long they live (DAT-006)

The store does not fill up by itself: the core looks at it every ten minutes (`core/artifactsweep.nim`) and deletes, from the store and from the database,

* an artifact **older than the retention** (`artifacts.retention` of the chart, `CINIM_ARTIFACT_RETENTION`, 30 days; `0` keeps for ever) whose run has ended - an artifact of a run that is still under way is never taken, whatever its age;
* an upload that was **started and never finished** for longer than `artifacts.abandonAfter` (`CINIM_UPLOAD_ABANDON_AFTER`, a day): the multipart upload is aborted, so that the store frees the parts;
* the artifacts of a run that is **not in the database** any more (an organisation that was purged).

An object the store says it does not have is as good as deleted; a store that does not answer leaves the rows for the next pass. Each pass looks at 200 rows of each kind. **Per organisation (the settings of its profile, `PUT /api/v1/profile?organization=<slug>`, docs/settings.md):** `artifact_retention_days` is the organisation's own retention (0: the shard's, above), and `artifact_quota_bytes` is the most bytes of artifacts it holds - stored and under way, whatever the runs - checked when an upload begins: one that would pass it is refused with `quota_exceeded` and the step's log says why; the file that a new one replaces is not counted twice. A legal hold on runs, groups and the organisation is below.

## Network

A step Pod reaches the core's ports 19742 (report), 19743 (log) and 19744 (artifacts) and DNS, and nothing else: the object store is not reachable from a step Pod and needs no NetworkPolicy of its own. The store has to be reachable from the core, with a plain `http://` or an `https://` endpoint (the core talks to it with its own HTTP client).

## Moving the storage module out of the core

*Built as a store of our own (2026-10-16): docs/store.md, D-57. The `RemoteBackend` below is `MirrorBackend` over `cinim-store` nodes, spoken to over ZeroMQ with CURVE; the S3 backend stays as the other choice (`PUT /api/v1/stores/{name}`). What follows is the original statement of the seam.*

This is the rule of D-49 applied to the store: the core is the source of the settings of every permanent module, so the storage service is started with only the core's address and its transport keys; the store's endpoint, bucket and key are the core's (sealed in its database) and go to the service with the request or when it connects, never into the service's environment.

What the core asks of a store is `ObjectBackend` (`src/core/storagebackend.nim`): eight operations (put an object, create / upload a part of / complete / abort a multipart upload, read a range, size, delete), none of which keeps state between calls. Built: `S3Backend` (`src/core/s3backend.nim`), in the core's process. To run the storage module as a separate service, write a `RemoteBackend` that sends the same eight operations as requests over ZeroMQ with CURVE, and a service that answers them with an `S3Backend`. The core stays in charge: the settings and the key are the core's (sealed in its database, `PUT /api/v1/stores/{name}`) and are sent to the service with a request or when it connects, the service keeps nothing, and `ArtifactIngest` may be served by that service too, with the shims pointed to it by `--artifact-addr` (the step credential would then be checked against a key the core derives for it, not the core's own). Nothing in a step, a shim or a script changes.

## Checked on the TESTING cluster

A job of two steps: the first made `dist/app.txt` (6 bytes) and `dist/sub/big.bin` (20 000 000 random bytes, three blocks of a multipart upload, Garage as the store) with `upload = {"dist/**"}`, the second declared `download = {"dist"}` and printed the same SHA-256 of the big file as the first. `GET /api/v1/runs/{id}/artifacts` listed both, `GET …/artifacts/dist/sub/big.bin` returned the same bytes (same SHA-256), and the first step's log said `artifact … put`. A step with an upload pattern that matches nothing ended `FAILED` with exit code 74, `artifacts_failed`, and the log named the pattern. The settings were refused when the endpoint did not resolve and accepted, with a round trip, when it did. **The drain (2026-10-12, TESTING cluster, run volumes on, `log_hold_timeout` of the organisation set to 20 s for the test):** (1) the store (Garage) scaled to 0, a step put `dist/app.txt` and a 3 MB `dist/big.bin`: the shim asked for 20 s and ended `artifacts_undelivered` (exit 76; the run SUCCEEDED, the step's reason said so); the core ordered the drain, the controller made the drain Pod; the first design, through `exec`, got nothing back from the controller's C client (see above) and was replaced; with the Pod, once the store was back, both files were in the store and `GET .../artifacts/dist/app.txt` and `.../big.bin` returned the bytes with the recorded SHA-256 (and `big.bin`'s equals the one the step printed). (2) The store **and** the log store (vlagent) scaled to 0 while a step wrote lines for 40 s: the step ended `logs_undelivered` (exit code 0 stands), and after both came back the drain Pod delivered the files and the ten log lines that had been spooled on the volume (the step's log then showed them, after the lines delivered before the outage). (3) The store away for 35 s with a hold of 120 s: the shim waited and delivered by itself, the run ended `ok`, no drain was made. (4) **The core itself down** (scaled to 0 from the middle of the step for 110 s, hold 20 s), a step that succeeded: it ended `logs_undelivered`; the core, which had not heard the shim, restored `result: success`, the log and the artifacts from the Pod's log, ordered the drain for both, and after it the artifact and the three log lines (those spooled while the core was away included) were there. The same with a command that exits 3: the step ended FAILED with exit 3 and `logs_undelivered`, the drain fetched the log only, no artifact was made or ordered. Two bugs came out of this and were fixed: the shim's upload loop deleted from the list it iterated (the whole step died with an assertion once a file was delivered), and the log spool of a running Pod that is cancelled was read from the old directory. Not checked: the drain of a file of more than one part (the requests are the shim's own, which are checked), a restart of the controller in the middle of a drain, the drain Pod under a stricter Pod Security policy, a step on a cluster without run volumes. Not checked either, and not this feature's: a core that restarts in the middle of a multipart upload, two big uploads at once.

## Legal hold (DAT-006)

A run can be put under a **legal hold**: what it left is not garbage-collected until the hold is released.

```
POST /api/v1/runs/{id}:hold      {"reason": "..."}     201 (200 if it is held already: the first reason stands)      (rw, admin)
POST /api/v1/runs/{id}:release                          200 {"released": true|false}                                 (rw, admin)
GET  /api/v1/organizations/{slug}/holds                 the runs under a hold, who placed each and why                (every role that reads)
```

* A hold needs a reason (at most 1000 characters). `GET /api/v1/runs/{id}` shows `hold: {reason, placed_by, placed_at}`. Placing and releasing are in the audit (`run.hold`, `run.release`). A run that is still going may be held; the hold takes effect when it ends.
* While it stands: the sweep of the artifacts does not take the run's artifacts, whatever their age; the core does not tell the controller to delete the run's volume (STO-006); and the organisation is **not deleted for good** (`DELETE /api/v1/organizations/{slug}?purge=true` answers `409 legal_hold`, and the reconciliation does not purge a switched-off organisation at the end of its retention; it says so in its report) until every hold is released.
* **Not covered:** the journal (nothing deletes it), and the caches (they are not a run's; a cache is a convenience that can be made again).
* **The log is not covered yet.** The log store drops whole days by its own period, so a hold does not keep the log of a held run. A copy of the log of held runs into the object store is written and tested (`core/heldlogs.nim`) but not switched on, and not offered by the API: the owner put it off until after the UI. Known gaps to close first: a pass copies too few steps for a big organisation, a log store that does not answer yields an empty copy marked incomplete, and only the newest attempt of a step is copied.

### A hold on a group or on the organisation

```
GET|PUT|DELETE /api/v1/organizations/{slug}/hold                         the organisation        (rw, admin to change; every role that reads)
GET|PUT|DELETE /api/v1/organizations/{slug}/groups/{path}/hold           a group and the groups below it
```

`PUT` takes `{"reason": "..."}` (201; 200 if held already, the first reason stands), `DELETE` releases. It covers **every run in the group and in the groups below it** (or every run of the organisation), **those that exist and those made while it stands**: it is a standing condition the sweeps look at, not a mark on each run. A run's view shows `hold` for its own and `held_by` (`level`, `group`, `reason`, `placed_by`) for the one that covers it. `GET /api/v1/organizations/{slug}/holds` lists the runs held and `scopes`, the holds of groups and of the organisation. A held group cannot be deleted; an organisation with any hold (of a run, a group or itself) is not deleted for good. In the audit: `group.hold`, `group.release`, `organization.hold`, `organization.release`. The word `hold` cannot be the name of a group.
* Checked live on the TESTING cluster (2026-10-13): no reason is `400`; a hold is `201`, a second one `200` and the first reason stands; the run's view and `GET /api/v1/organizations/acme/holds` show it, the audit has `run.hold`; release is `200` (`released: true`, then `false`); an unknown run is `404`. Not checked live: the sweep and the purge against a held run (tests only), the roles on a running core.
* Checked: `tests/integration/tholds.nim` (placed once, the first reason stands, released, listed; the sweep and the volume release skip a held run and take it once released; the view; a hold on a group covers the group and below it and not its neighbours or the groups above; a hold on the organisation covers all, runs made later too; the purge count; a held group is not deleted), `theldlogs` (the copy of the log, not switched on: once and in order, 12 MB through a multipart upload, lines that are missing, a group's hold, removal on release), `torgreconcile` (a held organisation is not purged and says why), `trbac` (who may).

## Not built

The storage module as a separate service (the seam is there, above), parallel uploads (the ingest is one thread: a big upload delays another step's request by a block), download of an artifact by another run (`ci.run`; the files that outlive a run for the next run are the cache, docs/cache.md), ACL, provenance, the `JobArtifact.upload/download` calls of the API v1 signatures (the `artifacts` option stands in for them), downloading from the UI.
