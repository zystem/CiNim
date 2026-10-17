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
import checksums/sha2
import ../common/[rqlite, storagebackend, httpsrv, storagetoken]
import schema, seal, registry, repair, replicas, storeauth, httpstore

type
  BackendMaker* = proc (l: Loaded; onMissed: MissedProc): ObjectBackend {.gcsafe, nimcall.}

  Reply* = object
    code*: int
    body*: string
    headers*: seq[string]

  ServiceConfig* = object
    rqliteUrl*: string
    shardSecrets*: Table[string, string]     ## shard -> the secret its calls are signed with
    adminToken*: string
    key*: seq[byte]                          ## the key the stores' secrets are sealed under
    replicaId*: string                       ## who holds the lease of the repair pass
    makeBackend*: BackendMaker               ## nil: `registry.backend`; the tests put their own
    repairEvery*, checkEvery*: int           ## seconds between the repair passes and between the checks of a slice of the inventory (0: 60 and 600)

const
  maxKeyLen = 1024
  defaultName = "_default"
  maxPartsInComplete = maxParts

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

func sha256Hex(s: string): string =
  for c in secureHash(Sha_256, s): result.add toHex(ord(c), 2).toLowerAscii

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

proc objectCall(c: var RqClient; shard, storeArg, key, meth: string; q: Table[string, string]; raw, body: string; now: int64): Reply =
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
    if "upload" in q:
      var n = 0
      try: n = parseInt(q.getOrDefault("part"))
      except ValueError: discard
      if n < 1 or n > maxParts: return problem(400, "invalid_part", "part is 1.." & $maxParts)
      let r = be.uploadPart(full, q["upload"], n, body)
      if not r.res.ok: return outcomeReply(r.res)
      return jsonReply(200, %*{"etag": r.etag})
    let given = raw.headerOf("x-content-sha256").toLowerAscii
    if given.len > 0 and given != sha256Hex(body): return problem(400, "sha256_mismatch", "the body is not the one X-Content-SHA256 names")
    if body.len > partSize: return problem(413, "too_large", "an object in one call is at most " & $partSize & " bytes; use a multipart upload")
    let r = be.putObject(full, body)
    if not r.ok: return outcomeReply(r)
    c.recordObject(l.name, full, body.len, now)
    return jsonReply(200, %*{"size": body.len})
  of "POST":
    if "uploads" in q:
      let r = be.createMultipart(full)
      if not r.res.ok: return outcomeReply(r.res)
      return jsonReply(200, %*{"upload_id": r.uploadId})
    if "upload" in q:
      var parts: seq[(int, string)]
      try:
        let j = parseJson(body)
        if j.kind != JObject or j{"parts"} == nil or j["parts"].kind != JArray or j["parts"].len == 0 or j["parts"].len > maxPartsInComplete: return problem(400, "invalid_request", "the body is {\"parts\": [[1, \"etag\"], ...]}")
        for p in j["parts"].elems:
          if p.kind != JArray or p.len != 2 or p[0].kind != JInt or p[1].kind != JString: return problem(400, "invalid_request", "a part is [number, \"etag\"]")
          parts.add (p[0].getInt, p[1].getStr)
      except JsonParsingError: return problem(400, "invalid_request", "the body is not JSON")
      let r = be.completeMultipart(full, q["upload"], parts)
      if not r.ok: return outcomeReply(r)
      let sz = be.objectSize(full)
      c.recordObject(l.name, full, (if sz.res.ok: sz.size else: -1'i64), now)       # -1: not known; the check only looks that the object is there
      return jsonReply(200, %*{"size": (if sz.res.ok: sz.size else: -1'i64)})
    return problem(400, "invalid_request", "POST takes ?uploads or ?upload={id}")
  of "GET":
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
    if a < 0 or b < a or b - a + 1 > 16 * 1024 * 1024: return problem(400, "invalid_range", "a read is 1 byte to 16 MiB")
    let r = be.readRange(full, a, b - a + 1)
    if not r.res.ok: return outcomeReply(r.res)
    return Reply(code: 206, body: r.data, headers: @["Content-Type: application/octet-stream"])
  of "DELETE":
    if "upload" in q:
      let r = be.abortMultipart(full, q["upload"])
      return (if r.ok: jsonReply(200, %*{"aborted": true}) else: outcomeReply(r))
    let r = be.deleteObject(full)
    if not r.ok and r.error != "no such object": return outcomeReply(r)
    c.forgetObject(l.name, full)
    return jsonReply(200, %*{"deleted": true})
  else:
    return problem(405, "method_not_allowed", "PUT, GET, POST or DELETE")

# ------------------------------------------------------------------ the operator's calls

proc admin(c: var RqClient; meth, rest, rawQuery, body: string; now: int64): Reply =
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
  try: j = parseJson(body)
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

proc dispatch*(meth, uri, raw, body: string; now: int64): Reply =
  ## one request, answered; `uri` is the request target (path and query), `raw` the whole request (the headers are read from it)
  let qpos = uri.find('?')
  let path = decodeUrl(if qpos >= 0: uri[0 ..< qpos] else: uri, decodePlus = false)
  let rawQuery = if qpos >= 0: uri[qpos + 1 .. ^1] else: ""
  let target = path & (if qpos >= 0: "?" & rawQuery else: "")
  if path == "/healthz": return jsonReply(200, %*{"status": "ok"})
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
      if path.startsWith("/v1/admin/stores"): return c.admin(meth, path["/v1/admin/stores".len .. ^1].strip(chars = {'/'}), rawQuery, body, now)
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
      return c.objectCall(shard, store, key, meth, parseQuery(rawQuery), raw, body, now)
    return problem(404, "not_found", "no such route")
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
            let rep = c.repairPass(e.name, mir, now)
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

proc onRequest() {.gcsafe, nimcall, raises: [].} =
  {.cast(gcsafe).}:
    try:
      let r = dispatch(getMethod(), getUri(), getRequest(), getBody(), getTime().toUnix())
      let code = HttpCode(r.code)
      if r.headers.len > 0: reply(code, r.body, r.headers) else: reply(code, r.body)
    except Exception as e:
      try: reply(Http500, "{\"error\":\"internal\",\"detail\":" & $(%e.msg) & "}", ["Content-Type: application/json"])
      except Exception: discard

proc startServer*(port: int; threads = 16): HttpServer =
  ## the server of the module; a body of an object is at most 8 MiB, and `Compact` mode wants it in the receive buffer (docs/storage-module.md, phase 0)
  result = newService(onRequest)
  result.bufferlength = 10 * 1024 * 1024
  result.sockettimeoutms = 60000
  discard result.start(port, uint(threads))
