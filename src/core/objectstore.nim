## The object store of the shard (DAT-003, D-46, Garage or any S3-compatible store): where the artifacts of runs live.
##
## The settings (endpoint, region, bucket, the access key's id) are in the database; the secret of the access key is sealed there like a step secret (D-45,
## core/secretvault.nim) under the tenant `_platform`, so that a restored database brings the store back and nothing is kept in Kubernetes Secrets. The core
## signs short-lived URLs (common/sigv4.nim); the shim of a step, which has no key at all, puts and gets objects through them. The objects of a run are
## `<tenant>/<run>/<path>`; a step may only ask for URLs of its own run, for what its own options declared (`artifacts = {upload = {...}, download = {...}}`).
import std/[json, strutils, times, httpclient, os, sequtils]
import ../common/[rqlite, sigv4]
import secretvault

const
  platformTenant* = "_platform"
  secretName = "OBJECTSTORE_SECRET_KEY"
  metaKey = "objectstore"
  maxFilesPerCall* = 1000
  maxObjectBytes* = 5'i64 * 1024 * 1024 * 1024     ## one PUT of S3 holds at most 5 GiB
  maxPathLen* = 512
  putExpires* = 900                                 ## seconds a URL to upload is good: the time to send the biggest file
  getExpires* = 300

type
  StoreConfig* = object
    found*: bool
    endpoint*, region*, bucket*, keyId*: string

  Store* = object
    ok*: bool
    cfg*: StoreConfig
    secret*: string
    error*: string               ## when not ok: not_configured, secrets_unavailable, unreadable
    retry*: bool

func checkConfig*(cfg: StoreConfig; secret: string): string =
  ## "" if these may be the settings of the store, else what is wrong
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

proc saveStore*(c: var RqClient; kek: KekProvider; cfg: StoreConfig; secret: string; now: int64): tuple[ok, retry: bool, error: string] =
  let put = c.putSecret(kek, platformTenant, secretName, secret, now)
  if not put.ok: return (false, put.retry, put.error)
  let meta = $(%*{"endpoint": cfg.endpoint, "region": cfg.region, "bucket": cfg.bucket, "key_id": cfg.keyId, "updated_at": now})
  discard c.execute(%*[["INSERT INTO vault_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", metaKey, meta]])
  (true, false, "")

proc loadConfig*(c: var RqClient): StoreConfig =
  let r = c.query(%*[["SELECT value FROM vault_meta WHERE key = ?", metaKey]])
  let v = r["results"][0]{"values"}
  if v == nil or v.len == 0: return
  try:
    let j = parseJson(v[0][0].getStr)
    StoreConfig(found: true, endpoint: j["endpoint"].getStr, region: j["region"].getStr, bucket: j["bucket"].getStr, keyId: j["key_id"].getStr)
  except CatchableError: StoreConfig()

proc forgetStore*(c: var RqClient): bool =
  discard c.execute(%*[["DELETE FROM step_secrets WHERE tenant_id = ? AND name = ?", platformTenant, secretName]])
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

proc url*(s: Store; httpMethod, key: string; expires: int; now = getTime().toUnix()): string =
  presignObject(httpMethod, s.cfg.endpoint, s.cfg.bucket, key, s.cfg.region, s.cfg.keyId, s.secret, now, expires)

# ------------------------------------------------------------------ talking to the store (core's own calls)

proc headSize*(s: Store; key: string): int64 =
  ## the size of an object, -1 if it is not there or the store does not answer
  let cl = newHttpClient(timeout = 10000)
  defer: cl.close()
  try:
    let r = cl.request(s.url("HEAD", key, 60), httpMethod = HttpHead)
    if r.code.int div 100 != 2: return -1
    result = try: parseBiggestInt(r.headers.getOrDefault("content-length")) except ValueError: -1
  except CatchableError: result = -1

proc removeObject*(s: Store; key: string): bool =
  let cl = newHttpClient(timeout = 10000)
  defer: cl.close()
  try: cl.request(s.url("DELETE", key, 60), httpMethod = HttpDelete).code.int div 100 == 2
  except CatchableError: false

proc roundTrip*(s: Store): string =
  ## "" if an object can be put, read back and deleted with these settings, else what failed; the check of `PUT /api/v1/storage` and `:check`
  let key = "_check/" & $getTime().toUnix() & "-" & $getCurrentProcessId()
  let body = "cinim object store check"
  let cl = newHttpClient(timeout = 10000)
  defer: cl.close()
  try:
    let put = cl.request(s.url("PUT", key, 60), httpMethod = HttpPut, body = body)
    if put.code.int div 100 != 2: return "put: the store answered " & $put.code & " " & put.body[0 ..< min(put.body.len, 200)]
    let got = cl.request(s.url("GET", key, 60), httpMethod = HttpGet)
    if got.code.int div 100 != 2 or got.body != body: return "get: the store answered " & $got.code
    if not s.removeObject(key): return "delete: the store refused"
  except CatchableError as e:
    return "the store did not answer: " & e.msg
  ""

# ------------------------------------------------------------------ the rows

proc recordUploading*(c: var RqClient; id, tenant, runId: string; step: int; path, key: string; size: int64; sha256: string; now: int64) =
  ## a path is one artifact of a run: a retry of the step puts it again
  discard c.execute(%*[["INSERT INTO artifacts (id, tenant_id, run_id, step_ordinal, path, s3_key, size, sha256, state, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'uploading', ?) " &
    "ON CONFLICT(run_id, path) DO UPDATE SET step_ordinal = excluded.step_ordinal, size = excluded.size, sha256 = excluded.sha256, state = 'uploading', created_at = excluded.created_at",
    id, tenant, runId, step, path, key, size, sha256, now]])

proc markStored*(c: var RqClient; runId, path: string): bool =
  c.execute(%*[["UPDATE artifacts SET state = 'stored' WHERE run_id = ? AND path = ? AND state = 'uploading'", runId, path]])["results"][0]{"rows_affected"}.getInt > 0

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
