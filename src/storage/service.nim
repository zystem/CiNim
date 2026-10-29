## The storage module as a service (docs/storage-module.md, D-60): the HTTP API the core talks to, the operator's admin API, and the background pass that keeps the nodes of a mirror alike.
##
## The core's calls (`Authorization: Bearer v1.<expires>.<mac>` and `X-Cinim-Shard`, made as in storage/storeauth.nim `signTarget` under the secret of that shard; two minutes):
##   GET    /v1/stores                                           the stores and the default one, no secrets
##   PUT    /v1/stores/{store}/objects/{key}                     an object in one call (up to 8 MiB); `X-Content-SHA256` is checked when given
##   GET    /v1/stores/{store}/objects/{key}  `Range: bytes=a-b`  a range (206); `?stat` answers {"size": n}
##   DELETE /v1/stores/{store}/objects/{key}
##   POST   /v1/stores/{store}/objects/{key}?uploads              a multipart upload: {"upload_id"}
##   PUT    /v1/stores/{store}/objects/{key}?upload={id}&part={n}   a part: {"etag"}
##   POST   /v1/stores/{store}/objects/{key}?upload={id}          complete, the body is {"parts": [[1, "etag"], ...]}
##   DELETE /v1/stores/{store}/objects/{key}?upload={id}          abort
## `{store}` is a name, or `_default` for the default store. The shard is put in front of the key in the store (`<shard>/<key>`), because the names of tenants repeat between shards; the token
## is made for the shard it names, so a shard cannot ask for the objects of another. The operator's calls (`Authorization: Bearer <admin token>`, plain): /v1/admin/stores... (see `admin`).
## The nodes of a mirror ask `GET /v1/internal/node-auth?node=<id>` (Caddy `forward_auth`) before they let a request in.
##
## `dispatch` is the whole of it without a socket, so that the tests call it directly; `serveStorage` puts it behind GuildenStern.
import std/[json, strutils, uri, times, tables, locks, os, atomics, sequtils]
import ../common/[rqlite, storagebackend, httpsrv, storagetoken, dbready]
import schema, seal, registry, repair, replicas, storeauth, httpstore, sha

type
  BackendMaker* = proc (l: Loaded; onMissed: MissedProc): ObjectBackend {.gcsafe, nimcall.}

  Reply* = object
    code*: int
    body*: string
    headers*: seq[string]
    stream*: proc (sink: PieceSink): Outcome {.closure.}   ## a body that is read from the store and sent as it comes (a read of a range), instead of `body`; the server runs it

  ServiceConfig* = object
    rqliteUrl*: string
    shardSecrets*: Table[string, string]     ## shard -> the secret its calls are signed with
    adminToken*: string
    key*: seq[byte]                          ## the key the stores' secrets are sealed under
    replicaId*: string                       ## who holds the lease of the repair pass
    makeBackend*: BackendMaker               ## nil: `registry.backend`; the tests put their own
    repairEvery*, checkEvery*: int           ## seconds between the repair passes and between the checks of a slice of the inventory (0: 60 and 600)
    repairRetry*: int                        ## seconds of the first pause after a repair that failed, doubling with each failure (0: 30)

const
  maxKeyLen = 1024
  defaultName = "_default"
  maxPartsInComplete = maxParts
  maxReadBytes = 256 * 1024 * 1024         ## one read; it is streamed, so the limit is a guard against a mistake and not a size in memory

var cfg*: ServiceConfig                      ## set once before the server starts; the threads only read it
var secretCache: tuple[values: seq[string], at: int64]
var secretLock: Lock
initLock(secretLock)
var tryingSecret: tuple[value: string, until: int64]       ## the token of a store that is being tried (the nodes ask for it before the store is kept)

func jsonReply(code: int; body: JsonNode; extra: seq[string] = @[]): Reply =
  Reply(code: code, body: $body, headers: @["Content-Type: application/json"] & extra)

func problem(code: int; error, detail: string; extra: seq[string] = @[]): Reply =
  jsonReply(code, %*{"error": error, "detail": detail}, extra)

func outcomeReply(o: Outcome): Reply =
  if o.retry: problem(503, "unavailable", o.error, @["Retry-After: 5"])
  elif o.error == "no such object": problem(404, "no_such_object", o.error)
  else: problem(502, "store_error", o.error)

func equalConstTime(a, b: string): bool =
  var diff = a.len xor b.len
  for i in 0 ..< min(a.len, b.len): diff = diff or (ord(a[i]) xor ord(b[i]))
  diff == 0

func bearer(raw: string): string =
  let auth = raw.headerOf("authorization")
  if auth.len > 7 and auth[0 ..< 7].toLowerAscii == "bearer ": auth[7 .. ^1].strip else: ""

func parseQuery(q: string): Table[string, string] =
  for pair in q.split('&'):
    if pair.len == 0: continue
    let eq = pair.find('=')
    if eq < 0: result[decodeUrl(pair, decodePlus = false)] = ""
    else: result[decodeUrl(pair[0 ..< eq], decodePlus = false)] = decodeUrl(pair[eq + 1 .. ^1], decodePlus = false)

func validObjectKey(key: string): bool =
  if key.len == 0 or key.len > maxKeyLen or key[0] == '/' or key[^1] == '/': return false
  for ch in key:
    if ch < ' ' or ch == '\x7f' or ch == '\\': return false
  for part in key.split('/'):
    if part.len == 0 or part == "." or part == "..": return false
  true

func validShard(s: string): bool = s.len in 1 .. 16 and s.allIt(it in {'0' .. '9'})

proc maker(): BackendMaker =
  if cfg.makeBackend != nil: cfg.makeBackend else: (proc (l: Loaded; onMissed: MissedProc): ObjectBackend {.gcsafe, nimcall.} = l.backend(onMissed))

proc nodeSecrets(c: var RqClient; now: int64): seq[string] =
  ## the tokens of the `dav` stores, kept for half a minute: every request of a node asks for them, and the stores change rarely
  withLock secretLock:
    if secretCache.at > 0 and now - secretCache.at < 30: return secretCache.values
  let found = c.davSecrets(cfg.key)
  withLock secretLock: secretCache = (values: found, at: now)
  found

proc nodeSecretsNow(c: var RqClient; now: int64): seq[string] =
  result = c.nodeSecrets(now)
  withLock secretLock:
    if tryingSecret.value.len > 0 and tryingSecret.until >= now: result.add tryingSecret.value

proc forgetNodeSecrets() =
  withLock secretLock: secretCache = (values: @[], at: 0'i64)

proc missedHook(url, store: string): MissedProc =
  ## what a node of a mirror missed goes into the repair queue of the store
  result = proc (key, node, op: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      try:
        var c = newRq(url)
        c.noteMissed(store, key, node, op, getTime().toUnix())
      except CatchableError: discard       # the check of the inventory finds it later

# ------------------------------------------------------------------ the core's calls

const maxSmallBody = 1024 * 1024        ## a body that is read whole (a JSON of the admin API, the list of parts of a complete)

proc readSmall(src: BodySource; len: int64): tuple[ok: bool, data: string] =
  ## the body of a request that is not an object: read to the end, at most `maxSmallBody`
  if len > maxSmallBody:
    discard src(proc (chunk: string): bool = false)       # read and dropped, so that the sender gets the answer
    return (false, "")
  collect(src, len)

type Digest = ref object
  h: Sha256
  n: int64

proc hashing(src: BodySource; d: Digest): BodySource =
  ## `src`, with the digest of what passes made as it goes
  result = proc (sink: proc (chunk: string): bool {.closure.}): bool {.closure.} =
    src(proc (chunk: string): bool =
      d.h.update chunk
      d.n += chunk.len
      sink(chunk))

proc objectCall(c: var RqClient; shard, storeArg, key, meth: string; q: Table[string, string]; raw: string; src: BodySource; bodyLen: int64; now: int64): Reply =
  let name = if storeArg == defaultName: "" else: storeArg
  let l = c.loadStore(cfg.key, name)
  if not l.ok:
    return case l.error
      of "not_configured": problem(409, "not_configured", "the module has no store yet")
      of "no_such_store": problem(404, "no_such_store", "no such store: " & storeArg)
      else: problem(500, "unreadable", "the settings of the store could not be read (the seal key is not the one they were sealed with)")
  if not validObjectKey(key): return problem(400, "invalid_key", "a key is relative, with no empty, . or .. parts, at most " & $maxKeyLen & " characters")
  let full = shard & "/" & key
  let be = maker()(l, if l.cfg.isMirror: missedHook(cfg.rqliteUrl, l.name) else: nil)
  case meth
  of "PUT":
    # the body is a stream (docs/storage-module.md, "The streaming PUT"): it is passed on to the store as it comes and never held whole. The digest is told before the bytes, so that a node
    # can check it as it writes; the module makes it too, and a body that is not the one named is taken back
    let given = raw.headerOf("x-content-sha256").toLowerAscii
    if given.len != 64 or not given.allCharsInSet({'0' .. '9', 'a' .. 'f'}): return problem(400, "sha256_required", "X-Content-SHA256 is the hex digest of the body, sent with the request")
    if bodyLen > partSize: return problem(413, "too_large", "an object in one call, or a part, is at most " & $partSize & " bytes; use a multipart upload")
    if bodyLen <= 0: return problem(400, "empty_body", "an object is at least one byte")
    let dg = Digest(h: initSha256())
    let body = src.hashing(dg)
    if "upload" in q:
      var n = 0
      try: n = parseInt(q.getOrDefault("part"))
      except ValueError: discard
      if n < 1 or n > maxParts: return problem(400, "invalid_part", "part is 1.." & $maxParts)
      let r = be.uploadPartStream(full, q["upload"], n, bodyLen, given, body)
      if not r.res.ok: return outcomeReply(r.res)
      if dg.n != bodyLen or dg.h.hexDigest() != given: return problem(400, "sha256_mismatch", "the body is not the one X-Content-SHA256 names")
      return jsonReply(200, %*{"etag": r.etag})
    let r = be.putStream(full, bodyLen, given, body)
    if not r.ok: return outcomeReply(r)
    if dg.n != bodyLen or dg.h.hexDigest() != given:
      discard be.deleteObject(full)                              # what a store that does not check what it is given has kept
      return problem(400, "sha256_mismatch", "the body is not the one X-Content-SHA256 names")
    c.recordObject(l.name, full, bodyLen, now)
    return jsonReply(200, %*{"size": bodyLen})
  of "POST":
    if "uploads" in q:
      let r = be.createMultipart(full)
      if not r.res.ok: return outcomeReply(r.res)
      return jsonReply(200, %*{"upload_id": r.uploadId})
    if "upload" in q:
      var parts: seq[(int, string)]
      let small = readSmall(src, bodyLen)
      if not small.ok: return problem(400, "invalid_request", "the body is a list of parts, at most 1 MiB")
      try:
        let j = parseJson(small.data)
        if j.kind != JObject or j{"parts"} == nil or j["parts"].kind != JArray or j["parts"].len == 0 or j["parts"].len > maxPartsInComplete: return problem(400, "invalid_request", "the body is {\"parts\": [[1, \"etag\"], ...]}")
        for p in j["parts"].elems:
          if p.kind != JArray or p.len != 2 or p[0].kind != JInt or p[1].kind != JString: return problem(400, "invalid_request", "a part is [number, \"etag\"]")
          parts.add (p[0].getInt, p[1].getStr)
      except JsonParsingError: return problem(400, "invalid_request", "the body is not JSON")
      let r = be.completeMultipart(full, q["upload"], parts)
      if not r.ok: return outcomeReply(r)
      let sz = be.objectSize(full)
      c.recordObject(l.name, full, (if sz.res.ok: sz.size else: -1'i64), now)       # -1: not known; the check only looks that the object is there
      c.forgetParts(l.name, full, q["upload"])
      return jsonReply(200, %*{"size": (if sz.res.ok: sz.size else: -1'i64)})
    return problem(400, "invalid_request", "POST takes ?uploads or ?upload={id}")
  of "GET":
    if "parts" in q and "upload" in q:
      # D-61: what the module received from a shim for this upload, part by part (the digest it made of the bytes, and their number); the core compares it with what the shim reported
      var items = newJArray()
      for p in c.partsOf(l.name, full, q["upload"]): items.add %*{"part": p.part, "sha256": p.sha256, "size": p.size}
      return jsonReply(200, %*{"parts": items})
    if "stat" in q:
      let r = be.objectSize(full)
      if not r.res.ok: return outcomeReply(r.res)
      return jsonReply(200, %*{"size": r.size})
    let range = raw.headerOf("range")
    if not range.startsWith("bytes="): return problem(400, "range_required", "a read names a range: Range: bytes=a-b")
    let ends = range[6 .. ^1].split('-')
    var a, b: int64
    try:
      if ends.len != 2: raise newException(ValueError, "range")
      a = parseBiggestInt(ends[0])
      b = parseBiggestInt(ends[1])
    except ValueError: return problem(400, "invalid_range", "Range: bytes=a-b, with both ends")
    if a < 0 or b < a or b - a + 1 > maxReadBytes: return problem(400, "invalid_range", "a read is 1 byte to " & $(maxReadBytes div (1024 * 1024)) & " MiB")
    return Reply(code: 206, headers: @["Content-Type: application/octet-stream"], stream: proc (sink: PieceSink): Outcome = be.readStream(full, a, b - a + 1, sink))
  of "DELETE":
    if "upload" in q:
      let r = be.abortMultipart(full, q["upload"])
      c.forgetParts(l.name, full, q["upload"])
      return (if r.ok: jsonReply(200, %*{"aborted": true}) else: outcomeReply(r))
    let r = be.deleteObject(full)
    if not r.ok and r.error != "no such object": return outcomeReply(r)
    c.forgetObject(l.name, full)
    return jsonReply(200, %*{"deleted": true})
  else:
    return problem(405, "method_not_allowed", "PUT, GET, POST or DELETE")

# ------------------------------------------------------------------ the operator's calls

proc admin(c: var RqClient; meth, rest, rawQuery: string; src: BodySource; bodyLen: int64; now: int64): Reply =
  ## /v1/admin/stores                       GET  the stores with the number of objects and the repair queue
  ## /v1/admin/stores/{name}                PUT (or POST)  {kind: "s3" | "dav", endpoint, region, bucket, access_key_id, secret_access_key | nodes, token, min_acks, default}: tried first, then kept
  ##                                        DELETE  [?force=1]
  ## /v1/admin/stores/{name}:check          POST the round trip again;   :default  POST makes it the default
  let q = parseQuery(rawQuery)
  var nameS = rest
  var action = ""
  let colon = nameS.find(':')
  if colon >= 0:
    action = nameS[colon .. ^1]
    nameS = nameS[0 ..< colon]
  if nameS.len == 0:
    if meth != "GET" or action.len > 0: return problem(405, "method_not_allowed", "GET")
    var items = newJArray()
    for e in c.listStores():
      var j = %*{"name": e.name, "kind": e.cfg.kind, "default": e.isDefault, "endpoint": e.cfg.endpoint, "region": e.cfg.region, "bucket": e.cfg.bucket, "access_key_id": e.cfg.keyId,
                 "nodes": e.cfg.nodes, "min_acks": (if e.cfg.isMirror and e.cfg.minAcks <= 0: e.cfg.nodes.len else: e.cfg.minAcks), "objects": c.objectCount(e.name)}
      if e.cfg.isMirror: j["repair_pending"] = %c.pendingRepairs(e.name)
      items.add j
    return jsonReply(200, %*{"stores": items})
  if action == ":check":
    if meth != "POST": return problem(405, "method_not_allowed", "POST")
    let l = c.loadStore(cfg.key, nameS)
    if not l.ok: return problem(if l.error == "no_such_store": 404 else: 409, l.error, "the store is not ready: " & l.error)
    let bad = maker()(l, nil).roundTrip()
    return (if bad.len > 0: problem(502, "storage_unreachable", bad) else: jsonReply(200, %*{"ok": true, "name": nameS, "kind": l.cfg.kind}))
  if action == ":default":
    if meth != "POST": return problem(405, "method_not_allowed", "POST")
    if not c.setDefaultStore(nameS): return problem(404, "no_such_store", "no such store: " & nameS)
    return jsonReply(200, %*{"name": nameS, "default": true})
  if action.len > 0: return problem(404, "not_found", "no such action")
  if meth == "DELETE":
    let why = c.forgetStore(nameS, force = "force" in q)
    if why.len > 0: return problem(if why == "no such store": 404 else: 409, if why == "no such store": "no_such_store" else: "store_in_use", why)
    forgetNodeSecrets()
    return jsonReply(200, %*{"deleted": true, "name": nameS})
  # POST does what PUT does, for the registration scripts of the chart, which have only busybox `wget` (it cannot PUT)
  if meth notin ["PUT", "POST"]: return problem(405, "method_not_allowed", "GET, PUT, DELETE, or POST :check / :default")
  var j: JsonNode
  let small = readSmall(src, bodyLen)
  try: j = (if small.ok: parseJson(small.data) else: nil)
  except JsonParsingError: j = nil
  if j == nil or j.kind != JObject: return problem(400, "invalid_request", "the body is {kind, endpoint, region, bucket, access_key_id, secret_access_key} or {kind: dav, nodes, token, min_acks}")
  var sc = StoreConfig(kind: j{"kind"}.getStr("s3"), endpoint: j{"endpoint"}.getStr, region: j{"region"}.getStr("garage"), bucket: j{"bucket"}.getStr, keyId: j{"access_key_id"}.getStr)
  var secret = j{"secret_access_key"}.getStr
  if sc.kind == "dav":
    sc.minAcks = j{"min_acks"}.getInt(0)
    if j{"nodes"} != nil and j["nodes"].kind == JArray:
      for a in j["nodes"].elems: sc.nodes.add a.getStr
    secret = j{"token"}.getStr
  if not validStoreName(nameS): return problem(400, "invalid_request", "a store's name is lowercase letters, digits and -, starting with a letter, at most 32")
  let why = checkConfig(sc, secret)
  if why.len > 0: return problem(400, "invalid_request", why)
  # the settings are tried before they are kept: a store that does not take an object is not one to write down
  if sc.kind == "dav": withLock secretLock: tryingSecret = (secret, now + 60)
  let bad = maker()(Loaded(ok: true, name: nameS, cfg: sc, secret: secret), nil).roundTrip()
  withLock secretLock: tryingSecret = ("", 0'i64)
  if bad.len > 0: return problem(400, "storage_unreachable", bad)
  let failed = c.saveStore(cfg.key, nameS, sc, secret, j{"default"}.getBool(false), now)
  if failed.len > 0: return problem(400, "invalid_request", failed)
  forgetNodeSecrets()
  return jsonReply(200, %*{"name": nameS, "checked": true})

# ------------------------------------------------------------------ the dispatch

proc dispatch*(meth, uri, raw: string; src: BodySource; bodyLen: int64; now: int64): Reply =
  ## one request, answered; `uri` is the request target (path and query), `raw` the whole request (the headers are read from it), `src` the body, `bodyLen` its length. A route that does
  ## not read the body leaves it to the caller, which reads it to the end before it answers (onRequest).
  let qpos = uri.find('?')
  let path = decodeUrl(if qpos >= 0: uri[0 ..< qpos] else: uri, decodePlus = false)
  let rawQuery = if qpos >= 0: uri[qpos + 1 .. ^1] else: ""
  let target = path & (if qpos >= 0: "?" & rawQuery else: "")
  if path == "/healthz": return jsonReply(200, %*{"status": "ok"})
  if path == "/readyz":
    # ready: the database that holds the stores, the inventory and the tokens answers; the module is alive when it does not, and is left out of the Service until it does
    let db = readyCached(cfg.rqliteUrl, 2000, epochTime())
    return if db.ok: jsonReply(200, %*{"status": "ready", "checks": {"database": "ok"}})
           else: jsonReply(503, %*{"status": "not_ready", "checks": {"database": db.why}})
  var c = newRq(cfg.rqliteUrl)
  try:
    if path == "/v1/internal/node-auth":
      var ok = false
      for sec in c.nodeSecretsNow(now):
        if storeAuthOk(raw, uri, sec, now): ok = true
      # a body that is not empty: GuildenStern follows an empty one with a stray CRLF, which Caddy logs for every request
      return (if ok: Reply(code: 200, body: "ok") else: Reply(code: 401, body: "no"))
    if path.startsWith("/v1/admin/"):
      if cfg.adminToken.len < 16 or not equalConstTime(bearer(raw), cfg.adminToken): return problem(401, "unauthorized", "the admin token is wrong or none")
      if path.startsWith("/v1/admin/stores"): return c.admin(meth, path["/v1/admin/stores".len .. ^1].strip(chars = {'/'}), rawQuery, src, bodyLen, now)
      return problem(404, "not_found", "no such route")
    if path == "/v1/stores" or path.startsWith("/v1/stores/"):
      let shard = raw.headerOf("x-cinim-shard")
      if not validShard(shard) or not cfg.shardSecrets.hasKey(shard) or not verifyTarget(cfg.shardSecrets[shard], shard, meth, target, bearer(raw), now):
        return problem(401, "unauthorized", "the token is wrong, expired, or not for this call")
      if path == "/v1/stores":
        if meth != "GET": return problem(405, "method_not_allowed", "GET")
        var items = newJArray()
        for e in c.listStores(): items.add %*{"name": e.name, "kind": e.cfg.kind, "default": e.isDefault}
        return jsonReply(200, %*{"stores": items, "default": c.defaultStoreName()})
      let rest = path["/v1/stores/".len .. ^1]
      let slash = rest.find('/')
      if slash < 1 or not rest[slash + 1 .. ^1].startsWith("objects/"): return problem(404, "not_found", "no such route")
      let store = rest[0 ..< slash]
      let key = rest[slash + 1 + "objects/".len .. ^1]
      return c.objectCall(shard, store, key, meth, parseQuery(rawQuery), raw, src, bodyLen, now)
    return problem(404, "not_found", "no such route")
  except RqError as e:
    return problem(503, "database_unavailable", e.msg, @["Retry-After: 5"])

proc materialized*(r: Reply): Reply =
  ## the answer with its stream read into `body` (the tests, which have no socket to send it to)
  if r.stream == nil: return r
  var data = ""
  let res = r.stream(proc (chunk: string): bool = (data.add chunk; true))
  if not res.ok and data.len == 0: return outcomeReply(res)
  Reply(code: r.code, body: data, headers: r.headers)

proc dispatch*(meth, uri, raw, body: string; now: int64): Reply =
  ## the same with a body that is in memory (the tests)
  materialized(dispatch(meth, uri, raw, bodyOf(body), int64(body.len), now))

# ------------------------------------------------------------------ the port for shims (D-61)

proc shimDispatch*(meth, uri, raw: string; src: BodySource; bodyLen: int64; now: int64): Reply =
  ## The calls of a step's shim, on a port and a thread pool of their own so that step code cannot take the threads the core's calls need. The shim holds a **grant** that the core made for
  ## one upload (to put its parts) or one object (to read it): a part is `PUT /s/{store}/{key}?upload={id}&part={n}` with `X-Content-SHA256`, a read is `GET /s/{store}/{key}` with a `Range`.
  ## The module checks the grant, streams the part to the store, makes the digest of what it received and keeps it (`storage_parts`); the core compares those digests with the ones the shim
  ## sent over its own channel before it completes the upload. Nothing else is open here: no listing, no delete, no complete.
  let qpos = uri.find('?')
  let path = decodeUrl(if qpos >= 0: uri[0 ..< qpos] else: uri, decodePlus = false)
  let rawQuery = if qpos >= 0: uri[qpos + 1 .. ^1] else: ""
  if path == "/healthz": return jsonReply(200, %*{"status": "ok"})
  if not path.startsWith("/s/"): return problem(404, "not_found", "no such route")
  let rest = path[3 .. ^1]
  let slash = rest.find('/')
  if slash < 1: return problem(404, "not_found", "no such route")
  let store = rest[0 ..< slash]
  let key = rest[slash + 1 .. ^1]
  let grant = bearer(raw)
  let shard = grantShard(grant)                    # the grant says which shard it is for; the secret of that shard checks it
  if not validShard(shard) or not cfg.shardSecrets.hasKey(shard) or store == defaultName or not validObjectKey(key):
    return problem(401, "unauthorized", "the grant is wrong, expired, or not for this call")
  let secret = cfg.shardSecrets[shard]
  let q = parseQuery(rawQuery)
  var c = newRq(cfg.rqliteUrl)
  try:
    case meth
    of "PUT":
      let upload = q.getOrDefault("upload")
      if not verifyGrant(secret, shard, store, key, upload, "w", grant, now): return problem(401, "unauthorized", "the grant is wrong, expired, or not for this call")
      var n = 0
      try: n = parseInt(q.getOrDefault("part"))
      except ValueError: discard
      if upload.len == 0 or n < 1 or n > maxParts: return problem(400, "invalid_part", "a part is PUT with ?upload={id}&part=1.." & $maxParts)
      let given = raw.headerOf("x-content-sha256").toLowerAscii
      if given.len != 64 or not given.allCharsInSet({'0' .. '9', 'a' .. 'f'}): return problem(400, "sha256_required", "X-Content-SHA256 is the hex digest of the part, sent with the request")
      if bodyLen <= 0: return problem(400, "empty_body", "a part is at least one byte")
      if bodyLen > partSize: return problem(413, "too_large", "a part is 1.." & $partSize & " bytes")
      let l = c.loadStore(cfg.key, store)
      if not l.ok: return problem(if l.error == "no_such_store": 404 else: 409, l.error, "the store is not ready: " & l.error)
      let be = maker()(l, nil)
      let full = shard & "/" & key
      let dg = Digest(h: initSha256())
      let r = be.uploadPartStream(full, upload, n, bodyLen, given, src.hashing(dg))
      if not r.res.ok: return outcomeReply(r.res)
      if dg.n != bodyLen or dg.h.hexDigest() != given: return problem(400, "sha256_mismatch", "the body is not the one X-Content-SHA256 names")
      c.recordPart(l.name, full, upload, n, given, bodyLen, now)
      return jsonReply(200, %*{"etag": r.etag})
    of "GET":
      if not verifyGrant(secret, shard, store, key, "", "r", grant, now): return problem(401, "unauthorized", "the grant is wrong, expired, or not for this call")
      let range = raw.headerOf("range")
      if not range.startsWith("bytes="): return problem(400, "range_required", "a read names a range: Range: bytes=a-b")
      let ends = range[6 .. ^1].split('-')
      var a, b: int64
      try:
        if ends.len != 2: raise newException(ValueError, "range")
        a = parseBiggestInt(ends[0])
        b = parseBiggestInt(ends[1])
      except ValueError: return problem(400, "invalid_range", "Range: bytes=a-b, with both ends")
      if a < 0 or b < a or b - a + 1 > maxReadBytes: return problem(400, "invalid_range", "a read is 1 byte to " & $(maxReadBytes div (1024 * 1024)) & " MiB")
      let l = c.loadStore(cfg.key, store)
      if not l.ok: return problem(if l.error == "no_such_store": 404 else: 409, l.error, "the store is not ready: " & l.error)
      let be = maker()(l, nil)
      let full = shard & "/" & key
      return Reply(code: 206, headers: @["Content-Type: application/octet-stream"], stream: proc (sink: PieceSink): Outcome = be.readStream(full, a, b - a + 1, sink))
    else:
      return problem(405, "method_not_allowed", "PUT or GET")
  except RqError as e:
    return problem(503, "database_unavailable", e.msg, @["Retry-After: 5"])

# ------------------------------------------------------------------ the background pass

var stopRepair*: Atomic[bool]
const
  defaultRepairSeconds = 60
  defaultCheckSeconds = 600

proc repairLoop*() {.thread.} =
  {.cast(gcsafe).}:
    var c = newRq(cfg.rqliteUrl)
    var lastCheck = 0.0
    var cursors = initTable[string, string]()
    while not stopRepair.load:
      try:
        let now = getTime().toUnix()
        if c.tryLease("repair", cfg.replicaId, now):
          let due = epochTime() - lastCheck >= float(if cfg.checkEvery > 0: cfg.checkEvery else: defaultCheckSeconds)
          if due: lastCheck = epochTime()
          for e in c.listStores():
            if not e.cfg.isMirror: continue
            let l = c.loadStore(cfg.key, e.name)
            if not l.ok: continue
            let mir = ReplicaBackend(maker()(l, nil))
            let rep = c.repairPass(e.name, mir, now, retryBase = (if cfg.repairRetry > 0: cfg.repairRetry else: defaultRetrySeconds))
            if rep.copied + rep.deleted + rep.dropped + rep.failed > 0:
              echo "storage: store ", e.name, " repair: ", rep.copied, " copied, ", rep.deleted, " deleted, ", rep.dropped, " dropped, ", rep.failed, " left for later"
            if due:
              let made = c.checkNodes(e.name, mir, cursors.mgetOrPut(e.name, ""), now)
              if made > 0: echo "storage: store ", e.name, " check: ", made, " objects are missing from a node or differ; queued for repair"
      except CatchableError as e: stderr.writeLine "storage: repair: " & e.msg
      for _ in 0 ..< (if cfg.repairEvery > 0: cfg.repairEvery else: defaultRepairSeconds) * 10:
        if stopRepair.load: break
        sleep 100

# ------------------------------------------------------------------ the server

type Router = proc (meth, uri, raw: string; src: BodySource; bodyLen: int64; now: int64): Reply {.nimcall, gcsafe.}

proc serve(route: Router) =
  ## the callback of a server: the headers first (the buffer is reused for the body), the body as a source, the answer after the whole body has been read
  let meth = getMethod()
  let uri = getUri()
  let raw = http.request[0 ..< http.requestlen]  # the headers (getRequest is for the Compact mode)
  var bodyLen = 0'i64
  try: bodyLen = parseBiggestInt(raw.headerOf("content-length"))
  except ValueError: discard
  var read = false
  let src: BodySource = proc (sink: proc (chunk: string): bool {.closure.}): bool {.closure.} =
    read = true
    var live = true
    for (state, chunk) in receiveStream():
      if state == Fail: return false
      if chunk.len > 0 and live: live = sink(chunk)
      if state == Complete: break
    true
  if bodyLen > 16 * 1024 * 1024:
    reply(Http413, "{\"error\":\"too_large\"}", ["Content-Type: application/json"])
    return
  let r = route(meth, uri, raw, src, bodyLen, getTime().toUnix())
  if bodyLen > 0 and not read: discard src(proc (chunk: string): bool = false)      # a route that did not want the body: read to the end and dropped, or the sender gets a reset
  let code = HttpCode(r.code)
  if r.stream != nil:
    # a read: the answer begins with the first piece, so that an error before it (no such object, the store away) is still an answer with a status; an error after it ends the connection
    var started = false
    let res = r.stream(proc (chunk: string): bool =
      if not started:
        started = replyStartChunked(code, r.headers)
        if not started: return false
      replyContinueChunked(chunk))
    if started:
      if res.ok: discard replyFinishChunked()
      else: closeSocket(CloseCalled, "a read failed after it began")
    else:
      let e = if res.ok: Reply(code: r.code, body: "", headers: r.headers) else: outcomeReply(res)
      reply(HttpCode(e.code), e.body, e.headers)
    return
  if r.headers.len > 0: reply(code, r.body, r.headers) else: reply(code, r.body)

proc guarded(route: Router) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    try: serve(route)
    except Exception as e:
      try: reply(Http500, "{\"error\":\"internal\",\"detail\":" & $(%e.msg) & "}", ["Content-Type: application/json"])
      except Exception: discard

proc coreRoute(meth, uri, raw: string; src: BodySource; bodyLen: int64; now: int64): Reply {.nimcall, gcsafe.} =
  {.cast(gcsafe).}: dispatch(meth, uri, raw, src, bodyLen, now)

proc shimRoute(meth, uri, raw: string; src: BodySource; bodyLen: int64; now: int64): Reply {.nimcall, gcsafe.} =
  {.cast(gcsafe).}: shimDispatch(meth, uri, raw, src, bodyLen, now)

proc onRequest() {.gcsafe, nimcall, raises: [].} = guarded(coreRoute)
proc onShimRequest() {.gcsafe, nimcall, raises: [].} = guarded(shimRoute)

proc startServer*(port: int; threads = 16): HttpServer =
  ## the server of the module. The body is read piece by piece (`Streaming`), so a thread's buffer is small (64 KiB) whatever the size of a block (docs/storage-module.md, "The streaming PUT")
  result = newService(onRequest, streaming = true)
  result.bufferlength = 64 * 1024
  result.sockettimeoutms = 60000
  discard result.start(port, uint(threads))

proc startShimServer*(port: int; threads = 8): HttpServer =
  ## the port for shims (D-61): a pool of its own, so that a step that holds connections open cannot take the threads of the core's calls
  result = newService(onShimRequest, streaming = true)
  result.bufferlength = 64 * 1024
  result.sockettimeoutms = 30000
  discard result.start(port, uint(threads))
