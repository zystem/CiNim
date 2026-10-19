## A stand-in for an HTTP proxy that takes CONNECT (tinyproxy, Squid), for testing that the core reaches the key service through one (core/transitclient.nim, `proxy`): it remembers
## the request line it was given, then either tunnels the bytes to the target or refuses. Threads share nothing but fixed arrays and a lock (a string made in one thread and freed in
## another crashes), and a connection is served by one thread from start to end.
import std/[nativesockets, net, locks, strutils, posix]

type ProxyMode* = enum pmTunnel, pmRefuse

const
  maxConns = 256
  lineLen = 256

var
  lock: Lock
  mode = pmTunnel
  stopping = false
  listenFd: SocketHandle = osInvalidSocket
  seen: array[lineLen, char]          ## the request line of the last CONNECT
  connects*: int
  accepter: Thread[void]
  conns: array[maxConns, Thread[int]]
  nconns = 0
initLock(lock)

proc setMode*(m: ProxyMode) =
  withLock lock: mode = m

proc lastRequestLine*(): string =
  withLock lock:
    for c in seen:
      if c == '\0': break
      result.add c

proc readHead(fd: SocketHandle): string =
  var buf: array[4096, char]
  while result.len < 8192 and "\r\n\r\n" notin result:
    let n = posix.recv(fd, addr buf[0], buf.len, 0)
    if n <= 0: return ""
    for i in 0 ..< n: result.add buf[i]

proc sendAll(fd: SocketHandle; data: openArray[char]; n: int): bool =
  var off = 0
  while off < n:
    let w = posix.send(fd, unsafeAddr data[off], n - off, cint(MSG_NOSIGNAL))
    if w <= 0: return false
    off += w
  true

proc serve(fd: int) {.thread.} =
  let client = SocketHandle(fd)
  defer: discard posix.close(client)
  let head = readHead(client)
  if head.len == 0: return
  let first = head.split("\r\n")[0]
  withLock lock:
    for i in 0 ..< lineLen: seen[i] = '\0'
    for i in 0 ..< min(first.len, lineLen - 1): seen[i] = first[i]
    inc connects
  var refuse = false
  withLock lock: refuse = mode == pmRefuse
  let parts = first.split(' ')
  if refuse or parts.len < 3 or parts[0] != "CONNECT":
    let r = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"
    discard sendAll(client, r, r.len)
    return
  let hp = parts[1].rsplit(':', 1)
  var target: Socket
  try: target = dial(hp[0], Port(parseInt(hp[1])))
  except CatchableError:
    let r = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
    discard sendAll(client, r, r.len)
    return
  defer: target.close()
  let up = target.getFd()
  let ok = "HTTP/1.1 200 Connection established\r\n\r\n"
  if not sendAll(client, ok, ok.len): return
  var buf: array[16384, char]
  while true:
    var fds = [TPollfd(fd: cint(client), events: POLLIN), TPollfd(fd: cint(up), events: POLLIN)]
    if posix.poll(addr fds[0], 2, 30000) <= 0: return
    for i in 0 .. 1:
      if (fds[i].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        let n = posix.recv(SocketHandle(fds[i].fd), addr buf[0], buf.len, 0)
        if n <= 0: return
        if not sendAll(if i == 0: up else: client, buf, n): return

proc acceptLoop() {.thread.} =
  while true:
    let c = posix.accept(listenFd, nil, nil)
    var done = false
    withLock lock: done = stopping
    if done:
      if c != osInvalidSocket: discard posix.close(c)
      return
    if c == osInvalidSocket: continue
    var slot = 0
    withLock lock:
      slot = nconns mod maxConns
      inc nconns
    createThread(conns[slot], serve, int(c))

proc startProxy*(port: int) =
  stopping = false
  connects = 0
  listenFd = createNativeSocket()
  var one: cint = 1
  discard setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, addr one, SockLen(sizeof(one)))
  let ai = getAddrInfo("127.0.0.1", Port(port))
  doAssert bindAddr(listenFd, ai.ai_addr, ai.ai_addrlen) == 0
  freeAddrInfo(ai)
  doAssert posix.listen(listenFd, 64) == 0
  createThread(accepter, acceptLoop)

proc stopProxy*() =
  withLock lock: stopping = true
  discard posix.shutdown(listenFd, SHUT_RDWR)
  discard posix.close(listenFd)
