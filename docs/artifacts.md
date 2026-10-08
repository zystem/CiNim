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

How it works: the step's shim has no key. It asks core (with its step credential, as for secrets) for URLs, one per file, good for 15 minutes to put and 5 to get; core signs them (SigV4, `UNSIGNED-PAYLOAD`) for the object `<organisation>/<run>/<path>` and only for what the step's own options declared. After the upload the shim says it is done, and core asks the store (HEAD) for the size before it marks the artifact `stored`; only then is it listed.

## Reading them

```
GET /api/v1/runs/{id}/artifacts          → {"artifacts": [{"path", "size", "sha256", "step", "created_at"}]}
GET /api/v1/runs/{id}/artifacts/{path}   → the file (up to 64 MiB; the core reads it from the store and passes it on)
```

An organisation's token sees its own runs only.

## Network

A step Pod reaches the store on port 3900 of the Pods labelled `app: garage` in the shard's namespace (a NetworkPolicy of the organisation, `allow-dns-and-collector`). A store elsewhere needs a policy of the operator's own. The shim speaks plain `http://` to the store (it is a static binary without TLS); an `https://` endpoint is signed fine by core, but a step cannot use it yet.

## Not built

Multipart upload (a file is one PUT), artifacts between runs and download by another run (`ci.run`, cache: DAT-004), retention and a sweeper of the objects (the rows of a deleted organisation go, its objects stay), a quota per organisation, expiry, ACL, provenance, the `JobArtifact.upload/download` calls of the API v1 signatures (the `artifacts` option stands in for them), downloading from the UI.
