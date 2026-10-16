## `cinim-store`: a store node (docs/store.md, D-57). One CURVE ROUTER socket for the core; a pool of workers does the disk work, as the push channel of the core does
## (core/streamhub.nim): the I/O thread reads the frames and hands each to the worker of its session (so what one client sends one after the other is done in that order), and
## sends what the workers have answered. Messages cross threads in shared memory (common/shmq.nim), never as Nim strings.
##
## CINIM_STORE_ROOT (default /data), CINIM_CERTS (the `store` keypair), CINIM_STORE_PORT (19750), CINIM_STORE_TOKEN or CINIM_STORE_TOKEN_FILE (required), CINIM_STORE_WORKERS (4),
## CINIM_STORE_TMP_AGE (seconds a leftover in tmp/ lives, 86400), CINIM_STORE_IO_THREADS (ZeroMQ I/O threads, 4), CINIM_STORE_TRANSPORT (curve, or plain for a network that is encrypted anyway), CINIM_STORE_SYNC (full: the file and its directory are flushed before the answer; file; none).
import std/[os, strutils, atomics, options, hashes, times, posix]
import ../common/[stream, zmqcurve, shmq]
import disk, wire, node

var stopping: Atomic[bool]

proc onTerm(sig: cint) {.noconv.} = stopping.store(true)

const
  msgOut = 0
  msgReq = 1
  replyKind = "store.rep"

type
  WorkerArgs = tuple[root, token: string, inq, outq: ptr ShmQueue]
  Bytes = ptr UncheckedArray[char]

proc replyHeadroom(sessionLen: int): int =
  ## room before the bytes of a read for everything that precedes them in the reply frame: the header of the frame, the fields `ok` and `size` (at most 31 bytes) and the header of `data`
  33 + sessionLen + replyKind.len + 31 + 5 + 16

proc fixedReply(h: FrameHead; body: Msg; outq: ptr ShmQueue; routing: string) =
  let bytes = encodeFrame(frame(h.session, replyKind, encode(body), re = h.id))
  let b = cast[Bytes](shmAlloc(bytes.len))
  copyMem(b, unsafeAddr bytes[0], bytes.len)
  outq[].pushOwned(msgOut, routing, b, b, bytes.len)

proc runWorker(a: WorkerArgs) {.thread.} =
  {.cast(gcsafe).}:
    let d = openDisk(a.root)
    var kind, n: int
    var routing: string
    var buf: Bytes
    var base: pointer
    while not stopping.load:
      if not a.inq[].popOwned(200, kind, routing, buf, n, base): continue
      defer: shmFree(base)
      let h = decodeHead(buf, n)
      if h.isNone or h.get.kind != "store.req": continue
      let head = h.get
      let body = view(cast[Bytes](addr buf[head.payloadAt]), head.payloadLen)
      if body.isNone:
        fixedReply(head, @[(tOk, "0"), (tCode, "bad_request"), (tError, "the request is not a store message")], a.outq, routing)
        continue
      var r: Reply
      let headroom = replyHeadroom(head.session.len)
      try: r = handleView(d, a.token, body.get, headroom)
      except CatchableError as e: r = Reply(fields: @[(tOk, "0"), (tCode, "io"), (tError, e.msg)])
      if r.base == nil:
        fixedReply(head, r.fields, a.outq, routing)
      else:
        # the bytes of a read are where the disk put them; the header of the frame is written right before them
        let tlv = encode(r.fields)
        var dataHead = newString(5)
        dataHead[0] = char(tData)
        for i in countdown(3, 0): dataHead[4 - i] = char((r.dataLen shr (i * 8)) and 0xff)
        let hdr = frameHeader(frame(head.session, replyKind, "", re = head.id), tlv.len + 5 + r.dataLen) & tlv & dataHead
        let start = headroom - hdr.len
        doAssert start >= 0
        let at = cast[Bytes](cast[uint](r.base) + uint(start))
        copyMem(at, unsafeAddr hdr[0], hdr.len)
        a.outq[].pushOwned(msgOut, routing, r.base, at, hdr.len + r.dataLen)

proc freeBlock(data, hint: pointer) {.noconv.} = shmFree(hint)

proc sendOwned(c: ZConnection; routing: string; base: pointer; b: Bytes; n: int) =
  ## routing id, then the frame without a copy: ZeroMQ gives the block back (`freeBlock`) when it has sent it, or when it could not
  try:
    c.socket.send(routing, SNDMORE)
  except CatchableError:
    shmFree(base)
    return
  var m: ZMsg
  if msg_init(m, cast[cstring](b), n, freeBlock, base) != 0:
    shmFree(base)
    return
  if msg_send(m, c.socket, 0) < 0: discard msg_close(m)

proc receiveOwned(c: ZConnection; blocking: bool): Option[tuple[routing: string, base: Bytes, n: int]] =
  ## one message of two parts, the routing id and the frame; the frame goes from ZeroMQ into a block of its own with one copy
  var m: ZMsg
  if msg_init(m) != 0: return none(tuple[routing: string, base: Bytes, n: int])
  if msg_recv(m, c.socket, if blocking: 0 else: ZMQ_DONTWAIT.cint) < 0:
    discard msg_close(m)
    return none(tuple[routing: string, base: Bytes, n: int])
  var routing = newString(msg_size(m))
  if routing.len > 0: copyMem(addr routing[0], msg_data(m), routing.len)
  var more = msg_more(m) != 0
  discard msg_close(m)
  var parts = 1
  var frameBlock: Bytes = nil
  var frameLen = 0
  while more:
    var q: ZMsg
    if msg_init(q) != 0: break
    if msg_recv(q, c.socket, 0) < 0:
      discard msg_close(q)
      break
    inc parts
    more = msg_more(q) != 0
    if parts == 2:
      frameLen = msg_size(q)
      frameBlock = cast[Bytes](shmAlloc(frameLen))
      if frameLen > 0: copyMem(frameBlock, msg_data(q), frameLen)
    discard msg_close(q)
  if parts != 2 or frameBlock == nil:
    if frameBlock != nil: shmFree(frameBlock)
    return none(tuple[routing: string, base: Bytes, n: int])
  some((routing, frameBlock, frameLen))

proc main() =
  setStdIoUnbuffered()
  let
    root = getEnv("CINIM_STORE_ROOT", "/data")
    certs = getEnv("CINIM_CERTS", getCurrentDir() / "tests" / "certs")
    port = parseInt(getEnv("CINIM_STORE_PORT", "19750"))
    workers = max(1, parseInt(getEnv("CINIM_STORE_WORKERS", "4")))
    tmpAge = parseInt(getEnv("CINIM_STORE_TMP_AGE", "86400"))
  var token = getEnv("CINIM_STORE_TOKEN")
  if token.len == 0 and getEnv("CINIM_STORE_TOKEN_FILE").len > 0: token = readFile(getEnv("CINIM_STORE_TOKEN_FILE")).strip
  if token.len == 0:
    stderr.writeLine "store: CINIM_STORE_TOKEN (or CINIM_STORE_TOKEN_FILE) is required: a node must be told whom to trust"
    quit 2
  let syncName = getEnv("CINIM_STORE_SYNC", "full")
  case syncName
  of "full": disk.syncMode = smFull
  of "file": disk.syncMode = smFile
  of "none": disk.syncMode = smNone
  else:
    stderr.writeLine "store: CINIM_STORE_SYNC is full, file or none"
    quit 2
  signal(SIGTERM, onTerm)
  signal(SIGINT, onTerm)
  let d = openDisk(root)
  let plain = getEnv("CINIM_STORE_TRANSPORT", "curve") == "plain"
  if plain: stderr.writeLine "store: CINIM_STORE_TRANSPORT=plain: the link is NOT encrypted; use it only inside a network that is (the token is sent in the clear)"
  let secretKey = if plain: "" else: loadKeypair(certs, "store").secretKey
  let ioThreads = max(1, parseInt(getEnv("CINIM_STORE_IO_THREADS", "4")))      # CURVE is encrypted in the I/O thread of the connection (about 55 MB/s a thread)
  let conn = listenStream(port, secretKey, sendTimeoutMs = 1000, ioThreads = ioThreads, curve = not plain)
  let inq = cast[ptr UncheckedArray[ShmQueue]](allocShared0(workers * sizeof(ShmQueue)))
  let outq = cast[ptr ShmQueue](allocShared0(sizeof(ShmQueue)))
  for i in 0 ..< workers: initShmQueue(inq[i])
  initShmQueue(outq[])
  var threads = newSeq[Thread[WorkerArgs]](workers)
  for i in 0 ..< workers: createThread(threads[i], runWorker, (root, token, addr inq[i], outq))
  echo "store: ", root, " on ", port, ", ", workers, " workers"
  var lastSweep = 0.0
  var kind, n: int
  var x: string
  var buf: Bytes
  var base: pointer
  conn.socket.setsockopt(RCVTIMEO, 2.cint)
  while not stopping.load:
    var sent = 0
    while sent < 256 and outq[].popOwned(0, kind, x, buf, n, base):
      conn.sendOwned(x, base, buf, n)
      inc sent
    var got = conn.receiveOwned(sent == 0)
    var taken = 0
    while got.isSome:
      let r = got.get
      let h = decodeHead(r.base, r.n)
      if h.isSome: inq[int(uint(hash(h.get.session)) mod uint(workers))].pushOwned(msgReq, r.routing, r.base, r.base, r.n)
      else: shmFree(r.base)
      inc taken
      if taken >= 64: break
      got = conn.receiveOwned(false)
    if epochTime() - lastSweep > 3600:
      lastSweep = epochTime()
      let n = d.sweepTmp(tmpAge)
      if n > 0: echo "store: ", n, " leftovers of unfinished writes removed from tmp/"
  for i in 0 ..< workers: joinThread(threads[i])
  conn.close()
  for i in 0 ..< workers: destroy(inq[i])
  destroy(outq[])
  deallocShared(inq)
  deallocShared(outq)
  echo "store: stopped"

main()
