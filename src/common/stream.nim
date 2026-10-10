## The sockets of the push channel (docs/conductors.md section 12): a CURVE ROUTER for the core and a CURVE DEALER for a client.
## The client opens the connection and the core never dials; both sides send at any moment. A frame is one Protobuf `StreamFrame`
## (proto/cicd/internal/v1/stream.proto) in one ZeroMQ message; a ROUTER prepends the peer's routing id, which changes at every
## reconnect, so the core identifies a peer by the `session` in its frames and keeps the routing id only as the address of its last frame.
##
## Heartbeats are ZeroMQ's own (ZMTP): a peer that disappears is noticed and its connection closed; the client's DEALER then connects again by
## itself, and the first frame it sends tells the core to ask for its state (`resync`). `ROUTER_MANDATORY` makes a send to a routing id that is
## gone or has a full queue fail (we are told) instead of being dropped silently.
import std/options
import zmqcurve

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

proc encodeFrame*(f: StreamFrame): string =
  doAssert f.session.len <= 0xffff and f.kind.len <= 0xffff
  result = newStringOfCap(34 + f.session.len + f.kind.len + f.payload.len)
  result.add char(frameVersion)
  result.putU64 f.id
  result.putU64 f.ack
  result.putU64 f.re
  result.add char(f.session.len shr 8); result.add char(f.session.len and 0xff); result.add f.session
  result.add char(f.kind.len shr 8); result.add char(f.kind.len and 0xff); result.add f.kind
  for i in countdown(3, 0): result.add char((f.payload.len shr (i * 8)) and 0xff)
  result.add f.payload
  if f.key.len > 0:
    doAssert f.key.len <= 0xffff
    result.add char(f.key.len shr 8); result.add char(f.key.len and 0xff); result.add f.key

proc decodeFrame*(s: string): Option[StreamFrame] =
  ## none for anything that is not a frame of this version (a stray or damaged message is dropped, never trusted)
  if s.len < 1 + 8 + 8 + 8 + 2 + 2 + 4 or ord(s[0]) != int(frameVersion): return none(StreamFrame)
  var f: StreamFrame
  f.id = getU64(s, 1)
  f.ack = getU64(s, 9)
  f.re = getU64(s, 17)
  var at = 25
  template take(n: int): string =
    if n < 0 or at + n > s.len: return none(StreamFrame)
    let part = s[at ..< at + n]
    at += n
    part
  var n = (ord(s[at]) shl 8) or ord(s[at + 1]); at += 2
  f.session = take(n)
  if at + 2 > s.len: return none(StreamFrame)
  n = (ord(s[at]) shl 8) or ord(s[at + 1]); at += 2
  f.kind = take(n)
  if at + 4 > s.len: return none(StreamFrame)
  var pl = 0
  for i in 0 ..< 4: pl = (pl shl 8) or ord(s[at + i])
  at += 4
  if pl > maxPayload: return none(StreamFrame)
  f.payload = take(pl)
  if at != s.len:
    if at + 2 > s.len: return none(StreamFrame)
    let kl = (ord(s[at]) shl 8) or ord(s[at + 1]); at += 2
    f.key = take(kl)
    if at != s.len: return none(StreamFrame)
  some(f)

proc frame*(session, kind: string; payload = ""; id = 0'u64; ack = 0'u64; re = 0'u64; key = ""): StreamFrame =
  StreamFrame(session: session, kind: kind, id: id, ack: ack, re: re, payload: payload, key: key)

proc listenStream*(port: int; secretKey: string; sendTimeoutMs = 200): ZConnection =
  ## the core's side: a ROUTER that anyone with the shared client key can connect to
  doAssert hasCurve(), "libzmq was not built with CURVE (libsodium) support"
  result = listen("tcp://0.0.0.0:" & $port, ROUTER) do (s: ZSocket) -> void:
    s.setCurveServer(secretKey)
    s.setsockopt(ROUTER_MANDATORY, 1)
    s.setsockopt(HEARTBEAT_IVL, heartbeatIntervalMs.cint)
    s.setsockopt(HEARTBEAT_TIMEOUT, heartbeatTimeoutMs.cint)
    s.setsockopt(HEARTBEAT_TTL, heartbeatTimeoutMs.cint)
    s.setsockopt(SNDTIMEO, sendTimeoutMs.cint)

proc connectStream*(address, serverPublicKey: string; client: CurveKeypair; sendTimeoutMs = 2000): ZConnection =
  ## a client's side: a DEALER that connects (and reconnects) by itself
  doAssert hasCurve(), "libzmq was not built with CURVE (libsodium) support"
  result = connect(address, DEALER) do (s: ZSocket) -> void:
    s.setCurveClient(serverPublicKey, client.publicKey, client.secretKey)
    s.setsockopt(HEARTBEAT_IVL, heartbeatIntervalMs.cint)
    s.setsockopt(HEARTBEAT_TIMEOUT, heartbeatTimeoutMs.cint)
    s.setsockopt(RECONNECT_IVL, 500.cint)
    s.setsockopt(RECONNECT_IVL_MAX, 5000.cint)
    s.setsockopt(SNDTIMEO, sendTimeoutMs.cint)

proc sendFrame*(c: ZConnection; f: StreamFrame): bool =
  ## a client sends to the core; false if the frame could not be queued
  try:
    c.send(encodeFrame(f))
    true
  except CatchableError: false

proc sendRawTo*(c: ZConnection; routingId, bytes: string): bool =
  ## the core sends an encoded frame to the peer last heard at `routingId`
  try:
    c.sendAll(routingId, bytes)
    true
  except CatchableError: false

proc sendTo*(c: ZConnection; routingId: string; f: StreamFrame): bool =
  ## the core sends to the peer last heard at `routingId`; false if that peer is gone or its queue is full (the frame stays unacknowledged
  ## and goes out again with the next contact)
  try:
    c.sendAll(routingId, encodeFrame(f))
    true
  except CatchableError: false

proc receiveRaw*(c: ZConnection; timeoutMs: int): Option[tuple[routingId, bytes: string]] =
  ## the core receives one message: the routing id and the bytes of the frame, not decoded; none after `timeoutMs`, or for a message of another shape
  let first = c.waitForReceive(timeoutMs)
  if not first.msgAvailable: return none(tuple[routingId, bytes: string])
  var parts = @[first.msg]
  var more = first.moreAvailable
  while more:
    let nxt = c.waitForReceive(1000)
    if not nxt.msgAvailable: break
    parts.add nxt.msg
    more = nxt.moreAvailable
  if parts.len != 2: return none(tuple[routingId, bytes: string])
  some((parts[0], parts[1]))

proc receiveFrom*(c: ZConnection; timeoutMs: int): Option[FrameIn] =
  ## the core receives: the routing id and the frame of one message; none after `timeoutMs`, or if the message was not a frame
  let raw = c.receiveRaw(timeoutMs)
  if raw.isNone: return none(FrameIn)
  let f = decodeFrame(raw.get.bytes)
  if f.isNone: return none(FrameIn)
  some((raw.get.routingId, f.get))

proc receive*(c: ZConnection; timeoutMs: int): Option[StreamFrame] =
  ## a client receives one frame; none after `timeoutMs`
  let r = c.waitForReceive(timeoutMs)
  if not r.msgAvailable: return none(StreamFrame)
  decodeFrame(r.msg)
