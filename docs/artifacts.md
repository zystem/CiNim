# Artifacts

A step can leave files for later steps and for people: its **artifacts**. They live in the shard's S3-compatible object store (Garage, D-46), not in the database and not on the Pod. Requirement: DAT-003.

## Setting the store up (an administrator, once per shard)

1. Run the store: `deploy/examples/garage/garage.yaml` (docs/deployment.md). It makes the bucket `cinim-artifacts` and the key `cinim`.
2. Tell the core where it is and give it the key. The secret is sealed in the database like a step secret (D-45) and is never answered again:

```
PUT /api/v1/storage
{"endpoint": "http://garage:3900", "region": "garage", "bucket": "cinim-artifacts",
 "access_key_id": "GK…", "secret_access_key": "…"}
```

The core tries the settings before it keeps them: it puts, reads and deletes one small object, and answers `400 storage_unreachable` with the store's own words if that fails. `GET /api/v1/storage` shows the settings without the secret, `POST /api/v1/storage:check` repeats the round trip, `DELETE /api/v1/storage` forgets them. The core needs its secrets set up first (`secrets_unavailable`, docs/hardware-key.md).

## In a pipeline

```lua
ci.job({ image = "alpine" }, function(j)
  j:sh("mkdir -p dist && echo built > dist/app.txt", { artifacts = { upload = { "dist/**" } } })
  j:sh("cat dist/app.txt", { artifacts = { download = { "dist" } } })
end)
```

* `upload` is a list of patterns, relative to the shared workspace `/cicd/workspace` (the same directory in every step of a run). `*` is any characters within a name, `**` crosses directories (`dist/**`, `**/*.log`), `?` is one character. **Every pattern must match at least one file**; a pattern that matches nothing fails the step with `artifacts_failed` and says which one. Symbolic links and the shim's own `.run` directory are never taken. At most 1000 files per step and 5 GiB per file.
* Files are put **after the command has succeeded**, before the step's log is closed (the log says `artifact dist/app.txt put (6 bytes)`). A command that failed or was stopped leaves nothing.
* `download` is a list of names: a file or a directory (all artifacts of this run under it). They are fetched into the workspace **before** the command, from the same run only; if one is missing the command does not start (`artifacts_unavailable`, exit 75). The SHA-256 recorded at upload is checked.
* A job's declaration and a step's are added together, as for secrets.
* A path is one artifact of a run: a retry of the step puts it again.

How it works: the step's shim has no key and no address of the store. It sends the files to the core over the authenticated channel `ArtifactIngest` (port 19744, ZeroMQ with CURVE), the way it sends its log, in blocks, each answered, with the step's own credential (as for its secrets). A file of at most 8 MiB is one request; a bigger one is a multipart upload of the store: the core starts it, takes the blocks of 8 MiB one by one and passes each to the store, and completes it. Nothing is kept in the core between the requests but the row of the artifact (state `uploading`, the store's upload id), so a core that restarts in the middle loses nothing and the shim sends the block again. An artifact is `stored` and listed only when the store itself says the object is there with the announced size. Downloading is the reverse: `get_list`, then blocks of 4 MiB (ranged reads), each file checked against the SHA-256 recorded at upload. The core allows only what the step's own options declared, in the step's own run, while its attempt is running.

Limits: 2 GiB per artifact, 10 GiB per run, 1000 files per step, 8 MiB per message.

## When the core cannot be reached (the spool fallback)

Before the first block the shim writes a **manifest** of the files it has to deliver (`/cicd/spool/artifacts.manifest`). If the core does not answer for the whole patience (60 s), the shim ends with the reason `artifacts_undelivered` (exit code 76): the command's own result stands (as `logs_undelivered` does for a log), and the Pod, with its workspace, is kept by the controller like a Pod whose log was not delivered. The shim has two tools for the controller, run through `exec` like the spool tools of the log: `cicd-shim --read-artifact PATH --workspace DIR --offset N --length L` (a block as base64) and `cicd-shim --ack-artifacts SPOOLDIR` (removes the manifest). The requests to ArtifactIngest are the same whoever sends them, and the controller already holds the step's credential (`StartStep.step_token`). The controller does nothing on its own: **when the core is available again and orders it**, it reads the manifest and the blocks out of the Pod and delivers them as the shim would have, then acknowledges. **Built so far: the shim's side (the manifest, the two tools, the exit code and its place in the Pod verdict); the controller's drain and the core's order are not built.** Until then a kept Pod is read by hand.

## Reading them

```
GET /api/v1/runs/{id}/artifacts          → {"artifacts": [{"path", "size", "sha256", "step", "created_at"}]}
GET /api/v1/runs/{id}/artifacts/{path}   → the file (up to 64 MiB; the core reads it from the store and passes it on)
```

An organisation's token sees its own runs only.

## Network

A step Pod reaches the core's ports 19742 (report), 19743 (log) and 19744 (artifacts) and DNS, and nothing else: the object store is not reachable from a step Pod and needs no NetworkPolicy of its own. The store has to be reachable from the core, with a plain `http://` or an `https://` endpoint (the core talks to it with its own HTTP client).

## Moving the storage module out of the core

What the core asks of a store is `ObjectBackend` (`src/core/storagebackend.nim`): eight operations (put an object, create / upload a part of / complete / abort a multipart upload, read a range, size, delete), none of which keeps state between calls. Built: `S3Backend` (`src/core/s3backend.nim`), in the core's process. To run the storage module as a separate service, write a `RemoteBackend` that sends the same eight operations as requests over ZeroMQ with CURVE, and a service that answers them with an `S3Backend`. The core stays in charge: the settings and the key are the core's (sealed in its database, `PUT /api/v1/storage`) and are sent to the service with a request or when it connects, the service keeps nothing, and `ArtifactIngest` may be served by that service too, with the shims pointed to it by `--artifact-addr` (the step credential would then be checked against a key the core derives for it, not the core's own). Nothing in a step, a shim or a script changes.

## Not built

The storage module as a separate service (the seam is there, above), the controller's drain of a kept Pod, parallel uploads (the ingest is one thread: a big upload delays another step's request by a block), artifacts between runs and download by another run (`ci.run`, cache: DAT-004), retention and a sweeper of the objects (the rows of a deleted organisation go, its objects stay), a quota per organisation, expiry, ACL, provenance, the `JobArtifact.upload/download` calls of the API v1 signatures (the `artifacts` option stands in for them), downloading from the UI.
