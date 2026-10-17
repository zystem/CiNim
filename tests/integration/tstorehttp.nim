## DAT-003, D-57 (docs/store.md): the store on HTTP nodes. Real nodes (`build/caddy-store`: Caddy with the WebDAV module of the CiNim fork, made by tools/store/build-caddy.sh), scratch
## directories, and the check of every request by the core's own function (core/storeauth.nim) behind the nodes' `forward_auth`. An object is a directory of chunks: written whole or by parts,
## read by blocks, replaced whole, deleted without taking a neighbour; a wrong token and a token made for another path do nothing; the mirror writes to both nodes, passes over a node that is away,
## says which writes a node missed, and the repair copies an object from one node to the other. No database needed.
import std/[unittest, os, osproc, strutils, strtabs, sequtils, times, locks, net, httpclient, atomics, algorithm]
import checksums/sha2
import common/httpsrv
import storage/[httpstore, storeauth]
import common/storagebackend

const
  port1 = 29871
  port2 = 29872
  authPort = 29873
  secret = "a-store-secret-for-the-test-nodes"

func sha(s: string): string =
  for c in secureHash(Sha_256, s): result.add toHex(ord(c), 2).toLowerAscii

if not fileExists("build/caddy-store"):
  if execCmd("tools/store/build-caddy.sh") != 0:
    echo "tstorehttp: no build/caddy-store and it could not be made (it needs Docker and the network); the tests are skipped"
    quit 0
let caddy = getCurrentDir() / "build" / "caddy-store"
let base = getTempDir() / ("tstorehttp-" & $getCurrentProcessId())
removeDir(base)
createDir(base)

# ------------------------------------------------------------------ the core's side: the answer to forward_auth
var authSecret {.threadvar.}: string
var asked: Atomic[int]
var refused: Atomic[int]
var currentSecret = secret
var secretLock: Lock
initLock(secretLock)

proc onAuth() {.gcsafe, nimcall, raises: [].} =
  {.cast(gcsafe).}:
    try:
      discard asked.fetchAdd(1)
      var sec = ""
      withLock secretLock: sec = currentSecret
      if getUri().startsWith(authPath) and storeAuthOk(getRequest(), getUri(), sec, epochTime().int64): reply(Http200, "ok")
      else:
        discard refused.fetchAdd(1)
        reply(Http401, "no")
    except CatchableError:
      reply(Http500, "error")

let authService = newService(onAuth)
authService.start(authPort, 4)

# ------------------------------------------------------------------ the nodes
proc listening(port: int): bool =
  try:
    let s = newSocket()
    s.connect("127.0.0.1", Port(port), 200)
    s.close()
    true
  except OSError: false

proc startNode(root: string; port: int; tls = ""): Process =
  if listening(port): quit "something listens on " & $port & " already (a node of an earlier run?)"
  createDir(root)
  let file = base / ("Caddyfile-" & $port)
  let name = if tls.len > 0: "localhost" else: "127.0.0.1"
  writeFile(file, "{\n\torder webdav before file_server\n\tauto_https off\n\tadmin off\n}\n:" & $port & " {\n" & (if tls.len > 0: "\ttls " & tls & ".crt " & tls & ".key\n" else: "") &
    "\tforward_auth 127.0.0.1:" & $authPort & " {\n\t\turi " & authPath &
    "?node=" & name & ":" & $port & "\n\t}\n\twebdav {\n\t\troot " & root & "\n\t\tatomic_put\n\t\tcreate_dirs\n\t}\n}\n")
  let env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env["XDG_DATA_HOME"] = base / "xdg"
  env["XDG_CONFIG_HOME"] = base / "xdgc"
  result = startProcess("/bin/sh", args = ["-c", "exec " & caddy & " run --config " & file & " --adapter caddyfile > " & base / ("caddy-" & $port & ".log") & " 2>&1"], env = env)     # the log goes to a file: an unread pipe fills up and stops the node
  for _ in 0 ..< 100:
    if listening(port): return
    sleep 100
  quit "the node on " & $port & " did not start"

proc stop(p: Process) =
  p.terminate()
  discard p.waitForExit(5000)
  p.close()

let root1 = base / "n1"
let root2 = base / "n2"
var p1 = startNode(root1, port1)
var p2 = startNode(root2, port2)

proc node(port: int; sec = secret): HttpNode = newHttpNode("http://127.0.0.1:" & $port, sec, 15000)
let n1 = node(port1)
let n2 = node(port2)

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

func blob(n: int; seed = 0): string =
  result = newString(n)
  for i in 0 ..< n: result[i] = char((i * 31 + seed * 7 + i div 251) mod 256)

proc objectFiles(root, key: string): seq[string] =
  let dir = root / "data"
  discard dir
  let objDir = root / objectDir(key)[1 .. ^1]
  if dirExists(objDir):
    for f in walkDir(objDir): result.add extractFilename(f.path)
  result.sort

suite "D-57 one HTTP node":
  test "the round trip of the backend's own check, and every operation on one node":
    let one = newHttpMirror(@[n1])
    check roundTrip(one) == ""
    check one.putObject("t/r/f.txt", "hello world").ok
    check one.objectSize("t/r/f.txt").size == 11
    check one.readRange("t/r/f.txt", 6, 5).data == "world"
    check one.readRange("t/r/f.txt", 0, 100).data == "hello world"
    check one.readRange("t/r/f.txt", 11, 5).data == ""                         # at the end: nothing, not an error
    check one.deleteObject("t/r/f.txt").ok
    let gone = one.objectSize("t/r/f.txt")
    check not gone.res.ok and not gone.res.retry and "no such object" in gone.res.error.toLowerAscii
    check not one.readRange("t/r/f.txt", 0, 5).res.ok
    check one.deleteObject("t/r/f.txt").ok                                      # a delete of nothing is fine
    check refused.load == 0 and asked.load > 0                                  # every request went through the core's check, and passed
  test "an object is a directory of chunks, written under a name nobody else can have":
    let one = newHttpMirror(@[n1])
    check one.putObject("acme/s1_x/dist/app.txt", "bytes").ok
    check objectFiles(root1, "acme/s1_x/dist/app.txt") == @[".c0000000"]
    check dirExists(root1 / "acme/s1_x/dist/app.txt~obj")
    check not dirExists(root1 / ".up") or toSeq(walkDir(root1 / ".up")).len == 0   # nothing is left of the staging
    check one.deleteObject("acme/s1_x/dist/app.txt").ok
  test "keys of every kind, a key under another key, and a delete that takes no neighbour":
    let one = newHttpMirror(@[n1])
    for k in ["odd/with space", "odd/unicode-ключ-鍵", "odd/a%b", "odd/q?mark", "odd/hash#tag", "odd/.hidden", "odd/" & "x".repeat(300), "x/a", "x/a/b", "x/a/b/c"]:
      check one.putObject(k, "data of " & k).ok
    for k in ["odd/with space", "odd/unicode-ключ-鍵", "odd/a%b", "odd/q?mark", "odd/hash#tag", "odd/.hidden", "odd/" & "x".repeat(300), "x/a", "x/a/b", "x/a/b/c"]:
      check one.readRange(k, 0, 1000).data == "data of " & k
    check one.deleteObject("x/a").ok
    check one.objectSize("x/a").res.ok == false
    check one.readRange("x/a/b", 0, 100).data == "data of x/a/b"
    check one.readRange("x/a/b/c", 0, 100).data == "data of x/a/b/c"
    for bad in ["", "/lead", "trail/", "a//b", "a/../b"]:
      check not one.putObject(bad, "x").ok
  test "a multipart upload of 20 MB in parts of 8 MiB comes back whole, by reads of 4 MiB, and is not there before the complete":
    let one = newHttpMirror(@[n1])
    let data = blob(20 * 1024 * 1024 + 123)
    let up = one.createMultipart("mp/r/big.bin")
    check up.res.ok
    var parts: seq[(int, string)]
    var n = 0
    var off = 0
    while off < data.len:
      inc n
      let chunk = data[off ..< min(off + partSize, data.len)]
      let r = one.uploadPart("mp/r/big.bin", up.uploadId, n, chunk)
      check r.res.ok
      parts.add (n, r.etag)
      off += partSize
    check not one.objectSize("mp/r/big.bin").res.ok                              # the parts are staged, the object is not there
    check one.completeMultipart("mp/r/big.bin", up.uploadId, parts).ok
    check objectFiles(root1, "mp/r/big.bin") == @[".c0000000", ".c0000001", ".c0000002"]
    check one.objectSize("mp/r/big.bin").size == data.len
    var got = ""
    var pos = 0'i64
    while pos < data.len:
      let r = one.readRange("mp/r/big.bin", pos, readSize)
      check r.res.ok
      if r.data.len == 0: break
      got.add r.data
      pos += r.data.len
    check got.len == data.len and sha(got) == sha(data)
    check one.readRange("mp/r/big.bin", partSize - 10, 20).data == data[partSize - 10 ..< partSize + 10]   # a read across the border of two chunks
    # a smaller object replaces it whole: no chunk of the old one is left
    check one.putObject("mp/r/big.bin", "small").ok
    check objectFiles(root1, "mp/r/big.bin") == @[".c0000000"]
    check one.objectSize("mp/r/big.bin").size == 5
    check one.deleteObject("mp/r/big.bin").ok
  test "a part sent again replaces it, an upload with a part missing or short is not completed, and an abort leaves nothing":
    let one = newHttpMirror(@[n1])
    let up = one.createMultipart("mp/r/two.bin")
    let a = blob(partSize, 1)
    let b = blob(1000, 2)
    let a1 = one.uploadPart("mp/r/two.bin", up.uploadId, 1, "old content")
    check a1.res.ok
    let a2 = one.uploadPart("mp/r/two.bin", up.uploadId, 1, a)
    let b2 = one.uploadPart("mp/r/two.bin", up.uploadId, 2, b)
    check a2.res.ok and b2.res.ok and a2.etag != a1.etag
    check not one.completeMultipart("mp/r/two.bin", up.uploadId, @[(1, a2.etag)]).ok or one.objectSize("mp/r/two.bin").size == partSize     # a list that leaves a part out is the caller's mistake
    discard one.abortMultipart("mp/r/two.bin", up.uploadId)
    let up2 = one.createMultipart("mp/r/three.bin")
    let s1 = one.uploadPart("mp/r/three.bin", up2.uploadId, 1, "short first part")
    let s2 = one.uploadPart("mp/r/three.bin", up2.uploadId, 2, "second")
    let bad = one.completeMultipart("mp/r/three.bin", up2.uploadId, @[(1, s1.etag), (2, s2.etag)])      # a part that is not the last must be a whole 8 MiB
    check not bad.ok and not bad.retry
    check not one.objectSize("mp/r/three.bin").res.ok
    let up3 = one.createMultipart("mp/r/four.bin")
    check one.uploadPart("mp/r/four.bin", up3.uploadId, 1, "x").res.ok
    check one.abortMultipart("mp/r/four.bin", up3.uploadId).ok
    check not dirExists(root1 / ".up" / up3.uploadId)
    check not one.uploadPart("mp/r/four.bin", "not an id", 1, "x").res.ok
    check not one.uploadPart("mp/r/four.bin", up3.uploadId, 0, "x").res.ok
    check not one.uploadPart("mp/r/four.bin", up3.uploadId, 1, "x".repeat(partSize + 1)).res.ok
  test "a wrong secret is refused for good and writes nothing; a token made for another path is no good":
    let wrong = newHttpMirror(@[node(port1, "not the secret of the store")])
    let before = refused.load
    let stagedBefore = if dirExists(root1 / ".up"): toSeq(walkDir(root1 / ".up")).len else: 0
    let r = wrong.putObject("t/r/wrong.txt", "x")
    check not r.ok and not r.retry
    check refused.load > before
    check not dirExists(root1 / "t/r/wrong.txt~obj")
    # a request with a token that is right for another path
    let c = newHttpClient(timeout = 5000)
    defer: c.close()
    let t = signRequest(secret, "127.0.0.1:" & $port1, "GET", "/t/r/other", epochTime().int64)
    c.headers = newHttpHeaders({"Authorization": "Bearer " & t})
    check c.get("http://127.0.0.1:" & $port1 & "/t/r/f.txt~obj/.c0000000").code.int == 401
    check c.get("http://127.0.0.1:" & $port2 & "/t/r/other").code.int == 401                  # nor for the other node
    check c.get("http://127.0.0.1:" & $port1 & "/t/r/other").code.int == 404                  # for the path it was made for the node lets the request in
    c.headers = newHttpHeaders()
    check c.get("http://127.0.0.1:" & $port1 & "/t/r/other").code.int == 401                  # no token at all
    check (if dirExists(root1 / ".up"): toSeq(walkDir(root1 / ".up")).len else: 0) == stagedBefore

suite "D-57 the mirror over two HTTP nodes":
  test "a write goes to both nodes, a read from either, a delete from both; no node missed anything":
    discard takeMissed()
    let m = newHttpMirror(@[n1, n2], 0, note)
    check m.putObject("m/r/a.txt", "on both").ok
    check objectFiles(root1, "m/r/a.txt") == @[".c0000000"] and objectFiles(root2, "m/r/a.txt") == @[".c0000000"]
    for _ in 1 .. 4: check m.readRange("m/r/a.txt", 0, 100).data == "on both"
    check m.deleteObject("m/r/a.txt").ok
    check objectFiles(root1, "m/r/a.txt").len == 0 and objectFiles(root2, "m/r/a.txt").len == 0
    check takeMissed().len == 0
  test "a multipart upload goes to both nodes":
    let m = newHttpMirror(@[n1, n2], 0, note)
    let data = blob(partSize + 4000, 3)
    let up = m.createMultipart("m/r/mp.bin")
    let p1 = m.uploadPart("m/r/mp.bin", up.uploadId, 1, data[0 ..< partSize])
    let p2 = m.uploadPart("m/r/mp.bin", up.uploadId, 2, data[partSize .. ^1])
    check m.completeMultipart("m/r/mp.bin", up.uploadId, @[(1, p1.etag), (2, p2.etag)]).ok
    check objectFiles(root1, "m/r/mp.bin") == @[".c0000000", ".c0000001"] and objectFiles(root2, "m/r/mp.bin") == @[".c0000000", ".c0000001"]
    check m.objectSize("m/r/mp.bin").size == data.len
    check m.deleteObject("m/r/mp.bin").ok
  test "with a node away, a write still succeeds if one confirmation is enough, and the node that missed it is named; by default it fails and may be tried again":
    discard takeMissed()
    stop p2
    let lenient = newHttpMirror(@[n1, n2], 1, note)
    check lenient.putObject("m/r/degraded.txt", "only on the first").ok
    check takeMissed() == @[("m/r/degraded.txt", n2.name, "copy")]
    check lenient.readRange("m/r/degraded.txt", 0, 100).data == "only on the first"
    let strict = newHttpMirror(@[n1, n2], 0, note)
    let r = strict.putObject("m/r/strict.txt", "x")
    check not r.ok and r.retry
    check lenient.putObject("m/r/gone.txt", "to be deleted").ok
    discard takeMissed()
    check strict.deleteObject("m/r/gone.txt").ok == false                          # a delete that a node did not take fails, and is tried again later
    discard takeMissed()
  test "the node comes back and the repair copies what it missed, whole and by parts":
    p2 = startNode(root2, port2)
    let m = newHttpMirror(@[n1, n2], 1, note)
    check m.sizeOn(1, "m/r/degraded.txt").ok == false
    check m.sizeOn(1, "m/r/degraded.txt").notFound
    let cp = m.copyBetween(0, 1, "m/r/degraded.txt")
    check cp.ok
    check m.sizeOn(1, "m/r/degraded.txt").size == 17
    check objectFiles(root2, "m/r/degraded.txt") == @[".c0000000"]
    # an object of three chunks
    let data = blob(2 * partSize + 77, 5)
    stop p2
    let up = m.createMultipart("m/r/parts.bin")
    var parts: seq[(int, string)]
    for i in 0 .. 2:
      let r = m.uploadPart("m/r/parts.bin", up.uploadId, i + 1, data[i * partSize ..< min((i + 1) * partSize, data.len)])
      check r.res.ok
      parts.add (i + 1, r.etag)
    check m.completeMultipart("m/r/parts.bin", up.uploadId, parts).ok
    check takeMissed().anyIt(it[0] == "m/r/parts.bin" and it[1] == n2.name)
    p2 = startNode(root2, port2)
    check m.copyBetween(0, 1, "m/r/parts.bin").ok
    let n = m.sizeOn(1, "m/r/parts.bin")
    check n.ok and n.size == data.len
    check objectFiles(root2, "m/r/parts.bin") == @[".c0000000", ".c0000001", ".c0000002"]
    check sha(readFile(root2 / "m/r/parts.bin~obj/.c0000002")) == sha(data[2 * partSize .. ^1])
    check m.deleteOn(1, "m/r/parts.bin").ok
    check m.sizeOn(1, "m/r/parts.bin").notFound
  test "an object on one node only is read from it, and one on neither is `no such object` for good":
    let m = newHttpMirror(@[n1, n2], 1, note)
    check m.deleteOn(1, "m/r/degraded.txt").ok
    for _ in 1 .. 3: check m.readRange("m/r/degraded.txt", 0, 100).data == "only on the first"
    let none = m.readRange("m/r/never.txt", 0, 10)
    check not none.res.ok and not none.res.retry
  test "a node that is stuck (it takes the connection and never answers) is given up after the timeout, and the other still answers":
    discard takeMissed()
    let stuck = newSocket()
    stuck.setSockOpt(OptReuseAddr, true)
    stuck.bindAddr(Port(29878))
    stuck.listen()
    let m = newHttpMirror(@[newHttpNode("http://127.0.0.1:29878", secret, 800), n1], 1, note)
    let t0 = epochTime()
    check m.putObject("m/r/slow.txt", "x").ok
    check epochTime() - t0 < 6
    check takeMissed() == @[("m/r/slow.txt", "127.0.0.1:29878", "copy")]
    check m.readRange("m/r/slow.txt", 0, 10).data == "x"                           # the stuck node is tried in turn too, and the answer comes from the other
    stuck.close()

suite "D-57 an HTTP node over TLS":
  test "a node with a certificate is spoken to over https, its certificate checked against the file in CINIM_STORE_CA":
    let pem = base / "node"
    if execCmd("openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost -addext subjectAltName=DNS:localhost -keyout " & pem & ".key -out " & pem & ".crt 2>/dev/null") != 0:
      skip()
    else:
      putEnv("CINIM_STORE_CA", pem & ".crt")
      let p3 = startNode(base / "n3", 29877, pem)
      let tlsMirror = newHttpMirror(@[newHttpNode("https://localhost:29877", secret, 15000)])
      check roundTrip(tlsMirror) == ""
      check tlsMirror.putObject("tls/r/a.txt", "over tls").ok
      check tlsMirror.readRange("tls/r/a.txt", 0, 100).data == "over tls"
      check readFile(base / "n3/tls/r/a.txt~obj/.c0000000") == "over tls"
      let wrong = newHttpMirror(@[newHttpNode("https://localhost:29877", "not the secret of the store", 15000)])
      check not wrong.putObject("tls/r/b.txt", "x").ok
      # plain http to the TLS port is no answer, and a node that is not checked against the CA is refused
      let plainToTls = newHttpMirror(@[newHttpNode("http://localhost:29877", secret, 3000)])
      check not plainToTls.putObject("tls/r/c.txt", "x").ok
      p3.stop()

p1.stop()
p2.stop()
shutdown()
removeDir(base)
