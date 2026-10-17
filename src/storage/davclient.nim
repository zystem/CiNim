## A small asynchronous HTTP/1.1 client for the store nodes (core/httpstore.nim). `std/httpclient` knows only the methods of its enum and refuses PROPFIND and MOVE, which WebDAV needs;
## this one sends any method, keeps the connection to a host alive between requests, and reads an answer with a `Content-Length`, a chunked one, or one that ends with the connection.
## One request at a time on a client (a client is for one thread, one node). No redirects, no cookies, no compression: the nodes are ours.
import std/[asyncdispatch, asyncnet, strutils, net, uri]

type
  DavClient* = ref object
    host*: string
    port*: int
    tls*: bool
    sock: AsyncSocket
    ctx: SslContext

  DavResponse* = object
    status*: int
    headers*: seq[(string, string)]
    body*: string

const
  maxLine = 16 * 1024
  maxHeaders = 200
  maxBody = 256 * 1024 * 1024
  blockSize = 1 shl 20

func header*(r: DavResponse; name: string): string =
  let want = name.toLowerAscii
  for (k, v) in r.headers:
    if k.toLowerAscii == want: return v

proc newDavClient*(host: string; port: int; tls: bool; ctx: SslContext = nil): DavClient =
  DavClient(host: host, port: port, tls: tls, ctx: ctx)

proc close*(c: DavClient) =
  if c.sock != nil:
    try: c.sock.close()
    except CatchableError: discard
    c.sock = nil

proc connect(c: DavClient) {.async.} =
  c.close()
  let s = newAsyncSocket(buffered = true)
  try:
    await s.connect(c.host, Port(c.port))
    if c.tls:
      when defined(ssl):
        if c.ctx == nil: raise newException(IOError, "no TLS context")
        wrapConnectedSocket(c.ctx, s, handshakeAsClient, c.host)
      else:
        raise newException(IOError, "this build has no TLS (compile with -d:ssl)")
    c.sock = s
  except CatchableError:
    try: s.close()
    except CatchableError: discard
    raise

proc readLine(c: DavClient): Future[string] {.async.} =
  let l = await c.sock.recvLine(maxLength = maxLine)
  if l.len == 0: raise newException(IOError, "the connection was closed")
  return l.strip(leading = false, chars = {'\r', '\n'})

proc readExactly(c: DavClient; n: int): Future[string] {.async.} =
  var left = n
  var body = newStringOfCap(n)
  while left > 0:
    let s = await c.sock.recv(min(left, blockSize))
    if s.len == 0: raise newException(IOError, "the connection was closed in the middle of an answer")
    body.add s
    left -= s.len
  return body

proc readResponse(c: DavClient; meth: string): Future[tuple[r: DavResponse, reusable: bool]] {.async.} =
  var line = await c.readLine()
  while line.startsWith("HTTP/1.1 100") : # a 100 Continue is followed by the real answer
    while (await c.readLine()).len > 0: discard
    line = await c.readLine()
  let parts = line.split(' ', maxsplit = 2)
  if parts.len < 2 or not parts[0].startsWith("HTTP/1."): raise newException(IOError, "not an HTTP answer: " & line[0 ..< min(line.len, 60)])
  var r = DavResponse(status: parseInt(parts[1]))
  var reusable = parts[0] == "HTTP/1.1"
  var chunked = false
  var length = -1
  for _ in 0 ..< maxHeaders:
    let h = await c.readLine()
    if h.len == 0: break
    let colon = h.find(':')
    if colon <= 0: continue
    let k = h[0 ..< colon].strip
    let v = h[colon + 1 .. ^1].strip
    r.headers.add (k, v)
    case k.toLowerAscii
    of "content-length": length = (try: parseInt(v) except ValueError: -1)
    of "transfer-encoding": chunked = "chunked" in v.toLowerAscii
    of "connection": (if "close" in v.toLowerAscii: reusable = false)
    else: discard
  if meth == "HEAD" or r.status in [204, 304] or r.status div 100 == 1:
    return (r, reusable)
  if chunked:
    while true:
      let sizeLine = await c.readLine()
      let size = try: parseHexInt(sizeLine.split(';')[0].strip) except ValueError: raise newException(IOError, "a bad chunk size")
      if size == 0:
        while (await c.readLine()).len > 0: discard            # the trailers
        break
      if r.body.len + size > maxBody: raise newException(IOError, "the answer is too long")
      r.body.add await c.readExactly(size)
      discard await c.readLine()
  elif length >= 0:
    if length > maxBody: raise newException(IOError, "the answer is too long")
    r.body = await c.readExactly(length)
  else:
    reusable = false                                            # the answer ends with the connection
    while true:
      let s = await c.sock.recv(blockSize)
      if s.len == 0: break
      r.body.add s
      if r.body.len > maxBody: raise newException(IOError, "the answer is too long")
  return (r, reusable)

proc request*(c: DavClient; meth, target: string; headers: seq[(string, string)] = @[]; body = ""): Future[DavResponse] {.async.} =
  ## `target` is the request target as it goes into the request line (already percent-encoded). A connection that the node closed while it was idle is made again, once.
  var head = meth & " " & target & " HTTP/1.1\r\nHost: " & c.host & ":" & $c.port & "\r\nUser-Agent: cinim-core\r\nConnection: keep-alive\r\nContent-Length: " & $body.len & "\r\n"
  for (k, v) in headers: head.add k & ": " & v & "\r\n"
  head.add "\r\n"
  for attempt in 0 .. 1:
    let fresh = c.sock == nil
    if fresh: await c.connect()
    try:
      await c.sock.send(head)
      if body.len > 0: await c.sock.send(body)
      let (r, reusable) = await c.readResponse(meth)
      if not reusable: c.close()
      return r
    except CatchableError:
      c.close()
      if fresh or attempt == 1: raise
  raise newException(IOError, "unreachable")
