# The storage module (`cinim-storage`): a service of its own, with Garage and Caddy behind it

*Status: **phases 0 to 3 are built** (2026-10-17: the choice of store per organisation, D-59; the module as a service of its own, `src/storage`, D-60); the chart (phase 3, `deploy/charts/cinim-storage`) is built too; the check on the TESTING cluster (phase 4) is not. It replaces the store settings that live in the core today (`vault_meta` `objectstore`, `core/objectstore.nim`) and moves the code of `core/s3backend.nim`, `core/httpstore.nim`, `core/storerepair.nim` and `core/storeauth.nim` out of the core. Decisions of the owner (2026-10-17): a service and a chart of their own; the mirror, the repair and the check live in the module, which keeps its state in **rqlite** (the shard's by default) and has **no local state at all**, so it is a plain Deployment that can be restarted at once; the administrator of an organisation chooses its store; the ZeroMQ node `cinim-store` (D-57) goes; tenants are **not** unique across shards, so the shard is part of every key; the protocol is for us to choose.*

## What it is

One service, `cinim-storage`, that the core (and nothing else) talks to. Behind it there are **stores**, each with a name chosen by the operator: a store is either a **Garage** (S3 API) or a set of **Caddy** nodes with the WebDAV module (docs/store.md). The operator installs Garage, Caddy nodes or both, with one Helm chart (`deploy/charts/cinim-storage`); the module serves any number of stores of either kind. The core no longer knows what a store is made of: it asks the module for an object in a named store.

```
shard (cinim-shard)                     cinim-storage (a Deployment; may serve several shards)
  core ── HTTP, token per request ──►  API ── registry of stores, inventory, repair queue: tables `storage_*` in rqlite
                                         ├── store "garage-main"  ──► Garage (S3)
                                         └── store "caddy-main"   ──► Caddy node 0, Caddy node 1 (mirror)
```

## The protocol (our choice): HTTP with a signed token per request

HTTP, because the Caddy nodes are HTTP anyway, it goes through any Ingress, Service or mesh, it can be tried with `curl`, and no wire format of our own is needed. Every request carries `Authorization: Bearer v1.<expires>.<HMAC>` and `X-Cinim-Shard` (`common/storagetoken.nim`: the shard, the method, the decoded path with the query as sent, the expiry; two minutes), under the secret of that shard, which the core and the module share (a Kubernetes Secret). The module serves the shards named in `CINIM_STORAGE_SHARDS` (`001=<secret>;002=<secret>`), each with its own secret, so one shard's secret opens nothing of another's. It was measured first (phase 0, below): the HTTP server of the services (GuildenStern, `common/httpsrv.nim`) takes bodies of 8 MiB at the rates we need.

The operations are those of `ObjectBackend`, with the store's name; the action is in the query, which is signed with the rest of the target, so that a token for a read is no good for a delete. `{store}` is a name or `_default`.

| Operation | Request |
|---|---|
| put an object (up to 8 MiB) | `PUT /v1/stores/{store}/objects/{key}` with `X-Content-SHA256` (checked when given) |
| start a multipart upload | `POST /v1/stores/{store}/objects/{key}?uploads` -> `{"upload_id"}` |
| upload a part | `PUT /v1/stores/{store}/objects/{key}?upload={id}&part={n}` -> `{"etag"}` |
| complete / abort | `POST …?upload={id}` with `{"parts": [[1, "etag"], ...]}` / `DELETE …?upload={id}` |
| read a range | `GET /v1/stores/{store}/objects/{key}` with `Range: bytes=a-b` (206; at most 16 MiB) |
| size | `GET …?stat` -> `{"size"}` |
| delete | `DELETE …/objects/{key}` (an object that is not there is fine) |
| the stores | `GET /v1/stores` -> names, kinds, the default (no secrets) |
| the nodes of a Caddy store ask | `GET /v1/internal/node-auth?node=<id>` (`forward_auth`) |
| the operator's calls | `/v1/admin/stores...` with the admin token (`Authorization: Bearer <token>`, which the core does not hold): `GET`; `PUT /{name}`, `DELETE /{name}[?force=1]`, `POST /{name}:check`, `POST /{name}:default` |

Errors: 401 (the token), 404 `no_such_object` / `no_such_store`, 409 `not_configured`, 400 for a bad key, range, part or digest, 413 above 8 MiB in one call, 502 when the store said no, 503 with `Retry-After` when the store or the database did not answer (the core treats 5xx and 429 as "try again").

The core says which shard it is (the header `X-Cinim-Shard`, signed into the token; a header that does not match the token is refused). **The shard is part of every key** in the module: an object `acme/s1_01a1/dist/app.txt` of shard `001` lies as `001/acme/s1_01a1/dist/app.txt`, because the names of tenants repeat between shards. The core still decides who may read or write what (the shim has no route to the store, D-46). The module does not know organisations.

## What lives in the module

* **No local state.** Nothing on a disk of the module's own: it is a Deployment, with no volume, that can be killed and started again at once, and a second replica can run beside the first.
* **The state is in rqlite, the shard's own by default.** The module uses the rqlite of the shard it belongs to (`rqlite.url` of the chart) and makes tables of its own there, all named `storage_*` (`storage_stores`, `storage_objects`, `storage_repair`, `storage_uploads`, `storage_lease`) and migrated by the module. It never reads or writes the tables of the core, and the core never touches `storage_*`. A module that serves **several shards** gets an rqlite of its own (`module.db.url`), a separate instance that the operator runs; there is no other kind of database.
* **Stores and their settings** (endpoints, Garage keys, Caddy node URLs): in `storage_stores`, sealed with a key from the module's own Secret (the module holds the key, the database the sealed values). The core does not hold them any more (D-49 changes here: the core is the source of settings for the other permanent modules, but this one is installed on its own and is configured by its operator).
* **The mirror** of a Caddy store (write to every node, `min_acks`, read from the first that has it) and the **repair**: the code of `httpstore.nim` and `storerepair.nim`, moved. A Garage store is one S3 endpoint; Garage replicates by itself.
* **An inventory** (table `storage_objects`: shard, store, key, size, SHA-256, state, written at) that the module keeps for every object it accepted. It replaces the rows of `artifacts` and `caches` that the repair and the check used to compare nodes against, so the module needs nothing of the core's tables. The sweep of expired artifacts stays in the core (it knows retention and holds) and tells the module to delete.
* **The queue of repair** (`storage_repair`, the old `store_repair` moved), the **pause** after a failure, the **check** of the inventory against the nodes (a slice at a time). With more than one replica, the pass is run by the one that holds the **lease** (a row of `storage_lease` that is renewed; the others wait), as the core's other periodic jobs do.
* **The tokens for Caddy nodes**: a node's `forward_auth` asks the module, not the core (`GET /v1/internal/node-auth?node=...`, as in `storage/storeauth.nim`).

## What changes in the core

* `core/objectstore.nim` stops being the settings of one store: the core keeps only the address of the module and the shared secret (a Secret, as for the controllers' keys), and a `RemoteBackend` (HTTP) that implements `ObjectBackend` over the API above, with a store name and its shard.
* **Which store an object lies in is a column** of `artifacts` and `caches` (`store`, empty = the module's default). A read goes to the store the row names; a write goes to the store that the organisation's setting chooses *at that moment*, and the row records it. So switching an organisation to another store never loses or moves anything: old objects are read where they are, new ones go to the new store.
* **The choice per organisation**: the settings of the organisation get `storage: {artifacts, caches, held_logs, audit}`, each a store name from `GET /v1/stores` (empty = the default of the shard). Changed by the **administrator of the organisation** (`PUT /api/v1/organizations/{slug}/storage`), validated against the list the module gives, written to the audit log (`storage.select`). Backups are not an organisation's: they use the module's default store of the platform.
* The settings of a store stop being in the core's API (in phase 1 `/api/v1/storage` is replaced by `/api/v1/stores`; in phase 2 the operator's calls go to the module's admin API).
* **The ZeroMQ node `cinim-store` goes** (D-57): `src/store`, `src/core/zstore.nim`, `cinim-storectl`, the image target `store`, `deploy/examples/store/store.yaml`, the CURVE key pair `store`. The Caddy node replaces it.

## The chart `cinim-storage` (built, phase 3)

`deploy/charts/cinim-storage`, one release per shard, into the namespace of the shard (so that it finds the shard's rqlite at `http://rqlite`; `rqliteUrl` points elsewhere for a module of several shards). What it makes:

* **The module**: a Deployment of `replicas` Pods (no volume), the Service `cinim-storage:18090`, the Secret `cinim-storage` (or the operator's own, `secrets.existingSecret`) with `shards` (`001=<secret>`; also the key `shard-001` that the core's chart reads), `adminToken`, `sealKey`, `nodeToken`. Nothing is generated at render time; the chart refuses secrets that are too short.
* **Garage** (`stores.garage.enabled`, on by default): a StatefulSet of one node on a volume of its own. Its sidecar makes the layout, the bucket and an access key once, keeps the key on the volume, and **registers the store with the module** (`POST /v1/admin/stores/<name>`, repeated until the module takes it, at every start of the Pod). The checked script of the example moved into the chart.
* **Caddy** (`stores.caddy.enabled`): a StatefulSet of 1 to 4 nodes (one per machine by default, `spreadAcrossNodes`) with the Caddy image of the fork (`stores.caddy.image`, target `caddy-store`), each node's `forward_auth` pointed at the module. The Job `cinim-storage-register` (a Helm hook after install and upgrade) registers the nodes with the module, with `nodeToken` and `minAcks`, waiting up to ten minutes for the module and the nodes.
* **Stores that are already there** (`stores.external`, a list): buckets with their key in a Secret of yours; the same Job tells the module. External Caddy nodes are not supported.
* **Network policies** (`networkPolicy.enabled`): the module is reached by the core's Pods and by what the chart installs; the Caddy nodes and Garage only by the module.
* `default: true` on a store makes it the default at every install and upgrade; with none marked, the first one registered is, and an operator's `:default` stays.

The shard's chart (`cinim-shard`) got `storage: {url, tokenSecret: {name, key}}` and nothing else about stores: the core's `CINIM_STORAGE_URL` and `CINIM_STORAGE_TOKEN`. The sample `helm template` of both charts renders; the registration scripts were run against a stand-in module with the real busybox. **Not tried on a cluster** (phase 4).

## Phase 1 as built (D-59)

In the core, before the module exists: tables `object_stores` (name, kind, config, default flag) and `org_storage` (organisation, purpose, store), a column `store` in `artifacts`, `caches` and `held_logs` (the row remembers where the object was written; switching an organisation's store never moves or loses objects), `core/objectstore.nim` (`saveStore`, `forgetStore`, `loadStore(name)`, `storeFor(tenant, purpose)`, `StoreSet`). API: `GET /api/v1/stores`, `PUT|DELETE /api/v1/stores/{name}`, `POST /api/v1/stores/{name}:check`, `POST /api/v1/stores/{name}:default`, `GET|PUT /api/v1/organizations/{slug}/storage` (`{"artifacts": "<store>", "caches": "<store>", ...}`, an empty name is the default; audit event `storage.select`). Purposes: `artifacts`, `caches`, `held_logs`, `audit`; the core uses the first two so far (held logs are not switched on, DAT-006; the audit stays in the database). **The org-level administrator does not exist yet** (RBAC is shard-level, IAM-001): the organisation's choice is for a shard administrator until organisation roles are built. The old single store (`vault_meta` `objectstore`) is not read any more: there is no migration (owner's decision), the stores are set up again.

## Phase 2 as built (D-60)

`src/storage` is the program `cinim-storage` (a Deployment with no volume): `CINIM_RQLITE_URL`, `CINIM_STORAGE_PORT` (18090), `CINIM_STORAGE_SHARDS`, `CINIM_STORAGE_ADMIN_TOKEN`, `CINIM_STORAGE_SEAL_KEY` (a key of its own, apart from the database), `CINIM_STORAGE_REPAIR_SECONDS` (60), `CINIM_STORAGE_CHECK_SECONDS` (600). It makes its tables at start (`storage_stores`, `storage_objects`, `storage_repair`, `storage_lease`) and waits for rqlite for two minutes. The stores and their sealed secrets, the inventory (every object put or completed, with its size; a delete removes it), the repair queue and the lease are rows there; a killed module comes back with all of it (`tstorageproc`). The repair loop runs in every replica but works only in the one that holds the lease (120 s, renewed each pass; another replica takes over when it ends). The core: `RemoteBackend` and `moduleStores` (`core/storageclient.nim`, a list kept for 5 s), `CINIM_STORAGE_URL` and `CINIM_STORAGE_TOKEN` (and `CINIM_SHARD`); the code of `s3backend`, `httpstore`, `davclient`, `replicas`, `storeauth` and the repair moved to `src/storage`, the seam to `src/common/storagebackend.nim`, and `src/store`, `core/zstore.nim`, `cinim-storectl`, the example `store.yaml` and the image target `store` are gone. `GET /api/v1/stores` of the core only shows the module's stores; `PUT`/`DELETE` of a store are the module's admin API. `object_stores`, `store_repair` and the old secrets are dropped from the core's database at start (docs/compat.md).

What is not done: **uploads that were never completed** are aborted by the core's sweep as before, the module keeps no list of them; an object put but whose inventory write failed is found by nobody; the module does not **count bytes** per shard; one **admin token** for all stores; `held_logs` and `audit` are purposes without a user yet.

## Phases (each is tested first and can stop there)

0. **Measure** (done 2026-10-17): the HTTP server of the services (GuildenStern, `common/httpsrv.nim`) with bodies of 8 MiB on one machine: PUT 150-573 MB/s, GET about 1.9 GB/s, resident memory 112 MiB; it needs `bufferlength` of 10 MiB for `Compact` mode (a body must fit the receive buffer). **The protocol is HTTP** with the token per request.
1. **In the core, still one process** (built 2026-10-17, D-59): a registry of named stores, the `store` column, the per-organisation choice and its API, the audit event; Garage and Caddy through the code that exists. This already gives the choice of store to organisations.
2. **The module** (built 2026-10-17, D-60): `src/storage` with the API, the registry and the inventory in `storage_*` tables of rqlite, the shard in every key, the mirror and repair moved from the core, the lease for the pass; the core uses `RemoteBackend`. The in-process backends and the ZeroMQ node are removed.
3. **The chart** (built 2026-10-17) `cinim-storage` with the Garage bootstrap (a sidecar) and the Caddy StatefulSet, the `storage:` values of `cinim-shard`, the examples replaced, a note on moving an existing shard: **there is no migration**: the store that exists today (its settings and its objects) is deleted, and the stores of the module start empty (decision of the owner, 2026-10-17).
4. **On the TESTING cluster**: install with Garage, with Caddy, with both; select per organisation; kill a Caddy node; kill the module and see it come back at once; switch an organisation and read the old objects.

## Open points

* Direct upload from the shim to the module (no hop through the core) for large artifacts: not now; the core stays in the path so that it can check the rights and count bytes (docs/artifacts.md).
* The lease of the repair pass lives 120 s and is renewed each pass (60 s); a second replica takes over within two minutes of the first one stopping. Shorter would need a faster loop.
