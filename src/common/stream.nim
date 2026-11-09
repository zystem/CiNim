## The push channel (docs/conductors.md section 12) over gRPC with mutual TLS (docs/shim-grpc.md): the core listens, a client keeps a connection to it, and both sides send at any moment.
## A frame is one Protobuf `StreamFrame` (proto/cicd/internal/v1/stream.proto) in one gRPC message. A client opens two calls on one HTTP/2 connection, each used by one thread in one
## direction: `/cicd.Stream/Down` (server streaming: the core pushes frames) and `/cicd.Stream/Up` (client streaming: the client sends frames). Both carry the metadata `cinim-peer`, a
## token the client makes at every connect, which is the routing id of the peer: it changes at every reconnect, so the core identifies a peer by the `session` in its frames and keeps
## the routing id only as the address of its last frame. The core never dials.
##
## Dead peers are noticed by HTTP/2 PINGs (a keepalive of 3 s and a timeout of 10 s, the heartbeats ZeroMQ had before) and the client connects again by itself with a growing pause; the first
## frame it sends tells the core to ask for its state (`resync`). A send to a routing id that is gone or has a full queue fails (we are told) instead of being dropped silently.
##
## Between threads frames go through `ShmQueue` (common/shmq.nim), never as Nim strings: the gRPC workers that read and write are threads of nimgrpc.
import std/[options, locks, atomics, os, sysrand, strutils]
import nimgrpc
import corechannel, shmq

## The envelope of one frame (the payload is a Protobuf message of the kind named in `kind`; the envelope itself is plain bytes so that the
## modules that carry their own generated message types need no second copy of the generator's output):
##   u8 version (1) | u64 id | u64 ack | u64 re | u16 len + session | u16 len + kind | u32 len + payload [| u16 len + key]     (integers big-endian)
## `key` (optional, left out when empty) is what the core spreads its workers by: a controller puts its namespace there, so that all the frames of an
## organisation go to one worker, in order; a frame without one is spread by its session.
## kinds in use: "controller.report" (client -> core, a PollRequest), "controller.work" (core -> client, a PollResponse), "ping" (either way,
## empty, carries `ack`), "resync" (core -> client: "I do not know you, send your state again"), "bye" (core -> client: refused or ended, the
## payload is the reason). `id` is the number of a numbered frame among the sender's (0: not numbered, needs no acknowledgement); `ack` is the
## highest numbered frame of the peer that the sender has applied; `re` is, in an answer, the `id` of the request it answers (a client numbers
## its reports for that, they are not resent), 0 in a frame that answers nothing, a push.
type
  StreamFrame* = object
    session*, kind*, payload*, key*: string
    id*, ack*, re*: uint64
  FrameIn* = tuple[routingId: string, frame: StreamFrame]

const
  frameVersion = 1'u8
  heartbeatIntervalMs = 3000
  heartbeatTimeoutMs = 10000
  maxPayload = 64 * 1024 * 1024

proc putU64(s: var string; v: uint64) =
  for i in countdown(7, 0): s.add char((v shr (i * 8)) and 0xff)

proc getU64(s: string; at: int): uint64 =
  for i in 0 ..< 8: result = (result shl 8) or uint64(ord(s[at + i]))

proc frameHeader*(f: StreamFrame; payloadLen: int): string =
  ## everything of a frame up to its payload (the length of the payload included); a caller that has the payload in a buffer of its own writes this before it
  doAssert f.session.len <= 0xffff and f.kind.len <= 0xffff
  result = newStringOfCap(34 + f.session.len + f.kind.len)
  result.add char(frameVersion)
  result.putU64 f.id
  result.putU64 f.ack
  result.putU64 f.re
  result.add char(f.session.len shr 8); result.add char(f.session.len and 0xff); result.add f.session
  result.add char(f.kind.len shr 8); result.add char(f.kind.len and 0xff); result.add f.kind
  for i in countdown(3, 0): result.add char((payloadLen shr (i * 8)) and 0xff)

proc encodeFrame*(f: StreamFrame): string =
  result = frameHeader(f, f.payload.len)
  result.add f.payload
  if f.key.len > 0:
    doAssert f.key.len <= 0xffff
    result.add char(f.key.len shr 8); result.add char(f.key.len and 0xff); result.add f.key

type FrameHead* = object
  ## a frame read in place: the payload is `payloadLen` bytes at `payloadAt` of the buffer, not copied
  id*, ack*, re*: uint64
  session*, kind*, key*: string
  payloadAt*, payloadLen*: int

proc decodeHead*(p: ptr UncheckedArray[char]; len: int): Option[FrameHead] =
  ## none for anything that is not a frame of this version (a stray or damaged message is dropped, never trusted)
  if len < 1 + 8 + 8 + 8 + 2 + 2 + 4 or ord(p[0]) != int(frameVersion): return none(FrameHead)
  var f: FrameHead
  var s = newString(len.min(25))
  copyMem(addr s[0], p, s.len)
  f.id = getU64(s, 1)
  f.ack = getU64(s, 9)
  f.re = getU64(s, 17)
  var at = 25
  template take(n: int): string =
    if n < 0 or at + n > len: return none(FrameHead)
    var part = newString(n)
    if n > 0: copyMem(addr part[0], addr p[at], n)
    at += n
    part
  var n = (ord(p[at]) shl 8) or ord(p[at + 1]); at += 2
  f.session = take(n)
  if at + 2 > len: return none(FrameHead)
  n = (ord(p[at]) shl 8) or ord(p[at + 1]); at += 2
  f.kind = take(n)
  if at + 4 > len: return none(FrameHead)
  var pl = 0
  for i in 0 ..< 4: pl = (pl shl 8) or ord(p[at + i])
  at += 4
  if pl > maxPayload or at + pl > len: return none(FrameHead)
  f.payloadAt = at
  f.payloadLen = pl
  at += pl
  if at != len:
    if at + 2 > len: return none(FrameHead)
    let kl = (ord(p[at]) shl 8) or ord(p[at + 1]); at += 2
    f.key = take(kl)
    if at != len: return none(FrameHead)
  some(f)

proc decodeFrame*(s: string): Option[StreamFrame] =
  ## none for anything that is not a frame of this version (a stray or damaged message is dropped, never trusted)
  let h = decodeHead(cast[ptr UncheckedArray[char]](if s.len > 0: unsafeAddr s[0] else: nil), s.len)
  if h.isNone: return none(StreamFrame)
  let x = h.get
  some(StreamFrame(id: x.id, ack: x.ack, re: x.re, session: x.session, kind: x.kind, key: x.key, payload: s[x.payloadAt ..< x.payloadAt + x.payloadLen]))

proc frame*(session, kind: string; payload = ""; id = 0'u64; ack = 0'u64; re = 0'u64; key = ""): StreamFrame =
  StreamFrame(session: session, kind: kind, id: id, ack: ack, re: re, payload: payload, key: key)

# ------------------------------------------------------------------ transport

const
  upMethod* = "/cicd.Stream/Up"
  downMethod* = "/cicd.Stream/Down"
  peerKey = "cinim-peer"
  maxMessageBytes = maxPayload + 64 * 1024     ## a frame and its envelope
  peerQueueCap = 4096                          ## frames waiting for one peer: past it a send fails
  inboxHigh = 100_000                          ## frames read and not yet taken by the core: past it the readers wait, and the senders with them (flow control)
  keepalive = Keepalive(timeMs: heartbeatIntervalMs, timeoutMs: heartbeatTimeoutMs, withoutCalls: true)

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

proc newToken(): string =
  var raw: array[16, byte]
  discard urandom(raw)
  for b in raw: result.add toHex(int(b), 2).toLowerAscii

# ---- the core's side

type
  PeerSlot = object
    inUse: bool
    idLen: int
    id: array[32, char]
    q: ShmQueue                      ## frames for the Down call of this peer

  ServerState = object
    lock: Lock
    inbox: ShmQueue                  ## (kind 0, routing id, frame bytes) from the Up calls
    slots: ptr UncheckedArray[PeerSlot]
    nslots: int
    closing: Atomic[bool]

  StreamServer* = ref object
    st: ptr ServerState
    srv: GrpcServer

proc idStr(s: PeerSlot): string =
  result = newString(s.idLen)
  for i in 0 ..< s.idLen: result[i] = s.id[i]

proc attach(st: ptr ServerState; peer: string): ptr PeerSlot =
  ## a slot for the Down call of `peer`; nil if the id is in use or the table is full
  acquire(st.lock)
  defer: release(st.lock)
  var free = -1
  for i in 0 ..< st.nslots:
    if st.slots[i].inUse:
      if st.slots[i].idStr == peer: return nil
    elif free < 0: free = i
  if free < 0: return nil
  let sl = addr st.slots[free]
  sl.inUse = true
  sl.idLen = peer.len
  for i in 0 ..< peer.len: sl.id[i] = peer[i]
  initShmQueue(sl.q)
  sl

proc detach(st: ptr ServerState; sl: ptr PeerSlot) =
  acquire(st.lock)
  sl.inUse = false
  destroy(sl.q)
  release(st.lock)

proc peerOf(ctx: ServerContext): string {.raises: [CatchableError].} =
  result = ctx.metadata.get(peerKey)
  if result.len == 0 or result.len > 32 or not result.allCharsInSet(HexDigits):
    raise newGrpcError(scInvalidArgument, "the metadata " & peerKey & " is a token of 1 to 32 hexadecimal digits")

proc downHandler(ctx: var ServerContext; call: var ServerCall; userData: pointer) {.nimcall, gcsafe, raises: [CatchableError].} =
  ## the core pushes: frames queued for this peer go down the call until it ends
  let st = cast[ptr ServerState](userData)
  let peer = peerOf(ctx)
  var hello: seq[byte]
  discard call.recv(hello)                        # the one request message, empty
  let sl = attach(st, peer)
  if sl == nil: raise newGrpcError(scAlreadyExists, "the peer id is in use or the table of peers is full")
  try:
    call.send(newSeq[byte]())                     # an empty message: the headers go out, and the client knows it is registered before it sends anything
    var kind: int
    var a, b: string
    while not st.closing.load:
      ctx.checkCancelled()
      if sl.q.pop(500, kind, a, b): call.send(toBytes(b))
  finally:
    detach(st, sl)

proc upHandler(ctx: var ServerContext; call: var ServerCall; userData: pointer) {.nimcall, gcsafe, raises: [CatchableError].} =
  ## the peer sends: every frame goes to the inbox with the peer's id
  let st = cast[ptr ServerState](userData)
  let peer = peerOf(ctx)
  var msg: seq[byte]
  while not st.closing.load and call.recv(msg):
    while st.inbox.len > inboxHigh and not st.closing.load:
      ctx.checkCancelled()
      sleep 5
    st.inbox.push(0, peer, toStr(msg))

proc listenStream*(port: int; certs: string; maxPeers = 2048): StreamServer =
  ## the core's side: anyone with a certificate of the CA in `<certs>/tls` may connect. Every peer holds two calls (two workers of nimgrpc) for as long as it is connected.
  let st = cast[ptr ServerState](allocShared0(sizeof(ServerState)))
  initLock(st.lock)
  initShmQueue(st.inbox)
  st.nslots = maxPeers
  st.slots = cast[ptr UncheckedArray[PeerSlot]](allocShared0(maxPeers * sizeof(PeerSlot)))
  let srv = newGrpcServer(port = port, address = "0.0.0.0", maxWorkers = maxPeers * 2 + 8, maxMessage = maxMessageBytes, tls = serverTls(certs), keepalive = keepalive)
  srv.addStreamingRaw(downMethod, downHandler, st)
  srv.addStreamingRaw(upMethod, upHandler, st)
  srv.start()
  StreamServer(st: st, srv: srv)

proc port*(s: StreamServer): int = s.srv.port

proc close*(s: StreamServer) =
  s.st.closing.store(true)
  s.srv.stop(graceMs = 1000)
  destroy(s.st.inbox)
  deinitLock(s.st.lock)
  deallocShared(s.st.slots)
  deallocShared(s.st)

proc sendRawTo*(s: StreamServer; routingId, bytes: string): bool =
  ## the core sends an encoded frame to the peer last heard at `routingId`; false if that peer is gone or its queue is full (the frame stays unacknowledged and goes out again with the next contact)
  let st = s.st
  acquire(st.lock)
  defer: release(st.lock)
  for i in 0 ..< st.nslots:
    if st.slots[i].inUse and st.slots[i].idStr == routingId:
      if st.slots[i].q.len >= peerQueueCap: return false
      st.slots[i].q.push(0, "", bytes)
      return true
  false

proc sendTo*(s: StreamServer; routingId: string; f: StreamFrame): bool =
  s.sendRawTo(routingId, encodeFrame(f))

proc receiveRaw*(s: StreamServer; timeoutMs: int): Option[tuple[routingId, bytes: string]] =
  ## the core receives one message: the routing id and the bytes of the frame, not decoded; none after `timeoutMs`
  var kind: int
  var a, b: string
  if s.st.inbox.pop(timeoutMs, kind, a, b): some((a, b)) else: none(tuple[routingId, bytes: string])

proc receiveFrom*(s: StreamServer; timeoutMs: int): Option[FrameIn] =
  ## the core receives: the routing id and the frame of one message; none after `timeoutMs`, or if the message was not a frame
  let raw = s.receiveRaw(timeoutMs)
  if raw.isNone: return none(FrameIn)
  let f = decodeFrame(raw.get.bytes)
  if f.isNone: return none(FrameIn)
  some((raw.get.routingId, f.get))

# ---- a client's side

type
  ClientState = object
    inq, outq: ShmQueue              ## frames from the core, frames for the core
    stop: Atomic[bool]
    connected: Atomic[bool]
    port: int
    host: array[256, char]
    certs: array[512, char]

  StreamClient* = ref object
    st: ptr ClientState
    thread: Thread[ptr ClientState]

  ReaderArgs = tuple[st: ptr ClientState, call: ptr ClientCall, broken: ptr Atomic[bool]]

proc cstr(a: openArray[char]): string =
  for c in a:
    if c == '\0': break
    result.add c

proc readLoop(a: ReaderArgs) {.thread.} =
  {.cast(gcsafe).}:
    try:
      var msg: seq[byte]
      while not a.st.stop.load and a.call[].recv(msg):
        a.st.inq.push(0, "", toStr(msg))
    except CatchableError: discard
    a.broken[].store(true)

proc clientMain(st: ptr ClientState) {.thread.} =
  {.cast(gcsafe).}:
    let host = cstr(st.host)
    let certs = cstr(st.certs)
    var pause = 500
    var pending = ""
    var havePending = false
    while not st.stop.load:
      var broken: Atomic[bool]
      var reader: Thread[ReaderArgs]
      var readerOn = false
      var ch: GrpcChannel
      var chOpen = false
      var down: ClientCall                 # the reader's call: made in the try below, used by the reader thread until it is joined
      try:
        ch = dial(host, st.port, clientTls(certs), serverName = coreServerName, keepalive = keepalive, connectTimeoutMs = 5000)
        chOpen = true
        let token = newToken()
        down = ch.newCall(downMethod, @[(peerKey, token)], maxMessage = maxMessageBytes)
        down.send(newSeq[byte]())
        down.closeSend()
        var first: seq[byte]
        if not down.recv(first): raise newGrpcError(scUnavailable, "the core ended the call")      # the empty message: this peer is registered
        var up = ch.newCall(upMethod, @[(peerKey, token)], maxMessage = maxMessageBytes)
        st.connected.store(true)
        pause = 500
        createThread(reader, readLoop, (st, addr down, addr broken))
        readerOn = true
        var kind: int
        var a, b: string
        while not st.stop.load and not broken.load:
          if not havePending and st.outq.pop(200, kind, a, b):
            pending = b
            havePending = true
          if havePending:
            up.send(toBytes(pending))
            havePending = false
        try: up.closeSend() except CatchableError: discard
      except CatchableError: discard
      st.connected.store(false)
      # The reader thread is in `down.recv` on the channel, and `ch.close()` frees the channel: closing it first let the reader's failing call touch freed memory (found with AddressSanitizer
      # in tconductorhub; the corrupted heap showed as a cycle in the allocator's free list, a thread that spun for ever holding the lock of a connection, and a server that accepted nobody).
      # nimgrpc 0.3.0 has the order for it: `shutdown` closes the connections and frees nothing (the calls of any thread fail at once, from any thread), the reader is joined, then `close` frees.
      if readerOn:
        try: ch.shutdown() except CatchableError: discard
        joinThread(reader)
      if chOpen: (try: ch.close() except CatchableError: discard)
      if not st.stop.load:
        var waited = 0
        while waited < pause and not st.stop.load:
          sleep 100
          waited += 100
        pause = min(pause * 2, 5000)

proc connectStream*(address, certs: string): StreamClient =
  ## a client's side: connects (and reconnects) by itself; frames sent while it is not connected wait in a queue. `address` is `tcp://host:port` or `host:port`; the keys are `<certs>/tls/{ca.pem,client.pem,client.key}`.
  let (host, port) = parseTarget(address)
  doAssert host.len < 256 and certs.len < 512
  let st = cast[ptr ClientState](allocShared0(sizeof(ClientState)))
  initShmQueue(st.inq)
  initShmQueue(st.outq)
  st.port = port
  for i in 0 ..< host.len: st.host[i] = host[i]
  for i in 0 ..< certs.len: st.certs[i] = certs[i]
  result = StreamClient(st: st)
  createThread(result.thread, clientMain, st)

proc connected*(c: StreamClient): bool = c.st.connected.load

proc sendFrame*(c: StreamClient; f: StreamFrame): bool =
  ## a client sends to the core; false if the frame could not be queued
  if c.st.outq.len >= peerQueueCap: return false
  c.st.outq.push(0, "", encodeFrame(f))
  true

proc receive*(c: StreamClient; timeoutMs: int): Option[StreamFrame] =
  ## a client receives one frame; none after `timeoutMs`
  var kind: int
  var a, b: string
  if not c.st.inq.pop(timeoutMs, kind, a, b): return none(StreamFrame)
  decodeFrame(b)

proc close*(c: StreamClient) =
  c.st.stop.store(true)
  joinThread(c.thread)
  destroy(c.st.inq)
  destroy(c.st.outq)
  deallocShared(c.st)
