## The HTTP server of the services (common/httpsrv.nim): requests that follow requests with a body are not dropped. A thread of the server keeps one receive buffer from request
## to request; GuildenStern looked for the length of a body in all of it, and found the old header of an earlier POST behind the end of a shorter GET, and closed the connection
## (see the header of common/httpsrv.nim). And a request that is slow keeps its connection whatever the others do meanwhile (the queue of the dispatcher, the same header). No rqlite is needed.
import std/[unittest, httpclient, strutils, os, net, atomics]
import common/httpsrv
import ../support/freeport

const port = 29862
requireFreePorts("thttp", [port])      # a port that something holds is another process: stop, do not talk to it (tests/support/freeport.nim)

proc onRequest() {.gcsafe, nimcall, raises: [].} =
  {.cast(gcsafe).}:
    try:
      let n = if isMethod("POST") or isMethod("PUT"): getBody().len else: 0
      if getUri().startsWith("/slow"): sleep 1500
      reply(Http200, "ok " & $n)
    except CatchableError:
      reply(Http500, "error")

suite "the HTTP server keeps serving after requests with a body":
  let s = newService(onRequest)
  s.start(port, 8)
  sleep 300
  let base = "http://127.0.0.1:" & $port


  var lastError = ""                 ## what the last failed request said: a timeout and a reset connection are not the same fault
  proc request(m: HttpMethod; path, body: string): int =
    let c = newHttpClient(timeout = 3000)
    defer: c.close()
    try: c.request(base & path, httpMethod = m, body = body).code.int
    except CatchableError as e:
      lastError = $e.name & ": " & e.msg
      -1

  test "a thousand GETs after two hundred POSTs and PUTs with bodies of different sizes all get an answer":
    # one request in 1200 was dropped once in the pipeline's Pod (2026-11-18, run of cd3518a, three test jobs at once): 0 of 37 runs on a quiet workstation and under full load. The failures are
    # told with their number and what the client said, so that a second one says whether it was a timeout (a slow node) or a closed connection (the library).
    var dropped: seq[string]
    for round in 1 .. 200:
      let m = if round mod 2 == 0: HttpPost else: HttpPut
      if request(m, "/some/long/path/that/makes/the/request/longer/" & $round, "x".repeat(10 + round mod 7 * 40)) != 200: dropped.add "body request " & $round & ": " & lastError
    for i in 1 .. 1000:
      if request(HttpGet, "/h", "") != 200: dropped.add "GET " & $i & ": " & lastError
    if dropped.len > 0: echo "  dropped: ", dropped
    check dropped.len == 0
  test "the length of the body is the one the request says, also when an earlier request had a longer one":
    check request(HttpPost, "/a", "y".repeat(5000)) == 200
    let c = newHttpClient(timeout = 3000)
    defer: c.close()
    check c.request(base & "/b", httpMethod = HttpPost, body = "abc").body == "ok 3"
    check c.request(base & "/b", httpMethod = HttpPost, body = "").body == "ok 0"
  test "a header written in other case is read all the same":
    let c = newHttpClient(timeout = 3000, headers = newHttpHeaders({"CONTENT-LENGTH": "4"}))
    defer: c.close()
    check c.request(base & "/c", httpMethod = HttpPost, body = "abcd").body == "ok 4"
  test "a request slower than four hundred others keeps its connection: the next request on it is answered":
    # GuildenStern 9.0.2 hands the events to its workers through a queue of QueueSize places (200 unless -d:QueueSize says more) that it fills again from the start; a worker reads its place
    # once more when its handler returns, and after a lap of the queue the place holds another connection: the worker restores the reading of that one, and the connection of the slow
    # request is never read again (its next request waits until the client gives up). config.nims makes the queue 20 000 places, which this test would not pass without.
    proc ask(c: Socket; path: string; timeoutMs: int): string =
      c.send("GET " & path & " HTTP/1.1\r\nHost: x\r\n\r\n")
      var len = -1
      while true:
        let line = c.recvLine(timeout = timeoutMs)
        if line.len == 0: raise newException(IOError, "closed")
        if line == "\r\n": break
        if line.toLowerAscii.startsWith("content-length:"): len = parseInt(line.split(':')[1].strip)
      if len > 0: result = c.recv(len, timeoutMs)
    var answered {.global.}: Atomic[int]
    proc quick(n: int) {.thread.} =
      {.cast(gcsafe).}:
        var c = newSocket()
        try:
          c.connect("127.0.0.1", Port(port))
          for i in 0 ..< n:
            if c.ask("/q" & $i, 5000) == "ok 0": answered.atomicInc
        except CatchableError: discard
        c.close()
    var slow = newSocket()
    slow.connect("127.0.0.1", Port(port))
    check slow.ask("/first", 3000) == "ok 0"
    slow.send("GET /slow HTTP/1.1\r\nHost: x\r\n\r\n")           # its handler sleeps from here on
    sleep 150
    var th: array[4, Thread[int]]
    for t in th.mitems: createThread(t, quick, 100)
    joinThreads(th)
    check answered.load == 400
    var len = -1
    while true:
      let line = slow.recvLine(timeout = 10000)
      if line == "\r\n": break
      if line.toLowerAscii.startsWith("content-length:"): len = parseInt(line.split(':')[1].strip)
    check slow.recv(len, 3000) == "ok 0"                          # the answer of the slow request
    let again = try: slow.ask("/again", 3000) except CatchableError: "no answer"
    check again == "ok 0"
    slow.close()
  shutdown()
