## The core's side of the storage module (docs/storage-module.md, D-60): `RemoteBackend` is `ObjectBackend` over the module's HTTP API (storage/service.nim), and `moduleStores` is the list of
## the module's stores with the default one. The core knows nothing of what a store is made of: it holds the address of the module, the secret its calls are signed with, and its own shard.
## Every call carries `Authorization: Bearer v1.<expires>.<mac>` (common/storagetoken.nim: shard, method, path and query) and `X-Cinim-Shard`, and is good for two minutes.
## An error that may pass (the module is away, 503, a timeout) is `retry`; one that will not (401, 404, 409, 4xx) is final.
import std/[httpclient, json, strutils, times, locks, uri]
import checksums/sha2
import ../common/[storagebackend, storagetoken]

const
  callTimeoutMs = 120_000
  defaultStore* = "_default"          ## the name the module resolves to its default store
  listCacheSeconds = 5

type
  RemoteBackend* = ref object of ObjectBackend
    store*: string                    ## the name of the store, or "" for the module's default

  ModuleStore* = object
    name*, kind*: string
    isDefault*: bool

  ModuleStores* = object
    ok*: bool
    stores*: seq[ModuleStore]
    defaultName*: string
    error*: string                    ## not_configured, or what the module or the network said
    retry*: bool

var
  moduleUrl: string
  moduleSecret: string
  moduleShard: string
  listCache: tuple[value: ModuleStores, at: int64]
  listLock: Lock
initLock(listLock)

var directBase: string

proc configureStorage*(url, secret, shard: string; direct = "") =
  ## called once at start (or by a test); an empty `url` means no module is set up. `direct` is where the shims put their bytes (the module's port for shims, D-61), as the shims reach it
  ## from their own namespaces; empty: the bytes go through the core
  moduleUrl = url.strip(chars = {'/'})
  moduleSecret = secret
  moduleShard = shard
  directBase = direct.strip(chars = {'/'})
  withLock listLock: listCache = (ModuleStores(), 0'i64)

proc forgetStoreList*() =
  ## the next question about the stores goes to the module (a test, or after the operator changed them and wants to see it at once)
  withLock listLock: listCache = (ModuleStores(), 0'i64)

proc storageConfigured*(): bool = moduleUrl.len > 0 and moduleSecret.len > 0

proc directUrl*(): string = (if storageConfigured(): directBase else: "")
  ## "" when the shims send their bytes through the core

func encodeKey(p: string): string =
  ## a path for the request line: everything but the unreserved characters and `/` is `%XX`
  for c in p:
    if c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.', '~', '/'}: result.add c
    else:
      result.add '%'
      result.add "0123456789ABCDEF"[ord(c) shr 4]
      result.add "0123456789ABCDEF"[ord(c) and 15]

func shaHex(s: string): string =
  for c in secureHash(Sha_256, s): result.add toHex(ord(c), 2).toLowerAscii

type Answer = object
  code: int                           ## 0: there was no answer
  body: string
  error: string

proc call(meth: HttpMethod; uri: string; body = ""; extra: openArray[(string, string)] = []): Answer =
  ## `uri` is the request target as sent (path encoded, query as is)
  if not storageConfigured(): return Answer(error: "not_configured")
  let q = uri.find('?')
  let target = decodeUrl(if q >= 0: uri[0 ..< q] else: uri, decodePlus = false) & (if q >= 0: uri[q .. ^1] else: "")
  let verb = case meth
    of HttpGet: "GET"
    of HttpPut: "PUT"
    of HttpPost: "POST"
    of HttpDelete: "DELETE"
    else: $meth
  var h = newHttpHeaders({"Authorization": "Bearer " & signTarget(moduleSecret, moduleShard, verb, target, getTime().toUnix()), "X-Cinim-Shard": moduleShard})
  for (k, v) in extra: h[k] = v
  let client = newHttpClient(timeout = callTimeoutMs, headers = h)
  try:
    let r = client.request(moduleUrl & uri, httpMethod = meth, body = body)
    Answer(code: r.code.int, body: r.body)
  except CatchableError as e:
    Answer(error: e.msg)
  finally:
    client.close()

proc outcomeOf(a: Answer): Outcome =
  ## the seam's answer from the module's: 2xx is done; no answer, 5xx and 429 may pass; the rest will not
  if a.code in 200 .. 299: return done()
  if a.code == 0: return fail("the storage module did not answer: " & a.error, retry = a.error != "not_configured")
  var detail = ""
  try:
    let j = parseJson(a.body)
    detail = j{"error"}.getStr & (if j{"detail"}.getStr.len > 0: ": " & j{"detail"}.getStr else: "")
  except CatchableError: detail = a.body[0 ..< min(200, a.body.len)]
  if a.code == 404 and detail.startsWith("no_such_object"): return fail("no such object")
  if a.code == 404 and detail.startsWith("no_such_store"): return fail("no such store")
  fail("the storage module answered " & $a.code & " " & detail, retry = a.code >= 500 or a.code == 429)

proc objectUri(b: RemoteBackend; key: string; query = ""): string =
  "/v1/stores/" & (if b.store.len > 0: b.store else: defaultStore) & "/objects/" & encodeKey(key) & (if query.len > 0: "?" & query else: "")

method putObject*(b: RemoteBackend; key, data: string): Outcome =
  call(HttpPut, b.objectUri(key), data, [("X-Content-SHA256", shaHex(data))]).outcomeOf

method createMultipart*(b: RemoteBackend; key: string): tuple[res: Outcome, uploadId: string] =
  let a = call(HttpPost, b.objectUri(key, "uploads"))
  let o = a.outcomeOf
  if not o.ok: return (o, "")
  try: (done(), parseJson(a.body)["upload_id"].getStr)
  except CatchableError: (fail("the storage module's answer is not an upload id"), "")

method uploadPart*(b: RemoteBackend; key, uploadId: string; part: int; data: string): tuple[res: Outcome, etag: string] =
  let a = call(HttpPut, b.objectUri(key, "upload=" & encodeUrl(uploadId, usePlus = false) & "&part=" & $part), data, [("X-Content-SHA256", shaHex(data))])
  let o = a.outcomeOf
  if not o.ok: return (o, "")
  try: (done(), parseJson(a.body)["etag"].getStr)
  except CatchableError: (fail("the storage module's answer is not an etag"), "")

method completeMultipart*(b: RemoteBackend; key, uploadId: string; parts: seq[(int, string)]): Outcome =
  var ps = newJArray()
  for (n, etag) in parts: ps.add %*[n, etag]
  call(HttpPost, b.objectUri(key, "upload=" & encodeUrl(uploadId, usePlus = false)), $(%*{"parts": ps})).outcomeOf

method abortMultipart*(b: RemoteBackend; key, uploadId: string): Outcome =
  call(HttpDelete, b.objectUri(key, "upload=" & encodeUrl(uploadId, usePlus = false))).outcomeOf

method readRange*(b: RemoteBackend; key: string; offset, length: int64): tuple[res: Outcome, data: string] =
  if length <= 0: return (done(), "")
  let a = call(HttpGet, b.objectUri(key), extra = [("Range", "bytes=" & $offset & "-" & $(offset + length - 1))])
  let o = a.outcomeOf
  if not o.ok: return (o, "")
  (done(), a.body)

method objectSize*(b: RemoteBackend; key: string): tuple[res: Outcome, size: int64] =
  let a = call(HttpGet, b.objectUri(key, "stat"))
  let o = a.outcomeOf
  if not o.ok: return (o, -1'i64)
  try: (done(), parseJson(a.body)["size"].getBiggestInt)
  except CatchableError: (fail("the storage module's answer is not a size"), -1'i64)

method deleteObject*(b: RemoteBackend; key: string): Outcome =
  call(HttpDelete, b.objectUri(key)).outcomeOf

# ------------------------------------------------------------------ the stores of the module

proc fetchStores(): ModuleStores =
  if not storageConfigured(): return ModuleStores(error: "not_configured")
  let a = call(HttpGet, "/v1/stores")
  let o = a.outcomeOf
  if not o.ok: return ModuleStores(error: o.error, retry: o.retry)
  try:
    let j = parseJson(a.body)
    result.ok = true
    result.defaultName = j{"default"}.getStr
    for s in j{"stores"}:
      result.stores.add ModuleStore(name: s{"name"}.getStr, kind: s{"kind"}.getStr, isDefault: s{"default"}.getBool)
  except CatchableError as e:
    result = ModuleStores(error: "the storage module's list is not understood: " & e.msg)

proc moduleStores*(): ModuleStores =
  ## the module's stores and the default one; kept for a few seconds (a store is made rarely, and every upload asks for the default)
  let now = getTime().toUnix()
  withLock listLock:
    if listCache.at > 0 and now - listCache.at < listCacheSeconds and listCache.value.ok: return listCache.value
  let fresh = fetchStores()
  if fresh.ok: withLock listLock: listCache = (fresh, now)
  fresh

# ------------------------------------------------------------------ the direct transfer of a shim (D-61)

proc grantFor*(store, key, upload, mode: string): string =
  ## the token a shim puts the parts of an upload with (`mode` "w") or reads an object with ("r"); "" when the shims go through the core, or the store has no name to bind it to
  if directUrl().len == 0 or store.len == 0: return ""
  signGrant(moduleSecret, moduleShard, store, key, upload, mode, getTime().toUnix())

proc directPath*(store, key: string): string = "/s/" & store & "/" & encodeKey(key)

method uploadedParts*(b: RemoteBackend; key, uploadId: string): tuple[res: Outcome, known: bool, parts: seq[PartRecord]] =
  let a = call(HttpGet, b.objectUri(key, "upload=" & encodeUrl(uploadId, usePlus = false) & "&parts"))
  let o = a.outcomeOf
  if not o.ok: return (o, false, @[])
  try:
    var parts: seq[PartRecord]
    for p in parseJson(a.body)["parts"]: parts.add (p["part"].getInt, p["sha256"].getStr, p["size"].getBiggestInt)
    (done(), true, parts)
  except CatchableError: (fail("the storage module's list of parts is not understood"), false, @[])
