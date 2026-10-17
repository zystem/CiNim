## The store of our own on HTTP nodes (docs/store.md, D-57): `ObjectBackend` (core/storagebackend.nim) over one or more nodes that are Caddy with the WebDAV module of the fork
## (github.com/zystem/caddy-webdav, `atomic_put`), spoken to with PUT, GET with Range, PROPFIND, MOVE and DELETE. A node keeps nothing but files; who may ask is decided by the core
## (core/storeauth.nim: every request carries a token made for it, and the node's `forward_auth` asks the core to check it).
##
## How an object lies on a node. WebDAV cannot join files, so an object is a **directory of chunks**: the key is escaped into a path as on the ZeroMQ node (store/layout.nim) and the
## last segment gets `~obj`, which no escaped segment can have, so no object is ever inside another and a delete of an object cannot take a neighbour with it:
##     data/acme/s1_x/dist/app.txt~obj/.c0000000   .c0000001 ...    (every chunk is a part of the multipart upload, `partSize` bytes but the last)
## A chunk is written atomically (the module's `atomic_put`: temp file, flush, rename, the SHA-256 of the body checked against `X-Content-SHA256`). A whole object appears at once:
## its chunks are written under `.up/<upload id>/`, and one MOVE of that directory onto the object's directory publishes it (a rename on the node; an earlier version of the object is
## replaced as a whole). An abandoned upload is a directory in `.up/` that the core's sweep aborts. The size of an object is what a PROPFIND of its directory adds up to.
##
## `HttpMirror` is the backend: the rules of D-57 (every write to every node at once, succeeds when `minAcks` have it - by default all - and each node
## that did not is reported through `onMissed` for the repair queue; a read tries the nodes in turn). The requests to the nodes of one call go out together on one thread's dispatcher.
import std/[asyncdispatch, strutils, tables, atomics, times, sysrand, sequtils, uri, os, net, algorithm]
import layout, sha
import ../common/storagebackend
import replicas, storeauth, davclient, curlstream
export replicas

type
  HttpNode* = ref object
    name*: string                   ## the id of the node: `host:port` of its address; the Caddyfile of the node says the same in its `forward_auth` (docs/store.md)
    scheme*, host*, prefix*: string ## prefix: the path the share is below, "" or `/something`
    port*: int
    secret*: string
    timeoutMs*: int

  Resp = object
    status: int
    body: string
    headers: seq[(string, string)]
    error: string                   ## when there was no answer at all
    silent: bool                    ## no answer: the node is away or too slow

  NodeRes = object
    ok, retry: bool
    error, etag: string

  Chunk* = tuple[index: int, size: int64]

  Listed = object
    res: NodeRes
    notFound, whole: bool            ## whole: the numbers of the chunks are 0, 1, 2, ...
    chunks: seq[Chunk]

  Read = object
    res: NodeRes
    notFound: bool
    data: string

  Sized = object
    res: NodeRes
    notFound: bool
    size: int64

  HttpMirror* = ref object of ReplicaBackend
    nodes*: seq[HttpNode]
    minAcks*: int
    onMissed*: MissedProc
    turn: Atomic[int]

const
  chunkPrefix = ".c"
  objSuffix = "~obj"
  stageDir = "/.up"
  hexChars = "0123456789abcdef"
  hashHeader = "X-Content-SHA256"

var clients {.threadvar.}: Table[string, DavClient]
when defined(ssl):
  var sslCtx: SslContext
  var sslMade: Atomic[bool]
  var sslBusy: Atomic[bool]

# ------------------------------------------------------------------ names

func encodePath*(p: string): string =
  ## a path for the request line: everything but the unreserved characters and `/` is `%XX`
  for c in p:
    if c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.', '~', '/'}: result.add c
    else:
      result.add '%'
      result.add "0123456789ABCDEF"[ord(c) shr 4]
      result.add "0123456789ABCDEF"[ord(c) and 15]

func chunkName*(index: int): string = chunkPrefix & align($index, 7, '0')

func objectDir*(key: string): string =
  ## the directory of the object of a valid key, as a path of the share (not encoded)
  "/" & keyToRel(key) & objSuffix

func stagePath(id: string): string = stageDir & "/" & id

proc etagOf*(data: string): string = sha256Hex(data) & "-" & $data.len
  ## the "etag" of a part: its SHA-256 and its length, so that the complete can see the sizes without asking a node

func etagSize*(etag: string): int64 =
  let i = etag.rfind('-')
  if i < 0: return -1
  try: parseBiggestInt(etag[i + 1 .. ^1]) except ValueError: -1

proc newId(): string =
  for b in urandom(16):
    result.add hexChars[int(b) shr 4]
    result.add hexChars[int(b) and 15]

proc newHttpNode*(address, secret: string; timeoutMs = 60000): HttpNode =
  ## `address` is `http://host:port` or `https://host:port`, with a path prefix if the share is below one
  let u = parseUri(address)
  let port = if u.port.len > 0: parseInt(u.port) else: (if u.scheme == "https": 443 else: 80)
  let prefix = u.path.strip(chars = {'/'})
  HttpNode(name: u.hostname & ":" & $port, scheme: u.scheme, host: u.hostname, port: port, prefix: (if prefix.len > 0: "/" & prefix else: ""), secret: secret, timeoutMs: timeoutMs)

func base(n: HttpNode): string = n.scheme & "://" & n.host & ":" & $n.port

func parsePropfind*(body: string): seq[tuple[href: string, size: int64]] =
  ## the entries of the answer of a PROPFIND (x/net's WebDAV writes `D:` for the namespace): the decoded `href` and the `getcontentlength` (-1 for a collection)
  var at = 0
  while true:
    let a = body.find("<D:response>", at)
    if a < 0: break
    let b = body.find("</D:response>", a)
    if b < 0: break
    let part = body[a ..< b]
    at = b
    let h1 = part.find("<D:href>")
    let h2 = part.find("</D:href>")
    if h1 < 0 or h2 < h1: continue
    let href = decodeUrl(part[h1 + 8 ..< h2], decodePlus = false)
    var size = -1'i64
    let s1 = part.find("<D:getcontentlength>")
    let s2 = part.find("</D:getcontentlength>")
    if s1 >= 0 and s2 > s1:
      try: size = parseBiggestInt(part[s1 + 20 ..< s2]) except ValueError: discard
    result.add (href, size)

func chunksOf*(entries: seq[tuple[href: string, size: int64]]): tuple[ok: bool, chunks: seq[Chunk]] =
  ## the chunks among the entries of a listing of an object directory, in order; not ok when their numbers are not 0, 1, 2, ... (a damaged object)
  for e in entries:
    if e.size < 0: continue
    let name = e.href.rsplit('/', maxsplit = 1)[^1]
    if not name.startsWith(chunkPrefix) or name.len != chunkPrefix.len + 7: continue
    let digits = name[chunkPrefix.len .. ^1]
    if not digits.allCharsInSet({'0' .. '9'}): continue
    result.chunks.add (parseInt(digits), e.size)
  result.chunks.sort(proc (a, b: Chunk): int = cmp(a.index, b.index))
  result.ok = true
  for i, c in result.chunks:
    if c.index != i: result.ok = false

# ------------------------------------------------------------------ one request

when defined(ssl):
  proc sslContext(): SslContext =
    ## the certificates of the nodes are checked against CINIM_STORE_CA (a file) when it is set, else against the system's
    while not sslMade.load:
      var expected = false
      if sslBusy.compareExchange(expected, true):
        let ca = getEnv("CINIM_STORE_CA")
        sslCtx = newContext(verifyMode = CVerifyPeer, caFile = ca)
        sslMade.store(true)
      else: sleep 1
    sslCtx

func clientKey(n: HttpNode): string = n.scheme & "://" & n.name

proc dropClient(n: HttpNode) =
  if n.clientKey in clients:
    try: clients[n.clientKey].close()
    except CatchableError: discard
    clients.del n.clientKey

proc clientFor(n: HttpNode): DavClient =
  if n.clientKey notin clients:
    when defined(ssl): clients[n.clientKey] = newDavClient(n.host, n.port, n.scheme == "https", (if n.scheme == "https": sslContext() else: nil))
    else: clients[n.clientKey] = newDavClient(n.host, n.port, n.scheme == "https")
  clients[n.clientKey]

proc call(n: HttpNode; meth, path: string; body = ""; extra: seq[(string, string)] = @[]): Future[Resp] {.async.} =
  ## one request to the node; `path` is not yet encoded
  let target = n.prefix & encodePath(path)
  var h = @[("Authorization", "Bearer " & signRequest(n.secret, n.name, meth, target, getTime().toUnix()))]
  h.add extra
  let c = clientFor(n)
  try:
    let fut = c.request(meth, target, h, body)
    if not await fut.withTimeout(n.timeoutMs):
      fut.addCallback(proc () = (if fut.failed: discard))
      n.dropClient()
      return Resp(silent: true, error: n.name & " did not answer in " & $(n.timeoutMs div 1000) & " s")
    let r = fut.read
    return Resp(status: r.status, body: r.body, headers: r.headers)
  except CatchableError as e:
    n.dropClient()
    return Resp(silent: true, error: n.name & ": " & e.msg)

func hdr(h: seq[(string, string)]; name: string): string =
  for (k, v) in h:
    if k.toLowerAscii == name.toLowerAscii: return v

func gist(n: HttpNode; r: Resp; what: string): string =
  if r.silent: r.error
  else:
    let t = r.body.strip
    n.name & " answered " & $r.status & " to " & what & (if t.len > 0: ": " & t[0 ..< min(t.len, 160)] else: "")

func verdict(n: HttpNode; r: Resp; what: string; okCodes: openArray[int] = [200, 201, 204, 206]): NodeRes =
  if not r.silent and r.status in okCodes: return NodeRes(ok: true, etag: r.headers.hdr(hashHeader))
  # no answer, a node in trouble, a lock held for a moment, a body damaged on the way: the same call may work later; a refusal is final
  NodeRes(ok: false, retry: r.silent or r.status in [408, 422, 423, 429, 500, 502, 503, 504, 507], error: gist(n, r, what))

# ------------------------------------------------------------------ what a node does for one object

proc chunkOn(n: HttpNode; dir: string; index: int; data: string): Future[NodeRes] {.async.} =
  let r = await n.call("PUT", dir & "/" & chunkName(index), data, @{hashHeader: sha256Hex(data)})
  var res = n.verdict(r, "a PUT of a chunk")
  if res.ok and res.etag.len > 0 and res.etag != sha256Hex(data):
    res = NodeRes(ok: false, retry: true, error: n.name & " stored another content than it was sent")
  return res

proc publishOn(n: HttpNode; stage, objDir: string): Future[NodeRes] {.async.} =
  let r = await n.call("MOVE", stage, extra = @{"Destination": n.base & n.prefix & encodePath(objDir), "Overwrite": "T"})
  return n.verdict(r, "a MOVE of an upload")

proc discardOn(n: HttpNode; dir: string): Future[NodeRes] {.async.} =
  let r = await n.call("DELETE", dir)
  return n.verdict(r, "a DELETE", [200, 202, 204, 404])

proc listOn(n: HttpNode; dir: string): Future[Listed] {.async.} =
  let r = await n.call("PROPFIND", dir & "/", extra = @{"Depth": "1"})
  if not r.silent and r.status == 404: return Listed(res: NodeRes(ok: false, error: "no such object"), notFound: true, whole: true)
  let res = n.verdict(r, "a PROPFIND", [207])
  if not res.ok: return Listed(res: res, whole: true)
  let cs = chunksOf(parsePropfind(r.body))
  if cs.chunks.len == 0: return Listed(res: NodeRes(ok: false, error: "no such object"), notFound: true, whole: true)
  return Listed(res: res, chunks: cs.chunks, whole: cs.ok)

proc putOn(n: HttpNode; key, data: string): Future[NodeRes] {.async.} =
  let stage = stagePath(newId())
  var r = await n.chunkOn(stage, 0, data)
  if not r.ok:
    discard await n.discardOn(stage)
    return r
  r = await n.publishOn(stage, objectDir(key))
  if not r.ok: discard await n.discardOn(stage)
  return r

proc completeOn(n: HttpNode; key, id: string; parts: seq[(int, string)]): Future[NodeRes] {.async.} =
  let stage = stagePath(id)
  let l = await n.listOn(stage)
  if not l.res.ok and not l.notFound: return l.res
  var complete = l.res.ok and l.whole and l.chunks.len == parts.len
  if complete:
    for i, c in l.chunks:
      if c.size != etagSize(parts[i][1]): complete = false
  if not complete:
    discard await n.discardOn(stage)
    return NodeRes(ok: false, retry: false, error: n.name & " does not have all the parts of the upload")
  let r = await n.publishOn(stage, objectDir(key))
  if not r.ok: discard await n.discardOn(stage)
  return r

proc readChunk(n: HttpNode; key: string; index: int; offset, length: int64): Future[Read] {.async.} =
  let r = await n.call("GET", objectDir(key) & "/" & chunkName(index), extra = @{"Range": "bytes=" & $offset & "-" & $(offset + length - 1)})
  if not r.silent and r.status == 404: return Read(res: NodeRes(ok: false, error: "no such object"), notFound: true)
  if not r.silent and r.status == 416: return Read(res: NodeRes(ok: true))              # past the end of the chunk: nothing there
  let res = n.verdict(r, "a GET of a chunk")
  var got = Read(res: res)
  if res.ok: got.data = r.body
  return got

proc readOn(n: HttpNode; key: string; offset, length: int64): Future[Read] {.async.} =
  var pos = offset
  var left = length
  var data = ""
  while left > 0:
    let index = int(pos div partSize)
    let inChunk = pos mod partSize
    let want = min(left, partSize - inChunk)
    let c = await n.readChunk(key, index, inChunk, want)
    if c.notFound:
      if index == 0 and pos == offset: return Read(res: c.res, notFound: true)
      break                                                                              # a chunk past the end: the object ended
    if not c.res.ok: return Read(res: c.res)
    data.add c.data
    if int64(c.data.len) < want: break                                                  # a short chunk is the last one
    pos += c.data.len
    left -= c.data.len
  return Read(res: NodeRes(ok: true), data: data)

proc sizeOn(n: HttpNode; key: string): Future[Sized] {.async.} =
  let l = await n.listOn(objectDir(key))
  if not l.res.ok: return Sized(res: l.res, notFound: l.notFound, size: -1)
  if not l.whole: return Sized(res: NodeRes(ok: false, error: n.name & ": the chunks of the object are not 0, 1, 2, ... (damaged)"), size: -1)
  var total = 0'i64
  for c in l.chunks: total += c.size
  return Sized(res: l.res, size: total)

proc deleteOn(n: HttpNode; key: string): Future[NodeRes] {.async.} = return await n.discardOn(objectDir(key))

# ------------------------------------------------------------------ the mirror

proc newHttpMirror*(nodes: seq[HttpNode]; minAcks = 0; onMissed: MissedProc = nil): HttpMirror =
  HttpMirror(nodes: nodes, minAcks: (if minAcks <= 0: nodes.len else: max(1, min(minAcks, nodes.len))), onMissed: onMissed)

proc missed(b: HttpMirror; key: string; i: int; what: string) =
  if b.onMissed != nil: b.onMissed(key, b.nodes[i].name, what)

func outcome(r: NodeRes): Outcome = (if r.ok: done() else: fail(r.error, retry = r.retry))

func worst(rs: seq[NodeRes]): NodeRes =
  for r in rs:
    if not r.ok and not r.retry: return r
  for r in rs:
    if not r.ok: return r

proc acks(rs: seq[NodeRes]): int = rs.countIt(it.ok)

proc gather(futs: seq[Future[NodeRes]]): seq[NodeRes] =
  if futs.len == 0: return
  result = waitFor all(futs)

method nodeNames*(b: HttpMirror): seq[string] = b.nodes.mapIt(it.name)

method putObject*(b: HttpMirror; key, data: string): Outcome =
  let why = validKey(key)
  if why.len > 0: return fail("the key is not good: " & why)
  if data.len > partSize: return fail("a put is at most " & $partSize & " bytes; use a multipart upload")
  let rs = gather(b.nodes.mapIt(it.putOn(key, data)))
  if rs.acks < b.minAcks:
    let w = rs.worst
    return fail(w.error, retry = w.retry)
  for i, r in rs:
    if not r.ok: b.missed(key, i, "copy")
  done()

method createMultipart*(b: HttpMirror; key: string): tuple[res: Outcome, uploadId: string] =
  let why = validKey(key)
  if why.len > 0: return (fail("the key is not good: " & why), "")
  (done(), newId())                                   # nothing to ask a node: the upload is a directory that its first part makes

method uploadPart*(b: HttpMirror; key, uploadId: string; part: int; data: string): tuple[res: Outcome, etag: string] =
  if uploadId.len != 32 or not uploadId.allCharsInSet({'0' .. '9', 'a' .. 'f'}): return (fail("no such upload"), "")
  if part < 1 or part > maxParts: return (fail("parts are numbered 1.." & $maxParts), "")
  if data.len > partSize: return (fail("a part is at most " & $partSize & " bytes"), "")
  let stage = stagePath(uploadId)
  let rs = gather(b.nodes.mapIt(it.chunkOn(stage, part - 1, data)))
  if rs.acks < b.minAcks:
    let w = rs.worst
    return (fail(w.error, retry = w.retry), "")
  (done(), etagOf(data))

# ------------------------------------------------------------------ the same as a stream (docs/storage-module.md, "The streaming PUT")

proc streamChunk(b: HttpMirror; dir: string; index: int; size: int64; sha256: string; src: BodySource): tuple[rs: seq[NodeRes], srcOk: bool] =
  ## a chunk written as a stream to every node at once, through libcurl: the body is passed on piece by piece as the module reads it, and each node checks it against `sha256`, which it is
  ## told first (`X-Content-SHA256`); a node that answers another digest is not trusted
  var targets: seq[UpTarget]
  let now = getTime().toUnix()
  for n in b.nodes:
    let target = n.prefix & encodePath(dir & "/" & chunkName(index))
    targets.add UpTarget(url: n.base & target, caFile: getEnv("CINIM_STORE_CA"), timeoutMs: n.timeoutMs,
                         headers: @["Authorization: Bearer " & signRequest(n.secret, n.name, "PUT", target, now), hashHeader & ": " & sha256])
  let sent = streamUpload(targets, size, src)
  result.srcOk = sent.sourceOk
  for i, n in b.nodes:
    let u = sent.results[i]
    var res = n.verdict(Resp(status: u.status, body: u.body, headers: u.headers, error: n.name & ": " & u.error, silent: u.status == 0), "a PUT of a chunk")
    if res.ok and res.etag.len > 0 and res.etag != sha256:
      res = NodeRes(ok: false, retry: true, error: n.name & " stored another content than it was sent")
    result.rs.add res

proc publishOrDiscard(n: HttpNode; sent: NodeRes; stage, objDir: string): Future[NodeRes] {.async.} =
  ## after a chunk was written: the node that has it publishes it (one MOVE), the one that has not drops what it may have staged
  if not sent.ok:
    discard await n.discardOn(stage)
    return sent
  let r = await n.publishOn(stage, objDir)
  if not r.ok: discard await n.discardOn(stage)
  return r

method putStream*(b: HttpMirror; key: string; size: int64; sha256: string; src: BodySource): Outcome =
  let why = validKey(key)
  if why.len > 0: return fail("the key is not good: " & why)
  if size > partSize: return fail("a put is at most " & $partSize & " bytes; use a multipart upload")
  let stage = stagePath(newId())
  let sent = b.streamChunk(stage, 0, size, sha256, src)
  if not sent.srcOk:
    discard gather(b.nodes.mapIt(it.discardOn(stage)))
    return fail("the body did not come whole", retry = true)
  let rs = gather(b.nodes.mapIt(it.publishOrDiscard(sent.rs[b.nodes.find(it)], stage, objectDir(key))))
  if rs.acks < b.minAcks:
    let w = rs.worst
    return fail(w.error, retry = w.retry)
  for i, r in rs:
    if not r.ok: b.missed(key, i, "copy")
  done()

method uploadPartStream*(b: HttpMirror; key, uploadId: string; part: int; size: int64; sha256: string; src: BodySource): tuple[res: Outcome, etag: string] =
  if uploadId.len != 32 or not uploadId.allCharsInSet({'0' .. '9', 'a' .. 'f'}): return (fail("no such upload"), "")
  if part < 1 or part > maxParts: return (fail("parts are numbered 1.." & $maxParts), "")
  if size > partSize: return (fail("a part is at most " & $partSize & " bytes"), "")
  let sent = b.streamChunk(stagePath(uploadId), part - 1, size, sha256, src)
  if not sent.srcOk: return (fail("the body did not come whole", retry = true), "")
  if sent.rs.acks < b.minAcks:
    let w = sent.rs.worst
    return (fail(w.error, retry = w.retry), "")
  (done(), sha256 & "-" & $size)         # the etag of a part is its digest and its length (etagOf)

method completeMultipart*(b: HttpMirror; key, uploadId: string; parts: seq[(int, string)]): Outcome =
  if parts.len == 0 or parts.len > maxParts: return fail("an upload has 1.." & $maxParts & " parts")
  for i, (n, etag) in parts:
    if n != i + 1: return fail("the parts are 1, 2, 3, ... in order, none missing")
    let sz = etagSize(etag)
    if sz < 0 or sz > partSize or (i < parts.high and sz != partSize): return fail("part " & $n & " is not " & $partSize & " bytes, and it is not the last")
  let rs = gather(b.nodes.mapIt(it.completeOn(key, uploadId, parts)))
  if rs.acks < b.minAcks:
    let w = rs.worst
    return fail(w.error, retry = w.retry)
  for i, r in rs:
    if not r.ok: b.missed(key, i, "copy")
  done()

method abortMultipart*(b: HttpMirror; key, uploadId: string): Outcome =
  if uploadId.len == 32 and uploadId.allCharsInSet({'0' .. '9', 'a' .. 'f'}):
    discard gather(b.nodes.mapIt(it.discardOn(stagePath(uploadId))))
  done()

proc order(b: HttpMirror): seq[int] =
  let start = b.turn.fetchAdd(1) mod b.nodes.len
  for k in 0 ..< b.nodes.len: result.add (start + k) mod b.nodes.len

method readRange*(b: HttpMirror; key: string; offset, length: int64): tuple[res: Outcome, data: string] =
  let why = validKey(key)
  if why.len > 0: return (fail("the key is not good: " & why), "")
  var lastFail = fail("no such object")
  for i in b.order():
    let r = waitFor b.nodes[i].readOn(key, offset, length)
    if r.res.ok: return (done(), r.data)
    if not r.notFound: lastFail = fail(r.res.error, retry = r.res.retry)
  (lastFail, "")

method readStream*(b: HttpMirror; key: string; offset, length: int64; sink: PieceSink): Outcome =
  ## A read that goes to `sink` as the nodes give it (docs/storage-module.md, "Streaming reads"): the range is cut at the borders of the chunks, each piece comes from the first node
  ## that answers, and a node that fails in the middle of a chunk is replaced by the next one from the byte where it stopped, so the reader sees one unbroken stream.
  let why = validKey(key)
  if why.len > 0: return fail("the key is not good: " & why)
  var pos = offset
  var left = length
  var emitted = false
  var lastFail = fail("no such object")
  while left > 0:
    let now = getTime().toUnix()                      # a long stream outlives a token
    let index = int(pos div partSize)
    let inChunk = pos mod partSize
    let want = min(left, partSize - inChunk)
    var done = 0'i64                                  # bytes of this piece that went to the sink
    var finished = false
    var allMissing = true
    for i in b.order():
      let n = b.nodes[i]
      let target = n.prefix & encodePath(objectDir(key) & "/" & chunkName(index))
      let r = streamDownload(n.base & target, @["Authorization: Bearer " & signRequest(n.secret, n.name, "GET", target, now),
                                              "Range: bytes=" & $(inChunk + done) & "-" & $(inChunk + want - 1)], getEnv("CINIM_STORE_CA"), n.timeoutMs,
                             proc (chunk: string): bool =
                               emitted = true
                               sink(chunk))
      done += r.delivered
      pos += r.delivered
      left -= r.delivered
      if r.stopped: return fail("the reader went away")
      if r.status == 404:
        continue                                      # this node does not have it: another may
      allMissing = false
      if r.status == 416:
        finished = true                               # past the end of the chunk: nothing there, the object ended
        left = 0
        break
      if r.status in 200 .. 299 and r.error.len == 0:
        if done < want: left = 0                      # a short chunk is the last one
        finished = true
        break
      lastFail = fail(if r.status == 0: n.name & ": " & r.error else: n.name & " answered " & $r.status & " to a GET of a chunk",
                      retry = r.status == 0 or r.status in [408, 422, 423, 429, 500, 502, 503, 504, 507])
    if not finished:
      if allMissing:
        if emitted or pos != offset: left = 0         # a chunk past the end: the object ended
        else: return fail("no such object")
      else: return lastFail
  done()

method objectSize*(b: HttpMirror; key: string): tuple[res: Outcome, size: int64] =
  let why = validKey(key)
  if why.len > 0: return (fail("the key is not good: " & why), -1'i64)
  var lastFail = fail("no such object")
  for i in b.order():
    let r = waitFor b.nodes[i].sizeOn(key)
    if r.res.ok: return (done(), r.size)
    if not r.notFound: lastFail = fail(r.res.error, retry = r.res.retry)
  (lastFail, -1'i64)

method deleteObject*(b: HttpMirror; key: string): Outcome =
  let why = validKey(key)
  if why.len > 0: return fail("the key is not good: " & why)
  let rs = gather(b.nodes.mapIt(it.deleteOn(key)))
  if rs.acks < b.minAcks:
    let w = rs.worst
    return fail(w.error, retry = w.retry)
  for i, r in rs:
    if not r.ok: b.missed(key, i, "delete")
  done()

# ------------------------------------------------------------------ the repair, one node and another

method sizeOn*(b: HttpMirror; node: int; key: string): Probe =
  let r = waitFor b.nodes[node].sizeOn(key)
  Probe(ok: r.res.ok, retry: r.res.retry, notFound: r.notFound, size: r.size, error: r.res.error)

method deleteOn*(b: HttpMirror; node: int; key: string): Outcome = outcome(waitFor b.nodes[node].deleteOn(key))

proc copyChunks(src, dst: HttpNode; key: string): Future[NodeRes] {.async.} =
  let l = await src.listOn(objectDir(key))
  if not l.res.ok: return l.res
  if not l.whole: return NodeRes(ok: false, error: src.name & ": the chunks of the object are not 0, 1, 2, ... (damaged)")
  let stage = stagePath(newId())
  for c in l.chunks:
    let rd = await src.readChunk(key, c.index, 0, c.size)
    if not rd.res.ok or int64(rd.data.len) != c.size:
      discard await dst.discardOn(stage)
      return if not rd.res.ok: rd.res else: NodeRes(ok: false, retry: true, error: src.name & " gave less of a chunk than it has")
    let w = await dst.chunkOn(stage, c.index, rd.data)
    if not w.ok:
      discard await dst.discardOn(stage)
      return w
  let p = await dst.publishOn(stage, objectDir(key))
  if not p.ok: discard await dst.discardOn(stage)
  return p

method copyBetween*(b: HttpMirror; src, dst: int; key: string): Outcome =
  outcome(waitFor copyChunks(b.nodes[src], b.nodes[dst], key))
