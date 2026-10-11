## The HTTP server of the services (common/httpsrv.nim): requests that follow requests with a body are not dropped. A thread of the server keeps one receive buffer from request
## to request; GuildenStern looked for the length of a body in all of it, and found the old header of an earlier POST behind the end of a shorter GET, and closed the connection
## (see the header of common/httpsrv.nim). No rqlite is needed.
import std/[unittest, httpclient, strutils, os]
import common/httpsrv

const port = 29862

proc onRequest() {.gcsafe, nimcall, raises: [].} =
  {.cast(gcsafe).}:
    try:
      let n = if isMethod("POST") or isMethod("PUT"): getBody().len else: 0
      reply(Http200, "ok " & $n)
    except CatchableError:
      reply(Http500, "error")

suite "the HTTP server keeps serving after requests with a body":
  let s = newService(onRequest)
  s.start(port, 8)
  sleep 300
  let base = "http://127.0.0.1:" & $port


  proc request(m: HttpMethod; path, body: string): int =
    let c = newHttpClient(timeout = 3000)
    defer: c.close()
    try: c.request(base & path, httpMethod = m, body = body).code.int
    except CatchableError: -1

  test "a thousand GETs after two hundred POSTs and PUTs with bodies of different sizes all get an answer":
    var dropped = 0
    for round in 1 .. 200:
      let m = if round mod 2 == 0: HttpPost else: HttpPut
      if request(m, "/some/long/path/that/makes/the/request/longer/" & $round, "x".repeat(10 + round mod 7 * 40)) != 200: inc dropped
    for i in 1 .. 1000:
      if request(HttpGet, "/h", "") != 200: inc dropped
    check dropped == 0
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
  shutdown()
