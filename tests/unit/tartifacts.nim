## The shim's part of the artifacts (DAT-003): patterns, the files found, the hash, and the transfer against a small server of the test's own.
import std/[unittest, os, strutils, net, json, tempfiles, locks]
import shim/artifacts

suite "DAT-003 artifact patterns":
  test "DAT-003 * stays inside a name, ** crosses directories, ? is one character":
    check globMatch("dist/*.txt", "dist/a.txt")
    check not globMatch("dist/*.txt", "dist/sub/a.txt")
    check globMatch("dist/**", "dist/sub/deeper/a.txt")
    check globMatch("dist/**/a.txt", "dist/a.txt")
    check globMatch("dist/**/a.txt", "dist/x/y/a.txt")
    check globMatch("**/a.txt", "a.txt")
    check globMatch("**/*.log", "x/y/z.log")
    check globMatch("a?c", "abc")
    check not globMatch("a?c", "a/c")
    check not globMatch("dist/*", "other/a")
    check globMatch("app", "app")
    check not globMatch("app", "app2")

  test "DAT-003 a pattern with many wildcards on a long name does not take exponential time":
    check not globMatch("*a*a*a*a*a*a*a*a*b", "a".repeat(300))
    check not globMatch("**a**a**a**a**a**b", "a".repeat(300))

suite "DAT-003 finding the files":
  test "DAT-003 the files that match, sorted, without the run directory, links or directories":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    createDir(root / "dist" / "sub")
    createDir(root / ".run")
    writeFile(root / "dist" / "b.txt", "b")
    writeFile(root / "dist" / "a.txt", "a")
    writeFile(root / "dist" / "sub" / "c.txt", "c")
    writeFile(root / ".run" / "CICD_ENV", "X=1")
    writeFile(root / "other.bin", "o")
    createSymlink(root / "other.bin", root / "dist" / "link")
    let c = collectFiles(root, @["dist/**"])
    check c.error == ""
    check c.files == @["dist/a.txt", "dist/b.txt", "dist/sub/c.txt"]
    check collectFiles(root, @["**"]).files.find(".run/CICD_ENV") < 0

  test "DAT-003 a pattern that matches nothing is an error that names it":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    writeFile(root / "a", "x")
    let c = collectFiles(root, @["a", "nothing/**"])
    check "nothing/**" in c.error

  test "DAT-003 the SHA-256 of a file is the usual one, also over several blocks":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    writeFile(root / "abc", "abc")
    check fileSha256(root / "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    writeFile(root / "big", "a".repeat(200_000))
    check fileSha256(root / "big") == "2287d207f24a941ff3b56c04c8a25ad56b63e3023207b3bb5b4ac0c9869d74be"

# a one-request server: remembers what it was sent and answers with what the test says
type ServerArgs = tuple[port: Port, answer: string, bodyBytes: int]
var received: array[2048, char]      # a fixed array: a string made in one thread and freed in another is not safe with the thread-local heaps
var receivedLen = 0
var recvLock: Lock
initLock(recvLock)

proc serveOnce(a: ServerArgs) {.thread.} =
  var srv = newSocket(buffered = false)
  srv.setSockOpt(OptReuseAddr, true)
  srv.bindAddr(a.port, "127.0.0.1")
  srv.listen()
  var cl: Socket
  srv.accept(cl)
  var head = ""
  var buf = newString(4096)
  while "\r\n\r\n" notin head:
    let n = cl.readSome(addr buf[0], buf.len, 5000)
    if n <= 0: break
    head.add buf[0 ..< n]
  let cut = head.find("\r\n\r\n")
  var got = head.len - (cut + 4)
  var want = 0
  for l in head.split("\r\n"):
    if l.toLowerAscii.startsWith("content-length:"): want = parseInt(l.split(':')[1].strip)
  while got < want:
    let n = cl.readSome(addr buf[0], buf.len, 5000)
    if n <= 0: break
    got += n
  let note = head[0 ..< cut] & " [body " & $got & "]"
  {.cast(gcsafe).}:
    withLock recvLock:
      receivedLen = min(note.len, received.len)
      for i in 0 ..< receivedLen: received[i] = note[i]
  cl.send(a.answer)
  cl.close()
  srv.close()

suite "DAT-003 the transfer":
  test "DAT-003 a PUT sends the whole file with its length and takes a 200":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    writeFile(root / "f", "x".repeat(300_000))
    var th: Thread[ServerArgs]
    createThread(th, serveOnce, (Port(18911), "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", 0))
    sleep 200
    let r = putFile("http://127.0.0.1:18911/b/k%20ey?X-Amz-Signature=abc", root / "f")
    joinThread(th)
    check r.ok and r.status == 200
    var got = ""
    withLock recvLock:
      for i in 0 ..< receivedLen: got.add received[i]
    check got.startsWith("PUT /b/k%20ey?X-Amz-Signature=abc HTTP/1.1")
    check "Content-Length: 300000" in got and got.endsWith("[body 300000]")

  test "DAT-003 a refusal is not a success":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    writeFile(root / "f", "x")
    var th: Thread[ServerArgs]
    createThread(th, serveOnce, (Port(18912), "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n", 0))
    sleep 200
    let r = putFile("http://127.0.0.1:18912/b/k", root / "f")
    joinThread(th)
    check not r.ok and r.status == 403 and "403" in r.detail

  test "DAT-003 a GET writes the file only when the size is the one core announced":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    var th: Thread[ServerArgs]
    createThread(th, serveOnce, (Port(18913), "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", 0))
    sleep 200
    let r = getFile("http://127.0.0.1:18913/b/k", root / "d" / "out.txt", 5)
    joinThread(th)
    check r.ok
    check readFile(root / "d" / "out.txt") == "hello"
    var th2: Thread[ServerArgs]
    createThread(th2, serveOnce, (Port(18914), "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", 0))
    sleep 200
    let bad = getFile("http://127.0.0.1:18914/b/k", root / "d" / "other.txt", 9)
    joinThread(th2)
    check not bad.ok and not fileExists(root / "d" / "other.txt") and not fileExists(root / "d" / "other.txt.part")

  test "DAT-003 https is refused plainly":
    let r = getFile("https://store.example/b/k", "/tmp/never", 1)
    check not r.ok and "http://" in r.detail
