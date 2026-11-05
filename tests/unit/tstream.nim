## RUN-016 / docs/conductors.md section 12: the push channel over gRPC with mutual TLS (a core that listens and clients that keep a connection) on localhost.
import std/[unittest, options, os, strutils, osproc]
import common/[stream]
import ../support/testcerts

let certs = testCerts()
let other = block:
  let d = getTempDir() / ("cinim-tstream-other-" & $getCurrentProcessId())
  createDir d
  if certs.len > 0 and execCmd("sh " & quoteShell(getCurrentDir() / "tools" / "grpc" / "gen_tls.sh") & " " & quoteShell(d) & " 2 >/dev/null 2>&1") == 0: d else: ""

proc addr0(s: StreamServer): string = "tcp://127.0.0.1:" & $s.port

proc waitConnected(c: StreamClient; ms = 5000): bool =
  var waited = 0
  while not c.connected and waited < ms:
    sleep 20
    waited += 20
  c.connected

suite "RUN-016 push channel: connections":
  setup:
    if certs.len == 0: skip()
  test "a frame from a client reaches the core with the client's routing id, and the core answers on it":
    let server = listenStream(0, certs)
    defer: server.close()
    let cl = connectStream(server.addr0, certs)
    defer: cl.close()
    check cl.sendFrame(frame("s1", "controller.report", "state-1"))
    let got = server.receiveFrom(5000)
    check got.isSome
    check got.get.frame.session == "s1" and got.get.frame.kind == "controller.report"
    check got.get.frame.payload == "state-1"
    # the core pushes without being asked
    check server.sendTo(got.get.routingId, frame("core", "controller.work", "do-this", id = 1))
    let back = cl.receive(5000)
    check back.isSome and back.get.kind == "controller.work" and back.get.payload == "do-this" and back.get.id == 1
  test "two clients are told apart, and a push goes only to the one it is for":
    let server = listenStream(0, certs)
    defer: server.close()
    let a = connectStream(server.addr0, certs)
    defer: a.close()
    let b = connectStream(server.addr0, certs)
    defer: b.close()
    check a.sendFrame(frame("a", "ping"))
    check b.sendFrame(frame("b", "ping"))
    var ids: seq[tuple[session, rid: string]]
    for _ in 0 ..< 2:
      let g = server.receiveFrom(5000)
      check g.isSome
      ids.add (g.get.frame.session, g.get.routingId)
    check ids.len == 2 and ids[0].rid != ids[1].rid
    let toB = (if ids[0].session == "b": ids[0].rid else: ids[1].rid)
    check server.sendTo(toB, frame("core", "controller.work", "for-b", id = 1))
    check b.receive(5000).isSome
    check a.receive(300).isNone
  test "a send to a peer that is gone fails and tells us, instead of vanishing":
    let server = listenStream(0, certs)
    defer: server.close()
    let cl = connectStream(server.addr0, certs)
    check cl.sendFrame(frame("gone", "ping"))
    let g = server.receiveFrom(5000)
    check g.isSome
    check server.sendTo(g.get.routingId, frame("core", "controller.work", "x", id = 1))
    cl.close()
    var failed = false
    for _ in 0 ..< 50:
      sleep 100
      if not server.sendTo(g.get.routingId, frame("core", "controller.work", "x", id = 2)):
        failed = true
        break
    check failed
    check not server.sendRawTo("never-heard", "x")
  test "a client whose certificate is of another CA cannot connect":
    if other.len == 0: skip()
    let server = listenStream(0, certs)
    defer: server.close()
    let mixed = other & "-mixed"
    createDir(mixed / "tls")
    copyFile(certs / "tls" / "ca.pem", mixed / "tls" / "ca.pem")           # it trusts the right core
    copyFile(other / "tls" / "client.pem", mixed / "tls" / "client.pem")   # but its own certificate is from another CA
    copyFile(other / "tls" / "client.key", mixed / "tls" / "client.key")
    defer: removeDir mixed
    let cl = connectStream(server.addr0, mixed)
    defer: cl.close()
    discard cl.sendFrame(frame("evil", "ping"))
    check server.receiveFrom(1500).isNone
    check not cl.connected
  test "a client that does not trust the core's CA cannot connect either":
    if other.len == 0: skip()
    let server = listenStream(0, certs)
    defer: server.close()
    let cl = connectStream(server.addr0, other)
    defer: cl.close()
    discard cl.sendFrame(frame("evil", "ping"))
    check server.receiveFrom(1500).isNone
  test "the core receives nothing when nobody sends":
    let server = listenStream(0, certs)
    defer: server.close()
    check server.receiveFrom(100).isNone
  test "frames sent before the client is connected wait, and arrive in order":
    let server = listenStream(0, certs)
    defer: server.close()
    let cl = connectStream(server.addr0, certs)
    defer: cl.close()
    for i in 0 ..< 200: check cl.sendFrame(frame("s", "controller.report", $i, id = uint64(i + 1)))
    for i in 0 ..< 200:
      let g = server.receiveFrom(5000)
      check g.isSome and g.get.frame.payload == $i
  test "a client connects to a core that comes up later, and again to one that was restarted":
    let first = listenStream(0, certs)
    let port = first.port
    let cl = connectStream("127.0.0.1:" & $port, certs)
    defer: cl.close()
    check cl.waitConnected()
    first.close()
    sleep 300
    check cl.sendFrame(frame("s", "controller.report", "after-restart"))
    let second = listenStream(port, certs)
    defer: second.close()
    var got: Option[FrameIn]
    for _ in 0 ..< 60:
      got = second.receiveFrom(250)
      if got.isSome: break
      discard cl.sendFrame(frame("s", "ping"))          # a frame that was in flight when the core went is lost, as ever; the next one arrives
    check got.isSome
    check cl.waitConnected()
  test "a big frame and many small ones both ways":
    let server = listenStream(0, certs)
    defer: server.close()
    let cl = connectStream(server.addr0, certs)
    defer: cl.close()
    let big = 'x'.repeat(3_000_000)
    check cl.sendFrame(frame("s", "conductor.call", big, id = 1))
    let g = server.receiveFrom(10000)
    check g.isSome and g.get.frame.payload == big
    check server.sendTo(g.get.routingId, frame("core", "conductor.lease", big, id = 1))
    let back = cl.receive(10000)
    check back.isSome and back.get.payload == big
    for i in 0 ..< 500: check server.sendTo(g.get.routingId, frame("core", "ping", $i, id = uint64(i + 2)))
    for i in 0 ..< 500:
      let r = cl.receive(5000)
      check r.isSome and r.get.payload == $i

suite "RUN-016 push channel: the frame envelope":
  test "a frame survives encoding, with empty and binary parts":
    for f in [frame("s", "ping"), frame("session-1", "controller.work", "\x00\xff payload \n", id = 7, ack = 3, re = 12),
              frame("", "x", "y", id = 0xFFFFFFFFFFFF'u64, ack = 1)]:
      let g = decodeFrame(encodeFrame(f))
      check g.isSome and g.get == f
  test "the spreading key is optional: a frame without one is the same bytes as before, a frame with one carries it":
    let plain = encodeFrame(frame("s", "ping", "abc", id = 1))
    check decodeFrame(plain).get.key == ""
    let keyed = frame("s", "controller.report", "abc", id = 1, key = "cinim-001-acme")
    let back = decodeFrame(encodeFrame(keyed))
    check back.isSome and back.get == keyed and back.get.key == "cinim-001-acme"
    check encodeFrame(keyed).startsWith(plain[0 ..< plain.len - 3 - 0][0 .. 24])      # the same head
    check decodeFrame(encodeFrame(keyed) & "x").isNone                                # nothing after the key
  test "anything that is not a frame is refused, never trusted":
    check decodeFrame("").isNone
    check decodeFrame("\x02garbage").isNone
    let good = encodeFrame(frame("s", "ping", "abc"))
    check decodeFrame(good[0 ..< good.len - 1]).isNone       # cut short
    check decodeFrame(good & "x").isNone                      # trailing bytes
    var big = good
    big[big.len - 4 - 3 .. big.len - 4] = "\xff\xff\xff\xff"   # a payload length beyond the limit
    check decodeFrame(big).isNone

  test "a frame is read in place: the payload stays where it is, and the head agrees with decodeFrame":
    let f = frame("session-1", "store.req", "payload \x00 bytes", id = 7, ack = 3, re = 5, key = "ns")
    var s = encodeFrame(f)
    let h = decodeHead(cast[ptr UncheckedArray[char]](addr s[0]), s.len)
    check h.isSome
    check h.get.id == 7 and h.get.ack == 3 and h.get.re == 5 and h.get.session == "session-1" and h.get.kind == "store.req" and h.get.key == "ns"
    check s[h.get.payloadAt ..< h.get.payloadAt + h.get.payloadLen] == f.payload
    check decodeFrame(s).get == f
    # the header and the payload written one after the other are the frame
    let plain = frame("s", "k", "abc", id = 1, re = 2)
    check frameHeader(plain, 3) & "abc" == encodeFrame(plain)
    var cut = s[0 ..< s.len - 1]
    check decodeHead(cast[ptr UncheckedArray[char]](addr cut[0]), cut.len).isNone

if other.len > 0: removeDir other
