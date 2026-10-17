## The object stores of the shard (DAT-003, D-46, D-59, D-60): where the artifacts and caches of runs live.
##
## The stores are the storage module's (docs/storage-module.md): it keeps their settings and their secrets, and the core holds only its address and the secret its calls are signed with
## (core/storageclient.nim). What the core keeps is which store an organisation chose for which purpose (`org_storage`) and, in each row of an artifact or a cache, the store it was written to.
## A step has no access to the store: its shim moves the bytes to and from the core (core/artifactingest.nim), and the core talks to the store through `ObjectBackend`
## (common/storagebackend.nim). The objects of a run are `<tenant>/<run>/<path>`; a step may only
## put and get what its own options declared (`artifacts = {upload = {...}, download = {...}}`), in its own run.
import std/[json, strutils, sequtils]
import ../common/[rqlite, storagebackend]
import storageclient
export storagebackend, storageclient

const
  maxFilesPerStep* = 1000
  maxObjectBytes* = 2'i64 * 1024 * 1024 * 1024      ## one artifact
  maxRunBytes* = 10'i64 * 1024 * 1024 * 1024        ## all the artifacts of a run
  maxPathLen* = 512

func cleanPath*(p: string): string =
  ## the path of an artifact inside its run, or "" if it is not one: relative, no `..`, no empty or `.` parts, no control characters
  if p.len == 0 or p.len > maxPathLen or p[0] == '/' or p[^1] == '/': return ""
  for ch in p:
    if ch < ' ' or ch == '\x7f' or ch == '\\': return ""
  for part in p.split('/'):
    if part.len == 0 or part == "." or part == "..": return ""
  p

proc artifactDecl*(optsJson: string): tuple[upload, download: seq[string]] =
  ## what the step's options declared (`artifacts = {upload = {...}, download = {...}}`); damaged options declare nothing
  if optsJson.len == 0: return
  try:
    let a = parseJson(optsJson){"artifacts"}
    if a == nil or a.kind != JObject: return
    for k in ["upload", "download"]:
      if a.hasKey(k) and a[k].kind == JArray:
        for v in a[k]:
          if v.kind == JString: (if k == "upload": result.upload.add v.getStr else: result.download.add v.getStr)
  except CatchableError: discard

proc hasArtifacts*(optsJson: string): bool =
  let d = artifactDecl(optsJson)
  d.upload.len > 0 or d.download.len > 0

func objectKey*(tenant, runId, path: string): string = tenant & "/" & runId & "/" & path

# ------------------------------------------------------------------ the stores

const
  purposes* = ["artifacts", "caches", "held_logs", "audit"]    ## what an organisation may choose a store for (D-59, docs/storage-module.md)

func validPurpose*(purpose: string): bool = purpose in purposes

proc orgStorage*(c: var RqClient; tenant: string): seq[(string, string)] =
  ## the purposes for which the organisation chose a store, with the store, in the order of the purposes' names
  let v = c.query(%*[["SELECT purpose, store_name FROM org_storage WHERE tenant_id = ? ORDER BY purpose", tenant]])["results"][0]{"values"}
  if v != nil:
    for row in v: result.add (row[0].getStr, row[1].getStr)

proc setOrgStorage*(c: var RqClient; tenant, purpose, store, by: string; now: int64): string =
  ## "" if done, else why not. An empty `store` clears the choice (the default again). The store has to be one of the storage module's.
  if not validPurpose(purpose): return "the purpose is one of " & purposes.join(", ")
  if store.len == 0:
    discard c.execute(%*[["DELETE FROM org_storage WHERE tenant_id = ? AND purpose = ?", tenant, purpose]])
    return ""
  let known = moduleStores()
  if not known.ok: return "the storage module could not be asked which stores it has (" & known.error & ")"
  if known.stores.allIt(it.name != store): return "no such store: " & store
  discard c.execute(%*[["INSERT INTO org_storage (tenant_id, purpose, store_name, updated_by, updated_at) VALUES (?, ?, ?, ?, ?) " &
    "ON CONFLICT(tenant_id, purpose) DO UPDATE SET store_name = excluded.store_name, updated_by = excluded.updated_by, updated_at = excluded.updated_at",
    tenant, purpose, store, by, now]])
  ""

proc storeFor*(c: var RqClient; tenant, purpose: string): string =
  ## the name of the store the organisation uses for the purpose: its own choice, else the module's default; "" if the module could not say (the module then takes its default for "")
  let v = c.query(%*[["SELECT store_name FROM org_storage WHERE tenant_id = ? AND purpose = ?", tenant, purpose]])["results"][0]{"values"}
  if v != nil and v.len > 0: return v[0][0].getStr
  let known = moduleStores()
  if known.ok: known.defaultName else: ""

# ------------------------------------------------------------------ the stores of a pass

type
  StoreSet* = ref object
    ## the backends of the stores that one request or one pass of a sweep needs. A request that touches rows of several stores (a sweep, a listing of caches) asks for each by the name that
    ## the row carries; a backend is the storage module's address and a store name, so it costs nothing to make. `fixed` is for the tests: every name gives that one store.
    fixed: ObjectBackend

  Resolved* = object
    be*: ObjectBackend
    error*: string                ## not_configured, no_such_store
    retry*: bool

proc newStoreSet*(): StoreSet = StoreSet()

proc fixedStoreSet*(be: ObjectBackend): StoreSet = StoreSet(fixed: be)

proc resolve*(ss: StoreSet; name: string): Resolved =
  ## the backend of the store `name` ("" is the module's default store)
  if ss.fixed != nil: return Resolved(be: ss.fixed)
  if not storageConfigured(): return Resolved(error: "not_configured")
  Resolved(be: RemoteBackend(store: name))

proc storesReady*(): bool =
  ## whether a step may be started that needs the object store: the module is set up, and has a store (or could not be asked just now, which is not a reason to refuse)
  if not storageConfigured(): return false
  let known = moduleStores()
  not known.ok or known.stores.len > 0

# ------------------------------------------------------------------ the rows

proc recordArtifact*(c: var RqClient; id, tenant, runId: string; step: int; path, key: string; size: int64; sha256, state, uploadId: string; now: int64; store = "") =
  ## a path is one artifact of a run: a retry of the step puts it again (and may put it in another store)
  discard c.execute(%*[["INSERT INTO artifacts (id, tenant_id, run_id, step_ordinal, path, s3_key, size, sha256, state, created_at, upload_id, store) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) " &
    "ON CONFLICT(run_id, path) DO UPDATE SET step_ordinal = excluded.step_ordinal, size = excluded.size, sha256 = excluded.sha256, state = excluded.state, " &
    "created_at = excluded.created_at, upload_id = excluded.upload_id, store = excluded.store",
    id, tenant, runId, step, path, key, size, sha256, state, now, uploadId, store]])

proc uploadingRow*(c: var RqClient; runId, path: string): tuple[found: bool, key, uploadId: string, size: int64, store: string] =
  let r = c.query(%*[["SELECT s3_key, upload_id, size, store FROM artifacts WHERE run_id = ? AND path = ? AND state = 'uploading'", runId, path]])
  let v = r["results"][0]{"values"}
  if v != nil and v.len > 0: (true, v[0][0].getStr, v[0][1].getStr, v[0][2].getBiggestInt, v[0][3].getStr) else: (false, "", "", 0'i64, "")

proc markStored*(c: var RqClient; runId, path: string): bool =
  c.execute(%*[["UPDATE artifacts SET state = 'stored', upload_id = '' WHERE run_id = ? AND path = ? AND state = 'uploading'", runId, path]])["results"][0]{"rows_affected"}.getInt > 0

proc forgetArtifact*(c: var RqClient; runId, path: string) =
  discard c.execute(%*[["DELETE FROM artifacts WHERE run_id = ? AND path = ? AND state = 'uploading'", runId, path]])

proc orgQuota*(c: var RqClient; runId: string): int64 =
  ## the quota of artifact bytes of the organisation the run belongs to (its profile's setting; 0: no limit)
  let v = c.query(%*[["SELECT COALESCE(p.artifact_quota_bytes, 0) FROM runs r LEFT JOIN execution_profiles p ON p.id = r.profile_id WHERE r.id = ?", runId]])["results"][0]{"values"}
  if v != nil and v.len > 0: v[0][0].getBiggestInt else: 0'i64

proc orgBytes*(c: var RqClient; tenant, runId, exceptPath: string): int64 =
  ## what the organisation holds in artifacts (stored and under way), without the file at `exceptPath` of this run, which a new one replaces
  c.query(%*[["SELECT COALESCE(SUM(size), 0) FROM artifacts WHERE tenant_id = ? AND NOT (run_id = ? AND path = ?)", tenant, runId, exceptPath]])["results"][0]{"values"}[0][0].getBiggestInt

proc runBytes*(c: var RqClient; runId, exceptPath: string): int64 =
  ## what the run's other artifacts hold already
  c.query(%*[["SELECT COALESCE(SUM(size), 0) FROM artifacts WHERE run_id = ? AND path != ?", runId, exceptPath]])["results"][0]{"values"}[0][0].getBiggestInt

proc listArtifacts*(c: var RqClient; runId: string): JsonNode =
  result = newJArray()
  let r = c.query(%*[["SELECT path, size, sha256, step_ordinal, created_at FROM artifacts WHERE run_id = ? AND state = 'stored' ORDER BY path", runId]])
  let v = r["results"][0]{"values"}
  if v != nil:
    for row in v: result.add %*{"path": row[0].getStr, "size": row[1].getBiggestInt, "sha256": row[2].getStr, "step": row[3].getInt, "created_at": row[4].getBiggestInt}

proc storedArtifact*(c: var RqClient; runId, path: string): tuple[found: bool, key: string, size: int64, sha256, store: string] =
  let r = c.query(%*[["SELECT s3_key, size, sha256, store FROM artifacts WHERE run_id = ? AND path = ? AND state = 'stored'", runId, path]])
  let v = r["results"][0]{"values"}
  if v != nil and v.len > 0: (true, v[0][0].getStr, v[0][1].getBiggestInt, v[0][2].getStr, v[0][3].getStr) else: (false, "", 0'i64, "", "")

proc storedUnder*(c: var RqClient; runId, prefix: string): seq[tuple[path, key: string; size: int64; sha256, store: string]] =
  ## the stored artifacts of a run whose path is `prefix` or lies under `prefix/`
  let r = c.query(%*[["SELECT path, s3_key, size, sha256, store FROM artifacts WHERE run_id = ? AND state = 'stored' AND (path = ? OR substr(path, 1, ?) = ?) ORDER BY path",
                      runId, prefix, prefix.len + 1, prefix & "/"]])
  let v = r["results"][0]{"values"}
  if v != nil:
    for row in v: result.add (row[0].getStr, row[1].getStr, row[2].getBiggestInt, row[3].getStr, row[4].getStr)
