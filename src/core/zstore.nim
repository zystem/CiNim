## The store of our own as the core uses it (docs/store.md, D-57): `ObjectBackend` (core/storagebackend.nim) over one or more store nodes, spoken to over ZeroMQ with CURVE.
##
## `ZNode` is one node: every thread that talks to it has a connection of its own (a ZeroMQ socket is not for two threads), made when it is first needed, and given up when a
## request times out (so that the requests queued for a node that is away are not run when it returns). A request is sent, and its answer waited for by the number of the request.
##
## `MirrorBackend` is the backend: every write goes to every node in parallel, the requests sent to all before any answer is waited for; it succeeds when `minAcks` nodes have it - by
## default all of them, so the answer is that of the last node - and each node that did not is reported through `onMissed` (the core puts that in its repair queue, core/storerepair.nim). A read tries the nodes in turn, the first that has the object answers; a
## delete goes to all. One node is a mirror of itself. The upload id of a multipart upload is the nodes' ids joined by `|`, `-` for a node that was away at the start.
import std/[tables, strutils, options, atomics, times, sequtils, sysrand, locks]
import ../common/[stream, zmqcurve]
import ../store/[wire, sha]
import storagebackend

type
  ZNode* = ref object
    name*, address*, serverKey*, token*: string
    keys*: CurveKeypair
    timeoutMs*: int
    plain*: bool                    ## no CURVE on this link (the node was started with CINIM_STORE_TRANSPORT=plain): for a network that is encrypted anyway; the token still says who asks

  Reply* = object
    ok*, retry*: bool
    code*, error*: string
    msg*: Msg

  Conn = ref object
    conn: ZConnection
    session: string
    next: uint64

  MissedProc* = proc (key, node, op: string) {.gcsafe.}

  MirrorBackend* = ref object of ObjectBackend
    nodes*: seq[ZNode]
    minAcks*: int
    onMissed*: MissedProc
    turn: Atomic[int]

var conns {.threadvar.}: Table[string, Conn]
var sessionCounter: Atomic[int]

const
  readChunk* = 4 * 1024 * 1024
  hexChars = "0123456789abcdef"

proc newNode*(address, serverKey, token: string; keys: CurveKeypair; timeoutMs = 30000): ZNode =
  ZNode(name: address, address: address, serverKey: serverKey, token: token, keys: keys, timeoutMs: timeoutMs)

var ctxLock: Lock
var storeCtx: ZContext
initLock(ctxLock)

proc sharedContext(): ZContext =
  ## one context for the store connections of the process, with I/O threads enough for the connections of several threads to be encrypted at once (stream.newContext)
  withLock ctxLock:
    if storeCtx == nil: storeCtx = newContext(4)
    result = storeCtx

proc dropConn(n: ZNode) =
  if n.address in conns:
    try: conns[n.address].conn.close(linger = 0)
    except CatchableError: discard
    conns.del n.address

proc connFor(n: ZNode): Conn =
  if n.address notin conns:
    discard sessionCounter.fetchAdd(1)
    let c = connect(n.address, DEALER, sharedContext()) do (s: ZSocket) -> void:
      if not n.plain: s.setCurveClient(n.serverKey, n.keys.publicKey, n.keys.secretKey)
      s.setsockopt(IMMEDIATE, 1.cint)             # a request is queued only for a node that is connected: none waits for one that is away
      s.setsockopt(HEARTBEAT_IVL, 3000.cint)
      s.setsockopt(HEARTBEAT_TIMEOUT, 10000.cint)
      s.setsockopt(RECONNECT_IVL, 500.cint)
      s.setsockopt(RECONNECT_IVL_MAX, 3000.cint)
      s.setsockopt(CONNECT_TIMEOUT, 3000.cint)
      s.setsockopt(SNDTIMEO, 3000.cint)
    var tag = ""
    for b in urandom(4):
      tag.add hexChars[int(b) shr 4]
      tag.add hexChars[int(b) and 15]
    conns[n.address] = Conn(conn: c, session: "z" & tag & "-" & $sessionCounter.load, next: 0)
  conns[n.address]

func unreachable(why: string): Reply = Reply(retry: true, code: "unreachable", error: why)

proc toReply(m: Msg): Reply =
  result.msg = m
  result.ok = m.get(tOk) == "1"
  if not result.ok:
    result.code = m.get(tCode)
    result.error = m.get(tError)
    result.retry = result.code in ["io", "unreachable", "busy"]

proc send*(n: ZNode; req: Msg): uint64 =
  ## 0 when the request could not even be queued
  let c = n.connFor()
  var r = req
  r.add(tToken, n.token)
  inc c.next
  if not c.conn.sendFrame(frame(c.session, "store.req", encode(r), id = c.next)):
    n.dropConn()
    return 0
  c.next

proc await*(n: ZNode; id: uint64): Reply =
  if id == 0: return unreachable("the request could not be sent to " & n.name)
  let c = n.connFor()
  let deadline = epochTime() + n.timeoutMs / 1000
  while true:
    let left = int((deadline - epochTime()) * 1000)
    if left <= 0:
      n.dropConn()
      return unreachable(n.name & " did not answer in " & $(n.timeoutMs div 1000) & " s")
    let f = c.conn.receive(left)
    if f.isNone: continue
    if f.get.kind != "store.rep" or f.get.re != id: continue               # an answer to a request given up already
    let body = decode(f.get.payload)
    if body.isNone: return Reply(retry: false, code: "bad_reply", error: "the node's answer is not a store message")
    return toReply(body.get)

proc call*(n: ZNode; req: Msg): Reply = n.await(n.send(req))

func op(name: string; fields: varargs[Field]): Msg =
  result.add(tOp, name)
  for f in fields: result.add f

proc shaHex(data: string): string = sha256Hex(data)

func outcome(r: Reply): Outcome = (if r.ok: done() else: fail(r.error, retry = r.retry))

# ------------------------------------------------------------------ a node, one thing at a time

proc nodeSize*(n: ZNode; key: string): tuple[reply: Reply, size: int64] =
  let r = n.call(op("size", (tKey, key)))
  (r, if r.ok: r.msg.getInt(tSize) else: -1)

proc nodeHash*(n: ZNode; key: string): tuple[reply: Reply, sha256: string] =
  let r = n.call(op("hash", (tKey, key)))
  (r, if r.ok: r.msg.get(tSha256) else: "")

proc nodeList*(n: ZNode; prefix, after: string; limit = 500): tuple[reply: Reply, entries: seq[tuple[key: string, size, mtime: int64, exact: bool]], next: string] =
  let r = n.call(op("list", (tPrefix, prefix), (tAfter, after), (tLimit, $limit)))
  result.reply = r
  if r.ok:
    for e in r.msg.all(tEntries):
      let p = parseEntry(e)
      if p.isSome: result.entries.add p.get
    result.next = r.msg.get(tNext)

proc nodeStats*(n: ZNode): tuple[reply: Reply, total, free: int64] =
  let r = n.call(op("stats"))
  (r, if r.ok: r.msg.getInt(tTotal) else: 0, if r.ok: r.msg.getInt(tFree) else: 0)

proc nodeRead*(n: ZNode; key: string; offset, length: int64): tuple[reply: Reply, data: string, size: int64] =
  let r = n.call(op("read", (tKey, key), (tOffset, $offset), (tLength, $length)))
  (r, if r.ok: r.msg.get(tData) else: "", if r.ok: r.msg.getInt(tSize) else: -1)

proc nodePut*(n: ZNode; key, data: string): Reply = n.call(op("put", (tKey, key), (tData, data), (tSha256, shaHex(data))))

proc nodeDelete*(n: ZNode; key: string): Reply = n.call(op("delete", (tKey, key)))

proc copyObject*(src, dst: ZNode; key: string): Outcome =
  ## the object from `src` onto `dst`, whole or by parts, checked against the SHA-256 that `src` has for it. For the repair.
  let sz = src.nodeSize(key)
  if not sz.reply.ok: return fail(sz.reply.error, retry = sz.reply.retry)
  let want = src.nodeHash(key)
  if not want.reply.ok: return fail(want.reply.error, retry = want.reply.retry)
  if sz.size <= 8 * 1024 * 1024:
    let rd = src.nodeRead(key, 0, sz.size)
    if not rd.reply.ok: return fail(rd.reply.error, retry = rd.reply.retry)
    let put = dst.call(op("put", (tKey, key), (tData, rd.data), (tSha256, want.sha256)))
    return outcome(put)
  let up = dst.call(op("mp_create", (tKey, key)))
  if not up.ok: return outcome(up)
  let id = up.msg.get(tUploadId)
  var parts: seq[(int, string)]
  var offset = 0'i64
  var buf = ""
  var partNo = 0
  while offset < sz.size or buf.len > 0:
    if offset < sz.size and buf.len < 8 * 1024 * 1024:
      let rd = src.nodeRead(key, offset, readChunk)
      if not rd.reply.ok or rd.data.len == 0:
        discard dst.call(op("mp_abort", (tUploadId, id)))
        return fail(if rd.reply.ok: "the object is shorter than it was" else: rd.reply.error, retry = true)
      buf.add rd.data
      offset += rd.data.len
      if buf.len < 8 * 1024 * 1024 and offset < sz.size: continue
    inc partNo
    let pr = dst.call(op("mp_part", (tUploadId, id), (tPart, $partNo), (tData, buf)))
    if not pr.ok:
      discard dst.call(op("mp_abort", (tUploadId, id)))
      return outcome(pr)
    parts.add (partNo, pr.msg.get(tEtag))
    buf.setLen 0
  var fin = op("mp_complete", (tUploadId, id), (tSha256, want.sha256))
  for (n, e) in parts: fin.add(tParts, partText(n, e))
  let r = dst.call(fin)
  if not r.ok: discard dst.call(op("mp_abort", (tUploadId, id)))
  outcome(r)

# ------------------------------------------------------------------ the mirror

proc newMirror*(nodes: seq[ZNode]; minAcks = 0; onMissed: MissedProc = nil): MirrorBackend =
  ## `minAcks` 0 (the default) is every node: a write, a delete and every step of an upload are sent to all nodes at once and succeed when the last has answered ok. A smaller number
  ## is a degraded mode chosen on purpose: the nodes that missed the operation go into the repair queue.
  MirrorBackend(nodes: nodes, minAcks: (if minAcks <= 0: nodes.len else: max(1, min(minAcks, nodes.len))), onMissed: onMissed)

proc missed(b: MirrorBackend; key: string; i: int; what: string) =
  if b.onMissed != nil: b.onMissed(key, b.nodes[i].name, what)

proc fanout(b: MirrorBackend; reqs: seq[Msg]; skip: seq[bool] = @[]): seq[Reply] =
  ## `reqs[i]` goes to node i (all sent before any answer is waited for); a skipped node gets the reply "unreachable"
  var ids = newSeq[uint64](b.nodes.len)
  for i, n in b.nodes:
    if skip.len > i and skip[i]: continue
    ids[i] = n.send(reqs[i])
  for i, n in b.nodes:
    result.add(if skip.len > i and skip[i]: unreachable("this node was away at the start of the upload") else: n.await(ids[i]))

func worst(rs: seq[Reply]): Reply =
  ## the failure to report when too few nodes answered ok: a final one (a refusal) wins over "unreachable"
  for r in rs:
    if not r.ok and not r.retry: return r
  for r in rs:
    if not r.ok: return r

proc acks(rs: seq[Reply]): int = rs.countIt(it.ok)

method putObject*(b: MirrorBackend; key, data: string): Outcome =
  let req = op("put", (tKey, key), (tData, data), (tSha256, shaHex(data)))
  let rs = b.fanout(b.nodes.mapIt(req))
  if rs.acks < b.minAcks:
    let w = rs.worst
    return fail(w.error, retry = w.retry)
  for i, r in rs:
    if not r.ok: b.missed(key, i, "copy")
  done()

proc splitId(b: MirrorBackend; uploadId: string): seq[string] =
  result = uploadId.split('|')
  if result.len != b.nodes.len: result = newSeq[string](b.nodes.len).mapIt("-")

method createMultipart*(b: MirrorBackend; key: string): tuple[res: Outcome, uploadId: string] =
  let req = op("mp_create", (tKey, key))
  let rs = b.fanout(b.nodes.mapIt(req))
  if rs.acks < b.minAcks:
    for i, r in rs:
      if r.ok: discard b.nodes[i].call(op("mp_abort", (tUploadId, r.msg.get(tUploadId))))
    let w = rs.worst
    return (fail(w.error, retry = w.retry), "")
  (done(), rs.mapIt(if it.ok: it.msg.get(tUploadId) else: "-").join("|"))

method uploadPart*(b: MirrorBackend; key, uploadId: string; part: int; data: string): tuple[res: Outcome, etag: string] =
  let ids = b.splitId(uploadId)
  let reqs = ids.mapIt(op("mp_part", (tUploadId, it), (tPart, $part), (tData, data)))
  let rs = b.fanout(reqs, ids.mapIt(it == "-"))
  var live = 0
  for i, id in ids:
    if id != "-": inc live
  if rs.acks < min(b.minAcks, max(live, 1)):
    let w = rs.worst
    return (fail(w.error, retry = w.retry), "")
  for r in rs:
    if r.ok: return (done(), r.msg.get(tEtag))

method completeMultipart*(b: MirrorBackend; key, uploadId: string; parts: seq[(int, string)]): Outcome =
  let ids = b.splitId(uploadId)
  var reqs: seq[Msg]
  for id in ids:
    var m = op("mp_complete", (tUploadId, id))
    for (n, e) in parts: m.add(tParts, partText(n, e))
    reqs.add m
  let rs = b.fanout(reqs, ids.mapIt(it == "-"))
  if rs.acks < b.minAcks:
    let w = rs.worst
    return fail(w.error, retry = w.retry)
  for i, r in rs:
    if not r.ok:
      if ids[i] != "-": discard b.nodes[i].call(op("mp_abort", (tUploadId, ids[i])))
      b.missed(key, i, "copy")
  done()

method abortMultipart*(b: MirrorBackend; key, uploadId: string): Outcome =
  let ids = b.splitId(uploadId)
  discard b.fanout(ids.mapIt(op("mp_abort", (tUploadId, it))), ids.mapIt(it == "-"))
  done()

proc order(b: MirrorBackend): seq[int] =
  let start = b.turn.fetchAdd(1) mod b.nodes.len
  for k in 0 ..< b.nodes.len: result.add (start + k) mod b.nodes.len

method readRange*(b: MirrorBackend; key: string; offset, length: int64): tuple[res: Outcome, data: string] =
  var lastFail = fail("no such object")
  for i in b.order():
    let r = b.nodes[i].call(op("read", (tKey, key), (tOffset, $offset), (tLength, $length)))
    if r.ok: return (done(), r.msg.get(tData))
    if r.code != "not_found": lastFail = fail(r.error, retry = r.retry)      # a node that did not answer is worth another try; "no such object" from all is final
  (lastFail, "")

method objectSize*(b: MirrorBackend; key: string): tuple[res: Outcome, size: int64] =
  var lastFail = fail("no such object")
  for i in b.order():
    let r = b.nodes[i].call(op("size", (tKey, key)))
    if r.ok: return (done(), r.msg.getInt(tSize))
    if r.code != "not_found": lastFail = fail(r.error, retry = r.retry)
  (lastFail, -1'i64)

method deleteObject*(b: MirrorBackend; key: string): Outcome =
  let req = op("delete", (tKey, key))
  let rs = b.fanout(b.nodes.mapIt(req))
  if rs.acks < b.minAcks:
    let w = rs.worst
    return fail(w.error, retry = w.retry)
  for i, r in rs:
    if not r.ok: b.missed(key, i, "delete")
  done()

proc nodeNamed*(b: MirrorBackend; name: string): ZNode =
  for n in b.nodes:
    if n.name == name: return n
