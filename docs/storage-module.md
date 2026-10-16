# The storage module (`cinim-storage`): a service of its own, with Garage and Caddy behind it

*Status: **proposed**, 2026-10-17; phases 0 and 1 are built (the choice of store per organisation works inside the core, D-59), the module itself (phase 2 onwards) is not. It replaces the store settings that live in the core today (`vault_meta` `objectstore`, `core/objectstore.nim`) and moves the code of `core/s3backend.nim`, `core/httpstore.nim`, `core/storerepair.nim` and `core/storeauth.nim` out of the core. Decisions of the owner (2026-10-17): a service and a chart of their own; the mirror, the repair and the check live in the module, which keeps its state in **rqlite** (the shard's by default) and has **no local state at all**, so it is a plain Deployment that can be restarted at once; the administrator of an organisation chooses its store; the ZeroMQ node `cinim-store` (D-57) goes; tenants are **not** unique across shards, so the shard is part of every key; the protocol is for us to choose.*

## What it is

One service, `cinim-storage`, that the core (and nothing else) talks to. Behind it there are **stores**, each with a name chosen by the operator: a store is either a **Garage** (S3 API) or a set of **Caddy** nodes with the WebDAV module (docs/store.md). The operator installs Garage, Caddy nodes or both, with one Helm chart (`deploy/charts/cinim-storage`); the module serves any number of stores of either kind. The core no longer knows what a store is made of: it asks the module for an object in a named store.

```
shard (cinim-shard)                     cinim-storage (a Deployment; may serve several shards)
  core ── HTTP, token per request ──►  API ── registry of stores, inventory, repair queue: tables `storage_*` in rqlite
                                         ├── store "garage-main"  ──► Garage (S3)
                                         └── store "caddy-main"   ──► Caddy node 0, Caddy node 1 (mirror)
```

## The protocol (our choice): HTTP with a signed token per request

HTTP, because the Caddy nodes are HTTP anyway, it goes through any Ingress, Service or mesh, it can be tried with `curl`, and no wire format of our own is needed. Every request carries `Authorization: Bearer v1.<expires>.<HMAC>` made as in `core/storeauth.nim` (node id, method, decoded path, expiry; two minutes), under a secret that the core and the module share (a Kubernetes Secret). **To be measured first** (phase 0): the HTTP server of the services (GuildenStern, `common/httpsrv.nim`) with bodies of 8 MiB at the rates we need; if it cannot, the same operations go over ZeroMQ with CURVE, as `cinim-store` did.

The operations are those of `ObjectBackend`, with the store's name and the shard:

| Operation | Request |
|---|---|
| put an object (up to 8 MiB) | `PUT /v1/stores/{store}/objects/{key}` with `X-Content-SHA256` |
| start / upload a part of / complete / abort a multipart upload | `POST /v1/stores/{store}/uploads?key=...` (answers the upload id), `PUT /v1/uploads/{id}/parts/{n}`, `POST /v1/uploads/{id}:complete` with the list of parts, `DELETE /v1/uploads/{id}` |
| read a range | `GET /v1/stores/{store}/objects/{key}` with `Range` |
| size | `HEAD` of the same |
| delete | `DELETE` of the same |
| the stores and their health | `GET /v1/stores` (names, kind, default, ok / degraded / down, free space if known) |
| the operator's own calls (add, change, test a store; the repair queue) | `/v1/admin/...`, with a separate token that the core does not hold |

The core says which shard it is (the header `X-Cinim-Shard`, signed into the token). **The shard is part of every key** in the module: an object `acme/s1_01a1/dist/app.txt` of shard `001` lies as `001/acme/s1_01a1/dist/app.txt`, because the names of tenants repeat between shards. The core still decides who may read or write what (the shim has no route to the store, D-46). The module does not know organisations.

## What lives in the module

* **No local state.** Nothing on a disk of the module's own: it is a Deployment, with no volume, that can be killed and started again at once, and a second replica can run beside the first.
* **The state is in rqlite, the shard's own by default.** The module uses the rqlite of the shard it belongs to (`rqlite.url` of the chart) and makes tables of its own there, all named `storage_*` (`storage_stores`, `storage_objects`, `storage_repair`, `storage_uploads`, `storage_lease`) and migrated by the module. It never reads or writes the tables of the core, and the core never touches `storage_*`. A module that serves **several shards** gets an rqlite of its own (`module.db.url`), a separate instance that the operator runs; there is no other kind of database.
* **Stores and their settings** (endpoints, Garage keys, Caddy node URLs): in `storage_stores`, sealed with a key from the module's own Secret (the module holds the key, the database the sealed values). The core does not hold them any more (D-49 changes here: the core is the source of settings for the other permanent modules, but this one is installed on its own and is configured by its operator).
* **The mirror** of a Caddy store (write to every node, `min_acks`, read from the first that has it) and the **repair**: the code of `httpstore.nim` and `storerepair.nim`, moved. A Garage store is one S3 endpoint; Garage replicates by itself.
* **An inventory** (table `storage_objects`: shard, store, key, size, SHA-256, state, written at) that the module keeps for every object it accepted. It replaces the rows of `artifacts` and `caches` that the repair and the check used to compare nodes against, so the module needs nothing of the core's tables. The sweep of expired artifacts stays in the core (it knows retention and holds) and tells the module to delete.
* **The queue of repair** (`storage_repair`, the old `store_repair` moved), the **pause** after a failure, the **check** of the inventory against the nodes (a slice at a time). With more than one replica, the pass is run by the one that holds the **lease** (a row of `storage_lease` that is renewed; the others wait), as the core's other periodic jobs do.
* **The tokens for Caddy nodes**: a node's `forward_auth` asks the module, not the core (`GET /v1/internal/node-auth?node=...`, as in `core/storeauth.nim`).

## What changes in the core

* `core/objectstore.nim` stops being the settings of one store: the core keeps only the address of the module and the shared secret (a Secret, as for the controllers' keys), and a `RemoteBackend` (HTTP) that implements `ObjectBackend` over the API above, with a store name and its shard.
* **Which store an object lies in is a column** of `artifacts` and `caches` (`store`, empty = the module's default). A read goes to the store the row names; a write goes to the store that the organisation's setting chooses *at that moment*, and the row records it. So switching an organisation to another store never loses or moves anything: old objects are read where they are, new ones go to the new store.
* **The choice per organisation**: the settings of the organisation get `storage: {artifacts, caches, held_logs, audit}`, each a store name from `GET /v1/stores` (empty = the default of the shard). Changed by the **administrator of the organisation** (`PUT /api/v1/organizations/{slug}/storage`), validated against the list the module gives, written to the audit log (`storage.select`). Backups are not an organisation's: they use the module's default store of the platform.
* The settings of a store stop being in the core's API (in phase 1 `/api/v1/storage` is replaced by `/api/v1/stores`; in phase 2 the operator's calls go to the module's admin API).
* **The ZeroMQ node `cinim-store` goes** (D-57): `src/store`, `src/core/zstore.nim`, `cinim-storectl`, the image target `store`, `deploy/examples/store/store.yaml`, the CURVE key pair `store`. The Caddy node replaces it.

## The chart `cinim-storage`

```yaml
module:    {image, replicas: 1, secret: {tokenSecretName, adminTokenSecretName, sealKeySecretName},
            db: {url: ""}    # empty: the rqlite of the shard (rqlite.url of the release it is installed with); else the rqlite of the operator's own, for a module of several shards
            }                # a Deployment: no volume, no StatefulSet
stores:                       # the named stores, in the order shown to organisations; `default` is the one an empty setting means
  - {name: garage-main, kind: garage, default: true, garage: {install: true | external: {endpoint, region, bucket, keySecret}}}
  - {name: caddy-main,  kind: caddy,  caddy: {install: true, nodes: 2, persistence: {...}, minAcks: 0 | external: {nodes: [...]}}}
garage:    # installed with the chart when a store above says install: true (a StatefulSet, it holds data; a Job makes the layout, the bucket and the key once and keeps them in a Secret)
caddy:     # a StatefulSet of nodes (they hold data) with the module `cinim-webdav` (deploy/examples/store/caddy-store.yaml becomes this)
networkPolicy: {enabled: true}   # only the core's Pods reach the module, only the module reaches the nodes
```

Any of Garage and Caddy can be installed by the chart, brought from outside, or both; one store of each kind in the beginning. The shard's chart (`cinim-shard`) gets `storage: {url, tokenSecretName}` and nothing else about stores.

## Phase 1 as built (D-59)

In the core, before the module exists: tables `object_stores` (name, kind, config, default flag) and `org_storage` (organisation, purpose, store), a column `store` in `artifacts`, `caches` and `held_logs` (the row remembers where the object was written; switching an organisation's store never moves or loses objects), `core/objectstore.nim` (`saveStore`, `forgetStore`, `loadStore(name)`, `storeFor(tenant, purpose)`, `StoreSet`). API: `GET /api/v1/stores`, `PUT|DELETE /api/v1/stores/{name}`, `POST /api/v1/stores/{name}:check`, `POST /api/v1/stores/{name}:default`, `GET|PUT /api/v1/organizations/{slug}/storage` (`{"artifacts": "<store>", "caches": "<store>", ...}`, an empty name is the default; audit event `storage.select`). Purposes: `artifacts`, `caches`, `held_logs`, `audit`; the core uses the first two so far (held logs are not switched on, DAT-006; the audit stays in the database). **The org-level administrator does not exist yet** (RBAC is shard-level, IAM-001): the organisation's choice is for a shard administrator until organisation roles are built. The old single store (`vault_meta` `objectstore`) is not read any more: there is no migration (owner's decision), the stores are set up again.

## Phases (each is tested first and can stop there)

0. **Measure** (done 2026-10-17): the HTTP server of the services (GuildenStern, `common/httpsrv.nim`) with bodies of 8 MiB on one machine: PUT 150-573 MB/s, GET about 1.9 GB/s, resident memory 112 MiB; it needs `bufferlength` of 10 MiB for `Compact` mode (a body must fit the receive buffer). **The protocol is HTTP** with the token per request.
1. **In the core, still one process** (built 2026-10-17, D-59): a registry of named stores, the `store` column, the per-organisation choice and its API, the audit event; Garage and Caddy through the code that exists. This already gives the choice of store to organisations.
2. **The module**: `src/storage` with the API, the registry and the inventory in `storage_*` tables of rqlite, the shard in every key, the mirror and repair moved from the core, the lease for the pass; the core uses `RemoteBackend`. The in-process backends and the ZeroMQ node are removed.
3. **The chart** `cinim-storage` with the Garage bootstrap Job and the Caddy StatefulSet, the `storage:` values of `cinim-shard`, the examples replaced, a note on moving an existing shard: **there is no migration**: the store that exists today (its settings and its objects) is deleted, and the stores of the module start empty (decision of the owner, 2026-10-17).
4. **On the TESTING cluster**: install with Garage, with Caddy, with both; select per organisation; kill a Caddy node; kill the module and see it come back at once; switch an organisation and read the old objects.

## Open points

* Direct upload from the shim to the module (no hop through the core) for large artifacts: not now; the core stays in the path so that it can check the rights and count bytes (docs/artifacts.md).
* The lease of the repair pass is in the database (`storage_lease`); how long it lives and how fast a second replica takes over is to be chosen in phase 2.
