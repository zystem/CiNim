## One HTTPS request through an HTTP proxy that takes CONNECT (tinyproxy, Squid), made here and not by std/httpclient: Nim 2.2.6's `generateHeaders` writes the request inside the tunnel as
## `GET host:port/path` (it strips the scheme and keeps the rest of the absolute URI) where 2.2.4 wrote `GET /path`, and a server answers that with 400. The TLS runs from the core to the
## service through the tunnel, as it does with a direct connection; the proxy sees the address and the bytes. What is here: the request as text, the reading of a response from a wire of
## three functions (so that it can be tested with a string), and the call itself (a socket, CONNECT, the TLS handshake, the request, the response; one request, then the connection closes).
import std/[net, strutils, uri]

type
  Wire* = object
    line*: proc (): string {.closure, gcsafe.}              ## the next line without its end; raises when the peer has closed
    exact*: proc (n: int): string {.closure, gcsafe.}       ## exactly n bytes
    rest*: proc (): string {.closure, gcsafe.}              ## everything until the peer closes

  Head* = tuple[code: int, reason: string, headers: seq[(string, string)]]
  Response* = tuple[code: int, headers: seq[(string, string)], body: string]

const maxBody = 4 * 1024 * 1024

func headerOf*(headers: seq[(string, string)]; name: string): string =
  for (k, v) in headers:
    if k.toLowerAscii == name.toLowerAscii: return v

proc readHead*(w: Wire): Head =
  let status = w.line().split(' ', 2)
  if status.len < 2 or not status[0].startsWith("HTTP/"): raise newException(ValueError, "not an HTTP response")
  result.code = try: parseInt(status[1]) except ValueError: raise newException(ValueError, "not an HTTP response")
  result.reason = if status.len > 2: status[2] else: ""
  while true:
    let l = w.line()
    if l.len == 0: break
    let c = l.find(':')
    if c > 0: result.headers.add (l[0 ..< c].strip, l[c + 1 .. ^1].strip)
    if result.headers.len > 100: raise newException(ValueError, "too many headers")

proc readBody*(w: Wire; head: Head): string =
  if head.code < 200 or head.code in [204, 304]: return ""
  if "chunked" in headerOf(head.headers, "transfer-encoding").toLowerAscii:
    while true:
      let sizeText = w.line().split(';')[0].strip
      let n = try: parseHexInt(sizeText) except ValueError: raise newException(ValueError, "bad chunk size")
      if n == 0:
        while w.line().len > 0: discard             # the trailer, if any
        break
      if result.len + n > maxBody: raise newException(ValueError, "the body is too big")
      result.add w.exact(n)
      discard w.line()                              # the end of the chunk
  elif headerOf(head.headers, "content-length").len > 0:
    let n = try: parseInt(headerOf(head.headers, "content-length")) except ValueError: raise newException(ValueError, "bad Content-Length")
    if n < 0 or n > maxBody: raise newException(ValueError, "the body is too big")
    if n > 0: result = w.exact(n)
  else:
    result = w.rest()
    if result.len > maxBody: raise newException(ValueError, "the body is too big")

proc readResponse*(w: Wire): Response =
  let h = readHead(w)
  (h.code, h.headers, readBody(w, h))

func hostPort(host, port: string): string = (if port.len > 0: host & ":" & port else: host)

func connectText*(host, port: string): string =
  let t = hostPort(host, port)
  "CONNECT " & t & " HTTP/1.1\r\nHost: " & t & "\r\n\r\n"

func requestText*(meth, host, port, path: string; headers: seq[(string, string)]; body: string): string =
  ## the request as a server wants it inside the tunnel: the path (not the whole address), a Host, the length of the body, and the end of the connection after the answer
  result = meth & " " & (if path.startsWith("/"): path else: "/" & path) & " HTTP/1.1\r\nHost: " & hostPort(host, (if port in ["", "443"]: "" else: port)) & "\r\n"
  for (k, v) in headers: result.add k & ": " & v & "\r\n"
  if body.len > 0: result.add "Content-Length: " & $body.len & "\r\n"
  result.add "Connection: close\r\n\r\n"
  result.add body

proc wireOf(sock: Socket; timeoutMs: int): Wire =
  result.line = proc (): string =
    # recvLine: a full line without its end; "\r\L" alone for an empty line; "" when the peer has closed
    let l = sock.recvLine(timeoutMs)
    if l.len == 0: raise newException(IOError, "the connection was closed")
    result = if l == "\r\L": "" else: l
  result.exact = proc (n: int): string =
    result = newString(n)
    var got = 0
    while got < n:
      var piece = newString(n - got)
      let k = sock.recv(piece, n - got, timeoutMs)
      if k <= 0: raise newException(IOError, "the connection was closed")
      for i in 0 ..< k: result[got + i] = piece[i]
      got += k
  result.rest = proc (): string =
    while true:
      var b = newString(1)
      let k = try: sock.recv(b, 1, timeoutMs) except OSError, TimeoutError: 0
      if k <= 0: break
      result.add b[0]
      if result.len > maxBody: break

when defined(ssl):
  proc viaConnect*(proxyUrl, host, port, meth, path: string; headers: seq[(string, string)]; body: string; ctx: SslContext; timeoutMs: int): Response =
    ## the request to https://host:port/path through the proxy at proxyUrl (http://proxyhost:proxyport): a CONNECT, the TLS handshake of the service's certificate (checked for `host`)
    ## and the client's, the request, the answer. Raises when the proxy does not answer or says no, or the handshake or the reading fails; the caller says what it was.
    let p = parseUri(proxyUrl)
    if p.hostname.len == 0: raise newException(ValueError, "the proxy address has no host: " & proxyUrl)
    let sock = newSocket()
    defer: sock.close()
    sock.connect(p.hostname, Port(if p.port.len > 0: parseInt(p.port) else: 3128), timeoutMs)
    let target = if port.len > 0: port else: "443"
    sock.send(connectText(host, target))
    let head = readHead(wireOf(sock, timeoutMs))
    if head.code div 100 != 2: raise newException(IOError, "the proxy rejected CONNECT to " & host & ":" & target & " (" & $head.code & " " & head.reason & ")")
    # a CONNECT answer has no body: the bytes that follow its headers are the service's TLS
    ctx.wrapConnectedSocket(sock, handshakeAsClient, host)
    sock.send(requestText(meth, host, target, path, headers, body))
    readResponse(wireOf(sock, timeoutMs))
