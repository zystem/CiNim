# The storage service (`cinim-storage`): blobgate, a project of its own

*Explanation and reference. Status: **built with blobgate v0.3.0** (D-116, 2026-11-13); the rollout on the TESTING cluster is described at the end of this page. Until then the service was a Nim program in this repository (D-60) with Garage and Caddy nodes behind it (D-58); it is deleted, and what it did is blobgate's. What was run, and what was not, is at the end of this page.*

## What it is

One service that the core, and nothing else of the platform, talks to for objects: the artifacts, the caches and the git mirrors of every organisation. It is **blobgate** (github.com/zystem/blobgate, a project of its own, the way hsmgate is): an HTTP API for objects over any servers that rclone can talk to (a local disk, S3 such as Garage, WebDAV, FTP, SFTP, and more), with a copy on every node of a store, every block checked against its SHA-256, and its records in rqlite (it keeps nothing on a disk of its own). Its documentation is in its repository (`README.md`, `docs/`, the API in `internal/api/openapi.yaml`); this page says what CiNim relies on, how the two are installed together, and what stays CiNim's.

```
shard (cinim-shard)                      cinim-storage (blobgate; a Deployment with no volume)
  core ── HTTP, token per request ─────►  API (port 18090) ── stores, inventory, repair queue, lease: tables `storage_*` in rqlite
step Pods' shims ── HTTP, a grant ─────►  port for shims (18091): PUT of a part, GET of a range, nothing else
                                           ├── store "garage-main" ──► Garage (S3), installed by the chart
                                           └── a mirror of any nodes ──► WebDAV, FTP, SFTP, S3, a local disk ...
```

## What the core relies on

The contract is blobgate's (its `openapi.yaml`; the process tests of this repository, `tests/integration/tstorageproc.nim` and `tshimdirect.nim`, run the program against the core's own client and ingest). In short:

| Operation | Request |
|---|---|
| put an object (up to 8 MiB) | `PUT /v1/stores/{store}/objects/{key}` with `X-Content-SHA256` (required) |
| start / complete / abort an upload | `POST …?uploads` -> `{"upload_id"}`; `POST …?upload={id}` with `{"parts": [[1, "etag"], ...]}`; `DELETE …?upload={id}` |
| upload a part | `PUT …?upload={id}&part={n}` with `X-Content-SHA256` -> `{"etag"}` |
| what the service recorded of the parts of an upload (D-61) | `GET …?upload={id}&parts` |
| read a range | `GET …/objects/{key}` with `Range: bytes=a-b` (206, a chunked reply) |
| size, delete | `GET …?stat` -> `{"size"}`; `DELETE …/objects/{key}` |
| the stores | `GET /v1/stores` -> names, kinds, the default (no secrets) |
| the operator's calls | `/v1/admin/stores...` with the admin token, which the core does not hold |

`{store}` is a name or `_default`. blobgate 0.3.0 calls a shard a *tenant* and names its settings `BLOBGATE_*` and its header `X-Blobgate-Tenant`; the names that the core uses (`CINIM_STORAGE_*`, `X-Cinim-Shard`, the tokens `v1` and the grants `g1`) are still accepted (its changelog), so the core did not change. Every request carries `Authorization: Bearer v1.<expires>.<HMAC>` and `X-Cinim-Shard` (`common/storagetoken.nim`: the shard, the method, the decoded path with the query as sent, the expiry, two minutes), under the secret of that shard, which the core and the service share (a Kubernetes Secret). The service serves the shards named in its settings, each with its own secret. **The shard is part of every key** in the service (an object `acme/s1_01a1/dist/app.txt` of shard `001` lies as `001/acme/s1_01a1/dist/app.txt`): the names of tenants repeat between shards. The core still decides who may read or write what; the service does not know organisations. Errors: 401, 404 `no_such_object` / `no_such_store`, 409 `not_configured`, 400 (`sha256_required`, `sha256_mismatch`, a bad key, range or part), 413, 502, 503 with `Retry-After` (the core treats 5xx and 429 as "try again"), and **507 `store_full`** (below).

## What changes in the core

* `core/objectstore.nim` holds only the address of the service and the shared secret, and a `RemoteBackend` (`core/storageclient.nim`: `ObjectBackend`, `common/storagebackend.nim`, over the API above, with a store name and its shard).
* **Which store an object lies in is a column** of `artifacts` and `caches` (`store`, empty = the default of the service). A read goes to the store the row names; a write goes to the store that the organisation's setting chooses *at that moment*, and the row records it. So switching an organisation to another store never loses or moves anything: old objects are read where they are, new ones go to the new store.
* **The choice per organisation**: `storage: {artifacts, caches, held_logs, audit}`, each a store name from `GET /v1/stores` (empty = the default). Changed by an administrator (`PUT /api/v1/organizations/{slug}/storage`), validated against the list the service gives, written to the audit log (`storage.select`). Backups are not an organisation's: they use the default store of the platform.
* The stores themselves (their settings and secrets) are the service's, made with its admin token (`PUT /v1/admin/stores/{name}`), not the core's API; `GET /api/v1/stores` of the core only shows the names.

## The chart `cinim-storage` and its stores

`deploy/charts/cinim-storage`, one release per shard, into the namespace of the shard (so that it finds the shard's rqlite at `http://rqlite`). It is a thin chart around **blobgate as a dependency** (`Chart.yaml`: the chart `oci://ghcr.io/zystem/charts/blobgate`, its archive kept in `charts/` because the deploy profile of the pipeline reaches nothing but the API server; after a change of the version run `helm dependency update deploy/charts/cinim-storage`). What it adds:

* **Names.** The Service, the Deployment and the Pods are called `cinim-storage` (`blobgate.nameOverride` and `fullnameOverride`): the core's address, the egress rule that the core makes for the namespaces of the organisations and the policies below rely on it. Every value of the blobgate chart is set under `blobgate:` (its image `ghcr.io/zystem/blobgate`, replicas, ports, resources, `config.*`, the backup of the database).
* **The Secret** `cinim-storage` (or yours, `blobgate.existingSecret`): `shards` (`001=<secret>`), `adminToken`, `sealKey`, and `shard-001` that the core's chart reads (`storage.tokenSecret`). Made from `secrets.*` when those are given; nothing is generated at render time, and the chart refuses secrets that are too short.
* **Garage** (`stores.garage.enabled`, on by default): a StatefulSet of one node on a volume of its own (`persistence.size`). Its sidecar makes the layout, the bucket and an access key once, keeps the key on the volume, and **registers the store with the service** (`PUT /v1/admin/stores/<name>`, with `space_url` for the room, repeated at every start of the Pod until the service takes it).
* **Stores that are already there**: `stores.external` (buckets with their key in a Secret of yours) and **`stores.mirrors`**: a mirror of any servers that rclone can talk to, whose whole admin body, with the nodes' passwords, is in a Secret (`bodySecret`). The Job `cinim-storage-register` (a Helm hook after install and upgrade) tells the service, waiting up to ten minutes for it.
* **Network policies** (`networkPolicy.enabled`): the service is reached by the core's Pods on 18090 and by what the chart installs; the namespaces of the shard's organisations reach port 18091 and no other; Garage is reached by the service only.

`default: true` on a store makes it the default at every install and upgrade; with none marked, the first one registered is the default (and an operator's `:default` stays). The shard's chart (`cinim-shard`) has `storage: {url, directUrl, tokenSecret}` and nothing else about stores. The nodes of a mirror have **static credentials** in their connection strings (the Caddy nodes of D-58 asked the service for a one-request token; that went with them).

## Direct transfer from the shim (D-61)

**Why.** The bytes of an artifact used to go shim -> core -> service -> store, and the core's ingest served the uploads of a whole shard one block at a time. Now the bytes go from the shim to the service.

**The principle (the owner, 2026-10-17).** The authenticated channel (gRPC with mutual TLS, D-104) stays the channel of control and of everything where forgery would be dangerous, and it is also the safe channel for the **digests** of data that travels unencrypted. Bulk bytes go over plain HTTP between the shim and the service and are trusted only when their digests match those that came over the channel.

**An upload.**
1. `put_begin` over the channel (`ArtifactRequest.direct = true`, a shim that can): the declared patterns, the quotas, the size. The core makes the row `uploading`, opens the upload in the service and answers with `grant`, `direct_url` and `direct_path`. The **grant** is `g1.<shard>.<expires>.<HMAC>` (`common/storagetoken.nim` `signGrant`) under the shard's secret, bound to the shard, the store, the key, the upload and the mode (`w`), good for two hours; a shim that did not say it can, a shard without `CINIM_STORAGE_DIRECT_URL`, or a row whose store has no name gets no grant and is refused with `direct_required`.
2. The shim sends each part (8 MiB) to the port for shims, `PUT <direct_path>?upload=<id>&part=<n>` with the grant and `X-Content-SHA256` (`shim/directclient.nim`, plain `std/httpclient`, no TLS). The service checks the grant, writes the part, makes the digest of what it received, compares it with the header, and records `(upload, part, digest, size)`.
3. `put_end` over the channel: the parts with their etags and the **digest of each part** that the shim made of its file (`ArtifactPart.sha256`). The core reads what the service recorded (`ObjectBackend.uploadedParts`), compares part by part, and only when they are equal completes the upload and marks the row `stored`; otherwise it aborts and answers `digest_mismatch`. Digests for some parts only, or not in lower-case hex, are `bad_request`.

**A download** is the same the other way: `get_list` and `cache_find` answer with `direct_url` and, for each file, a read grant (`mode r`) and `direct_path`; the shim reads ranges of 8 MiB (`GET <direct_path>` with `Range`) and checks the SHA-256 of the whole against the digest from the channel. Caches go the same way; the log and the held logs do not change.

**When the service cannot be used.** There is no other way (the owner, 2026-10-18). A service that does not answer is waited for as long as the shim's patience says, and then the upload fails with `store_unavailable` and the files stay on the run's volume for the drain; an answer 401/403/404/409 to a grant fails it at once. A file of no bytes is one request and nothing is put in the store (the core's row says all there is of it).

**The port for shims** (`blobgate.config.shimPort`, 18091, 0 turns it off) serves only `PUT` of a part and `GET` of a range, nothing else. **The network:** the core adds to the policy `allow-dns-and-collector` of every organisation namespace an egress rule to the service's Pods (`app.kubernetes.io/name: cinim-storage`) on that port (`ProvisionConfig.storageDirectPort`, from `CINIM_STORAGE_DIRECT_URL`); the chart has the matching ingress rule. The core only reports a policy that exists and differs, so for a namespace made before, delete `allow-dns-and-collector` and the core makes it again.

**What it does not give.** The confidentiality of the bytes on the wire: an operator who needs it encrypts the network (a CNI with WireGuard, a mesh). A stolen grant lets its holder write parts of that one upload for two hours, and the digest check at `put_end` rejects whatever the shim did not send.

## Room in the store

A full store does not say so: on 2026-11-11 the volume of Garage (4 GiB, 4.3 GB held) had 512 KiB left, uploads stalled with no error, and three self-builds hung before anyone looked at the volume. So the service **asks the store how much room it has before it takes a block** and refuses one that would not fit, with a message that says what is wrong (blobgate, its configuration page).

* **Where the room comes from.** A node says it itself where it can (rclone `about`); a store of kind `s3` has an optional `space_url` (an address that answers the Prometheus text of Garage: `http://cinim-storage-garage:3903/metrics`, the admin port, which answers `/metrics` with no token). The chart's Garage sidecar registers it. **A store that does not say, or does not answer, refuses nothing**; for a node that cannot say (FTP, most WebDAV) the write is tried and a refusal of the node for lack of room is the same 507.
* **What is refused.** A put of a block, or the start of an upload with a size, is answered **507** `store_full` when `free - need < reserve` (`CINIM_STORAGE_RESERVE_BYTES`, 256 MiB, settings.md). Nothing is written. The words: "the store garage-main is nearly full: 512.0 KiB free of 12.0 GiB, this upload needs 83.3 MiB and 256.0 MiB are kept free; delete caches or artifacts, shorten their retention (cache.retention, artifacts.retention), or give the store a bigger volume".
* **What the person sees.** The core passes it on as the refusal `store_full` with those words (`storageclient.nim`: 507 is final, not retried; `artifactingest.nim: fromOutcome`), so a cache step says `not saved (store_full: the store garage-main is nearly full: ...)` and an artifact step fails with them; the shim's direct client does not wait on a 507 either.
* **What it does not do.** It does not count what an organisation holds (the quota of the cache, `cache.quota`, is that) and it does not free anything. Keep the quota below the volume: the Garage volume of the TESTING cluster is 12 GiB and `cache.quota` 5 GiB.

## What was run, and what was not

*Run on 2026-11-13, on the workstation, with blobgate v0.1.0 built from its tag (and the five files `tstorageproc`, `tshimdirect`, `tcache`, `tdirectartifact` and `trepository` again with v0.3.0, all ok, in the test image):* the process tests `tstorageproc` (the core's `RemoteBackend`, the choice of store per organisation, a write that a node missed and its repair, a restart of the service) and `tshimdirect` (a shim's client against the core's real ingest and the service: a file of three parts, a small file, a cache entry, a part changed on its way, a false digest, a service that cannot be reached, a shard without the port for shims) against a mirror of two directories, and the whole suite in the test image (`tools/test/run.sh`). The chart: `helm lint --strict` and `helm template` of `deploy/charts/cinim-storage`.

*Rolled out on the TESTING cluster on 2026-11-13* (by hand, before the pipeline ran this commit): the old release `cinim-storage` (the Nim module, Garage, two Caddy nodes) and the volumes of Garage and of the Caddy nodes were deleted (no migration, D-60), the `storage_*` tables and the cache rows of the shard database were dropped, and the new chart was installed on a clean volume (`helm install`, blobgate 0.1.0, and the same day moved to 0.3.0 by `helm upgrade --reuse-values`: the Secret key is `tenants` now, the core was not restarted, `GET /api/v1/stores` of the core shows the store and `:check` answers ok; Garage with the bucket `cinim-artifacts`, the Secret made again with the same values, so the core did not need to restart). The Garage sidecar registered the store, `GET /v1/admin/stores` shows it with its `space_url`, `:check` answers ok, `/readyz` answers ready. **Not done:** an artifact and a cache entry through the core and a shim on this service were not yet run.

*Not run here:* a mirror of WebDAV and FTP through this chart (blobgate's own tests run one against real servers, SFTPGo, on 2026-11-12); a 72 hour soak with the new service.

*History.* The decisions D-57 (a store node of our own over ZeroMQ), D-58 (Caddy nodes with the WebDAV module of a fork, the mirror and the repair in the module) and D-60 (the module as a Nim service of its own) led here; they are in the decision log, and the code, the measurements and the notes of those phases are in the git history before the commit that replaced them.
