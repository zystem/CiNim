## DAT-003, D-57 (docs/store.md): real store nodes (the program `build/cinim-store`, real CURVE sockets, scratch directories) and the core's mirror over them. A node round-trips every
## operation, refuses a wrong token, keeps what it was given across a restart; the mirror writes to both, passes over a node that is away or stuck, says which writes a node missed,
## and the repair copies an object from one node to the other, whole or by parts, checked by its hash. No database needed.
import std/[unittest, os, osproc, strutils, strtabs, sequtils, tables, times, options, locks, posix, streams]
import checksums/sha2
import common/zmqcurve
import core/[zstore, storagebackend]
import store/[disk, wire]

const port1 = 29861
const port2 = 29862
const token = "a-token-for-the-test-nodes"
let certs = getCurrentDir() / "tests" / "certs"

func sha(s: string): string =
  for c in secureHash(Sha_256, s): result.add toHex(ord(c), 2).toLowerAscii

if execCmd("nim c --hints:off --warnings:off -p:src --threads:on --outdir:build -o:build/cinim-store src/store/main.nim") != 0:
  quit "could not build the store node"
let binary = getCurrentDir() / "build" / "cinim-store"
let base = getTempDir() / ("tstorenet-" & $getCurrentProcessId())
removeDir(base)

proc startNode(root: string; port: int; tokenValue = token; transport = "curve"): Process =
  let env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env["CINIM_STORE_ROOT"] = root
  env["CINIM_CERTS"] = certs
  env["CINIM_STORE_PORT"] = $port
  env["CINIM_STORE_TOKEN"] = tokenValue
  env["CINIM_STORE_WORKERS"] = "3"
  env["CINIM_STORE_TRANSPORT"] = transport
  result = startProcess(binary, env = env, options = {poStdErrToStdOut})
  sleep 700

proc node(port: int; tokenValue = token; timeoutMs = 20000): ZNode =
  newNode("tcp://127.0.0.1:" & $port, loadPublicKey(certs, "store"), tokenValue, loadKeypair(certs, "client"), timeoutMs)

proc stop(p: Process) =
  p.terminate()
  discard p.waitForExit(5000)
  p.close()

var missed: seq[(string, string, string)]
var missedLock: Lock
initLock(missedLock)
proc note(key, nodeName, what: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock missedLock: missed.add (key, nodeName, what)
proc takeMissed(): seq[(string, string, string)] =
  withLock missedLock:
    result = missed
    missed = @[]

proc wait(p: Process; ms = 0) = sleep ms

let root1 = base / "n1"
let root2 = base / "n2"
var p1 = startNode(root1, port1)
var p2 = startNode(root2, port2)
let d1 = openDisk(root1)
let d2 = openDisk(root2)
let n1 = node(port1)
let n2 = node(port2)

suite "D-57 one node over ZeroMQ":
  test "the round trip of the backend's own check, and every operation on one node":
    let one = newMirror(@[n1])
    check roundTrip(one) == ""
    check one.putObject("t/r/f.txt", "hello world").ok
    check one.objectSize("t/r/f.txt").size == 11
    check one.readRange("t/r/f.txt", 6, 5).data == "world"
    check one.readRange("t/r/f.txt", 0, 100).data == "hello world"
    check n1.nodeHash("t/r/f.txt").sha256 == sha("hello world")
    check one.deleteObject("t/r/f.txt").ok
    let gone = one.objectSize("t/r/f.txt")
    check not gone.res.ok and not gone.res.retry and "no such object" in gone.res.error.toLowerAscii
    check one.deleteObject("t/r/f.txt").ok
  test "a wrong token is refused for good, and the node does nothing":
    let wrong = newMirror(@[node(port1, "not the token")])
    let r = wrong.putObject("t/r/evil", "x")
    check not r.ok and not r.retry and "token" in r.error
    check d1.objectSize("t/r/evil").res.code == "not_found"
  test "a multipart upload of 25 MB in parts of 8 MiB comes back whole, by reads of 4 MiB":
    let one = newMirror(@[n1])
    var all = ""
    for i in 0 ..< 25: all.add ('a'.int + i mod 26).char.repeat(1 shl 20)
    let up = one.createMultipart("t/r/big.bin")
    check up.res.ok
    var parts: seq[(int, string)]
    var n = 1
    var at = 0
    while at < all.len:
      let chunk = all[at ..< min(all.len, at + partSize)]
      let p = one.uploadPart("t/r/big.bin", up.uploadId, n, chunk)
      check p.res.ok and p.etag == sha(chunk)
      parts.add (n, p.etag)
      inc n
      at += partSize
    check one.completeMultipart("t/r/big.bin", up.uploadId, parts).ok
    check one.objectSize("t/r/big.bin").size == all.len
    var got = ""
    var off = 0'i64
    while off < all.len:
      let r = one.readRange("t/r/big.bin", off, readSize)
      check r.res.ok
      got.add r.data
      off += r.data.len
    check got == all
    check n1.nodeHash("t/r/big.bin").sha256 == sha(all)
  test "an upload that is aborted leaves nothing":
    let one = newMirror(@[n1])
    let up = one.createMultipart("t/r/aborted")
    discard one.uploadPart("t/r/aborted", up.uploadId, 1, "x")
    check one.abortMultipart("t/r/aborted", up.uploadId).ok
    check one.objectSize("t/r/aborted").res.ok == false
  test "a list gives the keys, with a cursor":
    let one = newMirror(@[n1])
    for i in 0 ..< 5: check one.putObject("lst/k" & $i, "x".repeat(i + 1)).ok
    let a = n1.nodeList("lst/", "", 3)
    check a.reply.ok and a.entries.len == 3 and a.next == "lst/k2"
    let b = n1.nodeList("lst/", a.next, 3)
    check b.entries.mapIt(it.key) == @["lst/k3", "lst/k4"] and b.next == ""
    check b.entries[1].size == 5
  test "a node that is stopped and started again has what it was given":
    let one = newMirror(@[n1])
    check one.putObject("keep/me", "durable").ok
    p1.stop()
    p1 = startNode(root1, port1)
    check one.readRange("keep/me", 0, 100).data == "durable"

suite "D-57 a link without CURVE":
  test "a node started with CINIM_STORE_TRANSPORT=plain answers a client without CURVE, still wants the token, and does not answer a CURVE client":
    let root3 = base / "n3"
    let p3 = startNode(root3, port1 + 100, transport = "plain")
    let d3 = openDisk(root3)
    var plainNode = newNode("tcp://127.0.0.1:" & $(port1 + 100), "", token, (publicKey: "", secretKey: ""), 20000)
    plainNode.plain = true
    let m = newMirror(@[plainNode])
    check roundTrip(m) == ""
    check m.putObject("plain/one", "no CURVE on this link").ok and d3.readRange("plain/one", 0, 100).data == "no CURVE on this link"
    var big = ""
    for i in 0 ..< 3: big.add ('a'.int + i).char.repeat(1 shl 20)
    let up = m.createMultipart("plain/big")
    let a = m.uploadPart("plain/big", up.uploadId, 1, big)
    check a.res.ok and m.completeMultipart("plain/big", up.uploadId, @[(1, a.etag)]).ok and d3.objectSize("plain/big").size == big.len
    var wrong = newNode("tcp://127.0.0.1:" & $(port1 + 100), "", "not the token", (publicKey: "", secretKey: ""), 5000)
    wrong.plain = true
    let r = newMirror(@[wrong]).putObject("plain/evil", "x")
    check not r.ok and not r.retry and "token" in r.error
    # (the connections are kept by address, so the CURVE client names the node otherwise)
    let curveClient = newMirror(@[newNode("tcp://localhost:" & $(port1 + 100), loadPublicKey(certs, "store"), token, loadKeypair(certs, "client"), 1500)])
    check not curveClient.putObject("plain/curve", "x").ok                                  # a CURVE client cannot talk to a node without CURVE
    check d3.objectSize("plain/curve").res.code == "not_found"
    p3.stop()

suite "D-57 the mirror over two nodes":
  test "a write goes to both nodes, a read from either, a delete from both; no node missed anything":
    discard takeMissed()
    let m = newMirror(@[n1, n2], 1, note)
    check m.putObject("both/a", "same on both").ok
    check d1.readRange("both/a", 0, 100).data == "same on both" and d2.readRange("both/a", 0, 100).data == "same on both"
    for i in 0 ..< 6: check m.readRange("both/a", 0, 100).data == "same on both"
    check m.deleteObject("both/a").ok
    check d1.objectSize("both/a").res.code == "not_found" and d2.objectSize("both/a").res.code == "not_found"
    check takeMissed().len == 0
  test "a multipart upload goes to both nodes":
    let m = newMirror(@[n1, n2], 1, note)
    let up = m.createMultipart("both/mp")
    check up.res.ok and up.uploadId.count('|') == 1 and "-" notin up.uploadId
    let a = m.uploadPart("both/mp", up.uploadId, 1, "AAAA")
    let b = m.uploadPart("both/mp", up.uploadId, 2, "BB")
    check m.completeMultipart("both/mp", up.uploadId, @[(1, a.etag), (2, b.etag)]).ok
    check d1.readRange("both/mp", 0, 100).data == "AAAABB" and d2.readRange("both/mp", 0, 100).data == "AAAABB"
    check takeMissed().len == 0
  test "with a node away a write still succeeds (one ack is enough) and the node that missed it is named":
    discard takeMissed()
    p2.stop()
    let m = newMirror(@[node(port1), node(port2, timeoutMs = 1500)], 1, note)
    check m.putObject("away/one", "only on the first").ok
    let miss = takeMissed()
    check miss.len == 1 and miss[0][0] == "away/one" and miss[0][2] == "copy" and miss[0][1].endsWith($port2)
    check d1.readRange("away/one", 0, 100).data == "only on the first"
    check m.readRange("away/one", 0, 100).data == "only on the first"                       # the read passes over the node that is away
    check m.deleteObject("away/one").ok
    check takeMissed().mapIt(it[2]) == @["delete"]
  test "with two acks wanted, a write with a node away fails, and says it is worth trying again":
    let strict = newMirror(@[node(port1), node(port2, timeoutMs = 1000)], 2, note)
    let r = strict.putObject("away/strict", "x")
    check not r.ok and r.retry
    discard takeMissed()
  test "by default every node must confirm: with one away a put, a delete and the start of an upload all fail and can be tried again; with both up they pass":
    discard takeMissed()
    let m = newMirror(@[node(port1), node(port2, timeoutMs = 1000)], 0, note)         # 0: every node
    check m.minAcks == 2
    let put = m.putObject("away/default", "x")
    check not put.ok and put.retry
    check not m.deleteObject("away/default").ok
    let mp = m.createMultipart("away/default-mp")
    check not mp.res.ok and mp.res.retry
    check d1.objectSize("away/default-mp").res.code == "not_found"                           # the upload begun on the live node was aborted again
    check takeMissed().len == 0                                                              # the queue is for the degraded mode only
  test "a multipart upload started with a node away is completed on the other, and the missing node is named":
    discard takeMissed()
    let m = newMirror(@[node(port1), node(port2, timeoutMs = 1000)], 1, note)
    let up = m.createMultipart("away/mp")
    check up.res.ok and up.uploadId.endsWith("|-")
    let a = m.uploadPart("away/mp", up.uploadId, 1, "part one ")
    let b = m.uploadPart("away/mp", up.uploadId, 2, "part two")
    check m.completeMultipart("away/mp", up.uploadId, @[(1, a.etag), (2, b.etag)]).ok
    check d1.readRange("away/mp", 0, 100).data == "part one part two"
    check takeMissed().mapIt(it[2]) == @["copy"]
  test "the node comes back and the repair copies what it missed, whole and by parts, checked by the hash":
    p2 = startNode(root2, port2)
    let fresh2 = node(port2)
    check d2.objectSize("away/mp").res.code == "not_found"
    check copyObject(n1, fresh2, "away/mp").ok
    check d2.readRange("away/mp", 0, 100).data == "part one part two"
    # a big one goes by parts
    var big = ""
    for i in 0 ..< 20: big.add ('A'.int + i).char.repeat(1 shl 20)
    check n1.nodePut("repair/big", big[0 ..< 7 shl 20]).ok                                  # a whole object up to 8 MiB
    let one = newMirror(@[n1])
    let up = one.createMultipart("repair/huge")
    var parts: seq[(int, string)]
    var at = 0
    var k = 1
    while at < big.len:
      let chunk = big[at ..< min(big.len, at + partSize)]
      parts.add (k, one.uploadPart("repair/huge", up.uploadId, k, chunk).etag)
      inc k
      at += partSize
    check one.completeMultipart("repair/huge", up.uploadId, parts).ok
    check copyObject(n1, fresh2, "repair/huge").ok and copyObject(n1, fresh2, "repair/big").ok
    check n2.nodeHash("repair/huge").sha256 == sha(big) and n2.nodeHash("repair/big").sha256 == sha(big[0 ..< 7 shl 20])
    check d2.objectSize("repair/huge").size == big.len
    check not copyObject(n1, fresh2, "repair/nothing").ok
  test "an object on one node only is read from it, and one on neither is `no such object` for good":
    let m = newMirror(@[n1, n2], 1, note)
    check n2.nodePut("one/side", "only on the second").ok
    for i in 0 ..< 4: check m.readRange("one/side", 0, 100).data == "only on the second"
    let r = m.readRange("one/none", 0, 10)
    check not r.res.ok and not r.res.retry and "no such object" in r.res.error.toLowerAscii
  test "a node that is stuck (not away) is given up after the timeout, and works again when it is let go":
    discard takeMissed()
    let stuck = node(port2, timeoutMs = 1200)
    let m = newMirror(@[node(port1), stuck], 1, note)
    check kill(Pid(p2.processID), SIGSTOP) == 0
    let t0 = epochTime()
    check m.putObject("stuck/one", "x").ok
    check epochTime() - t0 < 5
    check takeMissed().len == 1
    check kill(Pid(p2.processID), SIGCONT) == 0
    sleep 500
    check m.putObject("stuck/two", "y").ok
    check takeMissed().len == 0
    check d2.readRange("stuck/two", 0, 10).data == "y"
    # the request given up may still have reached the node's buffers and be run on SIGCONT: either way it is the right data, and the missed-write record is what makes it whole
    check d2.objectSize("stuck/one").res.code in ["not_found", ""]
  test "cinim-storectl puts a small and a 20 MB file on both nodes, lists, hashes, gets them back whole and removes them":
    check execCmd("nim c --hints:off --warnings:off -p:src --threads:on --outdir:build -o:build/cinim-storectl src/store/ctl.nim") == 0
    let ctl = getCurrentDir() / "build" / "cinim-storectl"
    let env = newStringTable()
    for k, v in envPairs(): env[k] = v
    env["CINIM_STORE_NODES"] = "tcp://127.0.0.1:" & $port1 & ",tcp://127.0.0.1:" & $port2
    env["CINIM_STORE_TOKEN"] = token
    env["CINIM_CERTS"] = certs
    proc run(args: varargs[string]): tuple[output: string, code: int] =
      let p = startProcess(ctl, args = @args, env = env, options = {poStdErrToStdOut})
      result.output = p.outputStream.readAll()
      result.code = p.waitForExit()
      p.close()
    createDir(base / "ctl")
    writeFile(base / "ctl" / "small.txt", "backup of the state")
    var big = newStringOfCap(20 shl 20)
    for i in 0 ..< 20 shl 20: big.add char((i * 31 + i div 997) mod 251)
    writeFile(base / "ctl" / "big.bin", big)
    check run("put", "backup/state/small", base / "ctl" / "small.txt").code == 0
    check run("put", "backup/state/big", base / "ctl" / "big.bin").code == 0
    check d1.readRange("backup/state/small", 0, 100).data == "backup of the state" and d2.readRange("backup/state/small", 0, 100).data == "backup of the state"
    check d1.objectSize("backup/state/big").size == big.len and d2.objectSize("backup/state/big").size == big.len
    let ls = run("ls", "backup/")
    check ls.code == 0 and "backup/state/big" in ls.output and "backup/state/small" in ls.output
    let h = run("hash", "backup/state/big")
    check h.output.count(sha(big)) == 2
    check run("get", "backup/state/big", base / "ctl" / "back.bin").code == 0 and readFile(base / "ctl" / "back.bin") == big
    check run("rm", "backup/state/big").code == 0 and run("rm", "backup/state/small").code == 0
    check d1.objectSize("backup/state/big").res.code == "not_found" and d2.objectSize("backup/state/small").res.code == "not_found"
    check run("get", "backup/state/nothing", base / "ctl" / "x").code == 1
    check run("stat").output.count("free of") == 2
  test "four threads write and read through one mirror, each with a connection of its own":
    let m = newMirror(@[n1, n2], 1, note)
    var threads: array[4, Thread[tuple[b: MirrorBackend, who: int]]]
    var failures = 0
    proc work(a: tuple[b: MirrorBackend, who: int]) {.thread.} =
      {.cast(gcsafe).}:
        for i in 0 ..< 25:
          let key = "thr/" & $a.who & "/" & $i
          let data = "data-" & $a.who & "-" & $i
          if not a.b.putObject(key, data).ok or a.b.readRange(key, 0, 100).data != data:
            withLock missedLock: inc failures
    for i in 0 ..< 4: createThread(threads[i], work, (m, i))
    for i in 0 ..< 4: joinThread(threads[i])
    check failures == 0
    check n1.nodeList("thr/", "", 500).entries.len == 100 and n2.nodeList("thr/", "", 500).entries.len == 100

p1.stop()
p2.stop()
removeDir(base)
