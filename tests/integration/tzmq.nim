## Spike 2 (transport candidate): the nimble `zmq` wrapper with CURVE under Nim 2.2.4 ORC (ADR 0009).
## Run with LD_LIBRARY_PATH pointing at a libzmq built with libsodium.
import std/[unittest, os, strutils, atomics, times]
import zmq/bindings

proc curveKeypair(pub, sec: cstring): cint {.cdecl, importc: "zmq_curve_keypair", dynlib: zmqdll.}
proc zmqHas(cap: cstring): cint {.cdecl, importc: "zmq_has", dynlib: zmqdll.}

type
  Sock = object      # RAII: a C resource wrapped with =destroy (E-003)
    s: ZSocket
  Key = array[41, char]

proc `=destroy`(x: Sock) =
  if x.s != nil:
    var l = 0.cint
    discard setsockopt(x.s, LINGER, addr l, sizeof l)
    discard close(x.s)
proc `=copy`(a: var Sock; b: Sock) {.error.}

proc newSock(ctx: ZContext; typ: cint): Sock =
  result.s = socket(ctx, typ)
  var t = 1500.cint
  discard setsockopt(result.s, RCVTIMEO, addr t, sizeof t)
  discard setsockopt(result.s, SNDTIMEO, addr t, sizeof t)
  var l = 0.cint
  discard setsockopt(result.s, LINGER, addr l, sizeof l)

proc opt(s: Sock; o: ZSockOptions; k: Key) = discard setsockopt(s.s, o, unsafeAddr k[0], 40)
proc keyStr(k: Key): string = $cast[cstring](unsafeAddr k[0])

var
  ctx: ZContext
  serverPub, serverSec, clientPub, clientSec, roguePub, rogueSec: Key
  stop: Atomic[bool]
  port = 19400

# ZAP handler: accepts only the allowed client public key (Z85 form)
proc zapLoop(a: ptr Key) {.thread.} =
  let h = newSock(ctx, ZMQ_REP)
  var t = 200.cint
  discard setsockopt(h.s, RCVTIMEO, addr t, sizeof t)
  discard bindAddr(h.s, "inproc://zeromq.zap.01")
  while not stop.load:
    var f: array[7, array[64, char]]
    var n: array[7, int]
    var i = 0
    while true:
      n[i] = recv(h.s, addr f[i][0], 63, 0).int
      if n[i] < 0: break
      var more = 0.cint; var ml = sizeof more
      discard getsockopt(h.s, RCVMORE, addr more, addr ml)
      inc i
      if more == 0 or i == 7: break
    if i == 0 or n[0] < 0: continue
    var ok = false
    if i >= 7 and n[5] == 5 and n[6] == 32:
      var z: array[41, char]
      discard z85_encode(cast[cstring](addr z[0]), cast[ptr uint8](addr f[6][0]), 32)
      ok = $cast[cstring](addr z[0]) == $cast[cstring](addr a[][0])
    let code = if ok: "200" else: "400"
    discard send(h.s, cstring("1.0"), 3, ZMQ_SNDMORE)
    discard send(h.s, addr f[1][0], n[1], ZMQ_SNDMORE)
    discard send(h.s, cstring(code), 3, ZMQ_SNDMORE)
    discard send(h.s, cstring("OK"), 2, ZMQ_SNDMORE)
    discard send(h.s, cstring(""), 0, ZMQ_SNDMORE)
    discard send(h.s, cstring(""), 0, 0)

proc echoLoop(unused: int) {.thread.} =
  let r = newSock(ctx, ZMQ_REP)
  var t = 200.cint
  discard setsockopt(r.s, RCVTIMEO, addr t, sizeof t)
  var one = 1.cint
  discard setsockopt(r.s, CURVE_SERVER, addr one, sizeof one)
  r.opt(CURVE_SECRETKEY, serverSec)
  discard setsockopt(r.s, ZAP_DOMAIN, cstring("global"), 6)
  discard bindAddr(r.s, cstring("tcp://127.0.0.1:" & $port))
  while not stop.load:
    var b: array[64, char]
    let n = recv(r.s, addr b[0], 64, 0)
    if n < 0: continue
    if n == 1 and b[0] == 'R':
      let s = $(parseInt(readFile("/proc/self/statm").splitWhitespace()[1]) * 4096)
      discard send(r.s, cstring(s), s.len, 0)
    else:
      discard send(r.s, addr b[0], n, 0)

proc client(pub, sec, srv: Key; plain = false; timeoutMs = 1500): Sock =
  result = newSock(ctx, ZMQ_REQ)
  var t = timeoutMs.cint
  discard setsockopt(result.s, RCVTIMEO, addr t, sizeof t)
  if not plain:
    result.opt(CURVE_SERVERKEY, srv); result.opt(CURVE_PUBLICKEY, pub); result.opt(CURVE_SECRETKEY, sec)
  discard connect(result.s, cstring("tcp://127.0.0.1:" & $port))

proc request(c: Sock; m: string): string =
  if send(c.s, cstring(m), m.len, 0) < 0: return ""
  var b: array[64, char]
  let n = recv(c.s, addr b[0], 63, 0)
  if n < 0: return ""
  result = newString(min(n.int, 63))
  copyMem(addr result[0], addr b[0], result.len)

proc rssNow(): int = parseInt(readFile("/proc/self/statm").splitWhitespace()[1]) * 4096

suite "transport candidate: nimble zmq + CURVE (ADR 0009)":
  var zapT: Thread[ptr Key]
  var echoT: Thread[int]
  ctx = ctx_new()
  check curveKeypair(cast[cstring](addr serverPub[0]), cast[cstring](addr serverSec[0])) == 0
  discard curveKeypair(cast[cstring](addr clientPub[0]), cast[cstring](addr clientSec[0]))
  discard curveKeypair(cast[cstring](addr roguePub[0]), cast[cstring](addr rogueSec[0]))
  createThread(zapT, zapLoop, addr clientPub)
  createThread(echoT, echoLoop, 0)
  sleep 300

  test "the library loads and was built with CURVE":
    check zmqHas("curve") == 1

  test "CURVE: allowed client is served; plain, unknown-key and wrong-server-key clients are rejected":
    check client(clientPub, clientSec, serverPub, timeoutMs = 3000).request("hi") == "hi"
    check client(clientPub, clientSec, serverPub, plain = true).request("x") == ""
    check client(roguePub, rogueSec, serverPub).request("x") == ""
    check client(clientPub, clientSec, roguePub).request("x") == ""

  test "2000 request/reply round trips are correct":
    let c = client(clientPub, clientSec, serverPub)
    var ok = 0
    let t0 = epochTime()
    for i in 0 ..< 2000:
      if c.request("m" & $i) == "m" & $i: inc ok
    echo "  METRIC req_per_s = ", int(2000.0 / (epochTime() - t0))
    check ok == 2000

  test "E-003 connect/close cycles: Nim heap and process RSS stay flat":
    proc cycle() =
      let c = client(clientPub, clientSec, serverPub, timeoutMs = 3000)
      discard c.request("x")
    for _ in 0 ..< 200: cycle()   # warm-up
    let r0 = rssNow()
    let h0 = getOccupiedMem()
    for _ in 0 ..< 3000: cycle()
    let perConn = (rssNow() - r0) div 3000
    echo "  METRIC rss_bytes_per_connection = ", perConn
    echo "  METRIC nim_heap_growth_bytes = ", getOccupiedMem() - h0
    when not defined(sanitize): check perConn < 64   # ASan quarantine distorts RSS; LSan is the check there
    check getOccupiedMem() - h0 < 4096

  test "shutdown is clean":
    stop.store(true)
    joinThread(echoT); joinThread(zapT)
    check ctx_term(ctx) == 0
