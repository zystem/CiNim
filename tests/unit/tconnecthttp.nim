## common/connecthttp.nim: one request over TLS through an HTTP proxy that takes CONNECT. Nim 2.2.6's own httpclient sends `GET host:port/path` inside the tunnel (a regression: 2.2.4 sends
## `GET /path`), which a server answers with 400, so the core makes its own CONNECT. This file tests the part that reads what comes back (no sockets: the bytes are a string) and what is sent.
import std/[unittest, strutils]
import ../../src/common/connecthttp

proc wireOf(data: string): Wire =
  var pos = 0
  result.line = proc (): string =
    let e = data.find("\r\n", pos)
    if e < 0: raise newException(IOError, "closed")
    result = data[pos ..< e]
    pos = e + 2
  result.exact = proc (n: int): string =
    if pos + n > data.len: raise newException(IOError, "closed")
    result = data[pos ..< pos + n]
    pos += n
  result.rest = proc (): string =
    result = data[pos .. ^1]
    pos = data.len

suite "reading a response":
  test "the status, the headers (any case) and a body with a Content-Length":
    let r = readResponse(wireOf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCONTENT-LENGTH: 11\r\nX-Hsmgate-Retryable: false\r\n\r\n{\"a\":\"bcd\"}tail"))
    check r.code == 200 and r.body == "{\"a\":\"bcd\"}" and headerOf(r.headers, "x-hsmgate-retryable") == "false"
  test "a chunked body, with an extension, a trailer and several chunks":
    let r = readResponse(wireOf("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nTrailer-X: y\r\n\r\n"))
    check r.code == 200 and r.body == "hello world"
  test "no length and not chunked: the body is what is left until the server closes":
    let r = readResponse(wireOf("HTTP/1.0 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n400 Bad Request"))
    check r.code == 400 and r.body == "400 Bad Request"
  test "no body for 204, 304 and 1xx, whatever follows":
    check readResponse(wireOf("HTTP/1.1 204 No Content\r\n\r\nxxx")).body == ""
    check readResponse(wireOf("HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\n\r\nxxxxx")).body == ""
  test "a head alone (the answer to CONNECT: it has headers of the proxy and no body to wait for)":
    let h = readHead(wireOf("HTTP/1.0 200 Connection established\r\nProxy-agent: tinyproxy/1.11.2\r\n\r\n\x16\x03\x03"))
    check h.code == 200 and h.reason == "Connection established" and headerOf(h.headers, "Proxy-Agent") == "tinyproxy/1.11.2"
  test "what is not a response is refused, and a body that is too big is not read":
    expect ValueError: discard readResponse(wireOf("garbage\r\n\r\n"))
    expect ValueError: discard readResponse(wireOf("HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\n\r\n"))
    expect ValueError: discard readResponse(wireOf("HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n"))
    expect IOError: discard readResponse(wireOf("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\nshort"))

suite "what is sent":
  test "the request in the form a server wants inside the tunnel: /path, Host, the length, and no keep-alive":
    let q = requestText("PUT", "100.100.1.25", "8443", "/v1/transit/encrypt/k", @[("Content-Type", "application/json"), ("X-Vault-Token", "t")], "{\"a\":1}")
    check q.startsWith("PUT /v1/transit/encrypt/k HTTP/1.1\r\nHost: 100.100.1.25:8443\r\n")
    check "Content-Length: 7\r\n" in q and "Connection: close\r\n" in q and "X-Vault-Token: t\r\n" in q and q.endsWith("\r\n\r\n{\"a\":1}")
    let g = requestText("GET", "svc.example", "443", "/v1/x", @[], "")
    check g.startsWith("GET /v1/x HTTP/1.1\r\nHost: svc.example\r\n") and "Content-Length" notin g      # the default port is not written
  test "the CONNECT line names the target host:port, whatever the path":
    check connectText("100.100.1.25", "8443") == "CONNECT 100.100.1.25:8443 HTTP/1.1\r\nHost: 100.100.1.25:8443\r\n\r\n"
