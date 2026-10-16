## The object store of the shard (DAT-003, D-46, Garage or any S3-compatible store): where the artifacts of runs live.
##
## The settings (endpoint, region, bucket, the access key's id) are in the database; the secret of the access key is sealed there like a step secret (D-45,
## core/secretvault.nim) under the tenant `_platform`, so that a restored database brings the store back and nothing is kept in Kubernetes Secrets. A step has
## no access to the store: its shim moves the bytes to and from the core (core/artifactingest.nim), and the core talks to the store through `ObjectBackend`
## (core/storagebackend.nim), which is the seam where the storage module can leave the core. The objects of a run are `<tenant>/<run>/<path>`; a step may only
## put and get what its own options declared (`artifacts = {upload = {...}, download = {...}}`), in its own run.
import std/[json, strutils, sequtils, os, locks]
import ../common/[rqlite, sigv4, zmqcurve]
import secretvault, storagebackend, s3backend, zstore, httpstore, replicas
export storagebackend

const
  platformTenant* = "_platform"
  secretName = "OBJECTSTORE_SECRET_KEY"
  metaKey = "objectstore"
  maxFilesPerStep* = 1000
  maxObjectBytes* = 2'i64 * 1024 * 1024 * 1024      ## one artifact
  maxRunBytes* = 10'i64 * 1024 * 1024 * 1024        ## all the artifacts of a run
  maxPathLen* = 512

type
  StoreConfig* = object
    found*: bool
    endpoint*, region*, bucket*, keyId*: string
    kind*: string                ## "" or "s3": a bucket; "dav": store nodes of our own that are Caddy with WebDAV (docs/store.md), `nodes` are their URLs, the secret is the token the requests are signed with;
                                 ## "nodes": store nodes of ours over ZeroMQ (the first version of the node, docs/store.md), `nodes` are their addresses, the secret is their token
    nodes*: seq[string]
    minAcks*: int
    transport*: string           ## "" or "curve": CURVE on the link to the nodes; "plain": none, for a network that is encrypted anyway (docs/store.md)

  Store* = object
    ok*: bool
    cfg*: StoreConfig
    secret*: string
    error*: string               ## when not ok: not_configured, secrets_unavailable, unreadable
    retry*: bool

func isMirror*(cfg: StoreConfig): bool = cfg.kind in ["nodes", "dav"]
  ## the store is a mirror of store nodes of our own

func checkConfig*(cfg: StoreConfig; secret: string): string =
  ## "" if these may be the settings of the store, else what is wrong
  if cfg.kind == "dav":
    if cfg.nodes.len < 1 or cfg.nodes.len > 4: return "nodes is 1..4 URLs of store nodes"
    for a in cfg.nodes:
      let rest = if a.startsWith("https://"): a[8 .. ^1] elif a.startsWith("http://"): a[7 .. ^1] else: ""
      if rest.len == 0 or a.len > 200 or a.anyIt(it < '!' or it > '~') or rest.split('/')[0].count(':') != 1 or '?' in a or '#' in a: return "a node is http://host:port or https://host:port"
    if cfg.minAcks < 0 or cfg.minAcks > cfg.nodes.len: return "min_acks is 0 (every node, the default) or 1.." & $cfg.nodes.len
    if secret.len < 8 or secret.len > 256 or secret.anyIt(it < '!' or it > '~'): return "token is 8..256 printable characters"
    return ""
  if cfg.kind == "nodes":
    if cfg.nodes.len < 1 or cfg.nodes.len > 4: return "nodes is 1..4 addresses of store nodes"
    for a in cfg.nodes:
      if not a.startsWith("tcp://") or a.len > 200 or a.anyIt(it < '!' or it > '~'): return "a node is tcp://host:port"
    if cfg.minAcks < 0 or cfg.minAcks > cfg.nodes.len: return "min_acks is 0 (every node, the default) or 1.." & $cfg.nodes.len
    if cfg.transport notin ["", "curve", "plain"]: return "transport is curve (the default) or plain"
    if secret.len < 8 or secret.len > 256 or secret.anyIt(it < '!' or it > '~'): return "token is 8..256 printable characters"
    return ""
  if not splitEndpoint(cfg.endpoint).ok: return "endpoint is scheme://host[:port], http or https, with no path"
  if cfg.region.len == 0 or cfg.region.len > 64 or cfg.region.anyIt(it notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_'}): return "region is letters, digits, - and _"
  if cfg.bucket.len < 3 or cfg.bucket.len > 63 or cfg.bucket.anyIt(it notin {'a' .. 'z', '0' .. '9', '-', '.'}): return "bucket is 3..63 lowercase letters, digits, - and ."
  if cfg.keyId.len == 0 or cfg.keyId.len > 128 or cfg.keyId.anyIt(it < '!' or it > '~'): return "access_key_id is 1..128 printable characters"
  if secret.len == 0 or secret.len > 256 or secret.anyIt(it < '!' or it > '~'): return "secret_access_key is 1..256 printable characters"
  ""

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

# ------------------------------------------------------------------ the settings

var secretCache: tuple[value: string, at: int64]
var secretLock: Lock
initLock(secretLock)

proc forgetStoreSecret*() =
  ## the settings were changed: the next check of a node's request reads them again
  withLock secretLock: secretCache = (value: "", at: 0'i64)


proc saveStore*(c: var RqClient; kek: KekProvider; cfg: StoreConfig; secret: string; now: int64): tuple[ok, retry: bool, error: string] =
  let put = c.putSecret(kek, platformTenant, secretName, secret, now)
  if not put.ok: return (false, put.retry, put.error)
  let meta = $(%*{"endpoint": cfg.endpoint, "region": cfg.region, "bucket": cfg.bucket, "key_id": cfg.keyId, "updated_at": now, "kind": cfg.kind, "nodes": cfg.nodes, "min_acks": cfg.minAcks, "transport": cfg.transport})
  discard c.execute(%*[["INSERT INTO vault_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", metaKey, meta]])
  forgetStoreSecret()
  (true, false, "")

proc loadConfig*(c: var RqClient): StoreConfig =
  let r = c.query(%*[["SELECT value FROM vault_meta WHERE key = ?", metaKey]])
  let v = r["results"][0]{"values"}
  if v == nil or v.len == 0: return
  try:
    let j = parseJson(v[0][0].getStr)
    result = StoreConfig(found: true, endpoint: j["endpoint"].getStr, region: j["region"].getStr, bucket: j["bucket"].getStr, keyId: j["key_id"].getStr,
                         kind: j{"kind"}.getStr, minAcks: j{"min_acks"}.getInt(1), transport: j{"transport"}.getStr)
    if j{"nodes"} != nil and j["nodes"].kind == JArray:
      for a in j["nodes"].elems: result.nodes.add a.getStr
  except CatchableError: result = StoreConfig()

proc forgetStore*(c: var RqClient): bool =
  discard c.execute(%*[["DELETE FROM step_secrets WHERE tenant_id = ? AND name = ?", platformTenant, secretName]])
  forgetStoreSecret()
  c.execute(%*[["DELETE FROM vault_meta WHERE key = ?", metaKey]])["results"][0]{"rows_affected"}.getInt > 0

proc loadStore*(c: var RqClient): Store =
  ## the settings and the secret, ready to sign with
  result.cfg = c.loadConfig()
  if not result.cfg.found:
    result.error = "not_configured"
    return
  let vk = vaultKek()
  if not vk.ready:
    result.error = "secrets_unavailable"
    result.retry = true
    return
  let got = c.getSecrets(vk.kek, platformTenant, @[secretName])
  if not got.ok:
    result.error = if got.retry: "secrets_unavailable" else: "unreadable"
    result.retry = got.retry
    return
  result.secret = got.values[0][1]
  result.ok = true

proc storeSecret*(c: var RqClient; now: int64): string =
  ## the secret that the requests to the HTTP nodes are signed with, "" when the store is not of that kind (or is not ready). Kept for half a minute: every request of a node
  ## to the core's check asks it, and the settings change rarely (core/storeauth.nim)
  withLock secretLock:
    if secretCache.at > 0 and now - secretCache.at < 30: return secretCache.value
  let st = c.loadStore()
  let v = if st.ok and st.cfg.kind == "dav": st.secret else: ""
  withLock secretLock: secretCache = (value: v, at: now)
  v

var missedHook*: MissedProc          ## set by the core at start: what a store node missed goes into the repair queue (core/storerepair.nim)

proc backend*(s: Store): ObjectBackend =
  ## the store as the core talks to it; the one place that says which backend it is
  if s.cfg.kind == "dav":
    return newHttpMirror(s.cfg.nodes.mapIt(newHttpNode(it, s.secret)), s.cfg.minAcks, missedHook)
  if s.cfg.kind == "nodes":
    let certs = getEnv("CINIM_CERTS", getCurrentDir() / "tests" / "certs")
    var nodes: seq[ZNode]
    let plain = s.cfg.transport == "plain"
    for a in s.cfg.nodes:
      var n = if plain: newNode(a, "", s.secret, (publicKey: "", secretKey: "")) else: newNode(a, loadPublicKey(certs, "store"), s.secret, loadKeypair(certs, "client"))
      n.plain = plain
      nodes.add n
    return newMirror(nodes, s.cfg.minAcks, missedHook)
  S3Backend(endpoint: s.cfg.endpoint, region: s.cfg.region, bucket: s.cfg.bucket, keyId: s.cfg.keyId, secret: s.secret)

# ------------------------------------------------------------------ the rows

proc recordArtifact*(c: var RqClient; id, tenant, runId: string; step: int; path, key: string; size: int64; sha256, state, uploadId: string; now: int64) =
  ## a path is one artifact of a run: a retry of the step puts it again
  discard c.execute(%*[["INSERT INTO artifacts (id, tenant_id, run_id, step_ordinal, path, s3_key, size, sha256, state, created_at, upload_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) " &
    "ON CONFLICT(run_id, path) DO UPDATE SET step_ordinal = excluded.step_ordinal, size = excluded.size, sha256 = excluded.sha256, state = excluded.state, " &
    "created_at = excluded.created_at, upload_id = excluded.upload_id",
    id, tenant, runId, step, path, key, size, sha256, state, now, uploadId]])

proc uploadingRow*(c: var RqClient; runId, path: string): tuple[found: bool, key, uploadId: string, size: int64] =
  let r = c.query(%*[["SELECT s3_key, upload_id, size FROM artifacts WHERE run_id = ? AND path = ? AND state = 'uploading'", runId, path]])
  let v = r["results"][0]{"values"}
  if v != nil and v.len > 0: (true, v[0][0].getStr, v[0][1].getStr, v[0][2].getBiggestInt) else: (false, "", "", 0'i64)

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

proc storedArtifact*(c: var RqClient; runId, path: string): tuple[found: bool, key: string, size: int64, sha256: string] =
  let r = c.query(%*[["SELECT s3_key, size, sha256 FROM artifacts WHERE run_id = ? AND path = ? AND state = 'stored'", runId, path]])
  let v = r["results"][0]{"values"}
  if v != nil and v.len > 0: (true, v[0][0].getStr, v[0][1].getBiggestInt, v[0][2].getStr) else: (false, "", 0'i64, "")

proc storedUnder*(c: var RqClient; runId, prefix: string): seq[tuple[path, key: string; size: int64; sha256: string]] =
  ## the stored artifacts of a run whose path is `prefix` or lies under `prefix/`
  let r = c.query(%*[["SELECT path, s3_key, size, sha256 FROM artifacts WHERE run_id = ? AND state = 'stored' AND (path = ? OR substr(path, 1, ?) = ?) ORDER BY path",
                      runId, prefix, prefix.len + 1, prefix & "/"]])
  let v = r["results"][0]{"values"}
  if v != nil:
    for row in v: result.add (row[0].getStr, row[1].getStr, row[2].getBiggestInt, row[3].getStr)
