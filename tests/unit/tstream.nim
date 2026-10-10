## RUN-016 / docs/conductors.md section 12: the sockets of the push channel (a CURVE ROUTER and DEALERs) over localhost.
import std/[unittest, options, os, strutils]
import common/[stream, zmqcurve]

let certs = getCurrentDir() / "tests" / "certs"
let port = 29845

suite "RUN-016 push channel: sockets":
  let (_, coreSecret) = loadKeypair(certs, "core")
  let corePub = loadPublicKey(certs, "core")
  let clientKeys = loadKeypair(certs, "client")
  var server = listenStream(port, coreSecret)
  test "a frame from a client reaches the core with the client's routing id, and the core answers on it":
    var cl = connectStream("tcp://127.0.0.1:" & $port, corePub, clientKeys)
    check cl.sendFrame(frame("s1", "controller.report", "state-1"))
    let got = server.receiveFrom(3000)
    check got.isSome
    check got.get.frame.session == "s1" and got.get.frame.kind == "controller.report"
    check got.get.frame.payload == "state-1"
    # the core pushes without being asked
    check server.sendTo(got.get.routingId, frame("core", "controller.work", "do-this", id = 1))
    let back = cl.receive(3000)
    check back.isSome and back.get.kind == "controller.work" and back.get.payload == "do-this" and back.get.id == 1
    cl.close()
  test "two clients are told apart, and a push goes only to the one it is for":
    var a = connectStream("tcp://127.0.0.1:" & $port, corePub, clientKeys)
    var b = connectStream("tcp://127.0.0.1:" & $port, corePub, clientKeys)
    check a.sendFrame(frame("a", "ping"))
    check b.sendFrame(frame("b", "ping"))
    var ids: seq[tuple[session, rid: string]]
    for _ in 0 ..< 2:
      let g = server.receiveFrom(3000)
      check g.isSome
      ids.add (g.get.frame.session, g.get.routingId)
    check ids.len == 2 and ids[0].rid != ids[1].rid
    let toB = (if ids[0].session == "b": ids[0].rid else: ids[1].rid)
    check server.sendTo(toB, frame("core", "controller.work", "for-b", id = 1))
    check b.receive(3000).isSome
    check a.receive(300).isNone
    a.close()
    b.close()
  test "a send to a peer that is gone fails and tells us, instead of vanishing":
    var cl = connectStream("tcp://127.0.0.1:" & $port, corePub, clientKeys)
    check cl.sendFrame(frame("gone", "ping"))
    let g = server.receiveFrom(3000)
    check g.isSome
    cl.close()
    sleep 600
    check not server.sendTo(g.get.routingId, frame("core", "controller.work", "x", id = 1))
  test "a client that is not the core's cannot connect: a wrong server key gets nothing":
    var cl = connectStream("tcp://127.0.0.1:" & $port, "0000000000000000000000000000000000000000", clientKeys)
    discard cl.sendFrame(frame("evil", "ping"))
    check server.receiveFrom(800).isNone
    cl.close()
  test "the core receives nothing when nobody sends":
    check server.receiveFrom(100).isNone
  server.close()

suite "RUN-016 push channel: the frame envelope":
  test "a frame survives encoding, with empty and binary parts":
    for f in [frame("s", "ping"), frame("session-1", "controller.work", "\x00\xff payload \n", id = 7, ack = 3, re = 12),
              frame("", "x", "y", id = 0xFFFFFFFFFFFF'u64, ack = 1)]:
      let g = decodeFrame(encodeFrame(f))
      check g.isSome and g.get == f
  test "anything that is not a frame is refused, never trusted":
    check decodeFrame("").isNone
    check decodeFrame("\x02garbage").isNone
    let good = encodeFrame(frame("s", "ping", "abc"))
    check decodeFrame(good[0 ..< good.len - 1]).isNone       # cut short
    check decodeFrame(good & "x").isNone                      # trailing bytes
    var big = good
    big[big.len - 4 - 3 .. big.len - 4] = "\xff\xff\xff\xff"   # a payload length beyond the limit
    check decodeFrame(big).isNone
