## The artifacts of a step (DAT-003, docs/artifacts.md), the shim's part: find the files, hash them, and put or get them with the short-lived URLs core
## gives. The shim has no key for the store and no TLS client (a static binary of about a megabyte): the URLs are plain `http://` inside the cluster, and the
## transfer is a small HTTP/1.1 client over a socket that streams the file in blocks, so a big artifact is not held in memory.
import std/[os, strutils, algorithm, net, uri, json, posix]
import checksums/sha2

const
  blockSize = 64 * 1024
  maxFiles* = 1000

# ------------------------------------------------------------------ patterns

proc globMatch*(pat, s: string): bool =
  ## `*` any characters but `/`, `?` one character but `/`, `**` any characters (`/` included); `**/` may also match nothing, so `**/a` matches `a`.
  ## A table of (position in the pattern, position in the name) keeps a pattern with many wildcards from taking exponential time.
  let np = pat.len
  let ns = s.len
  var seen = newSeq[bool]((np + 1) * (ns + 1))      # visited and failed
  proc at(i, j: int): bool =
    if i == np: return j == ns
    let key = i * (ns + 1) + j
    if seen[key]: return false
    var ok = false
    if pat[i] == '*' and i + 1 < np and pat[i + 1] == '*':
      let rest = i + 2
      if rest < np and pat[rest] == '/':
        ok = at(rest + 1, j)                          # `**/` as nothing
        var k = j
        while not ok and k < ns:
          if s[k] == '/' and at(rest + 1, k + 1): ok = true
          inc k
      else:
        var k = j
        while not ok and k <= ns:
          if at(rest, k): ok = true
          inc k
    elif pat[i] == '*':
      var k = j
      while not ok and k <= ns:
        if at(i + 1, k): ok = true
        if k < ns and s[k] == '/': break
        inc k
    elif pat[i] == '?':
      ok = j < ns and s[j] != '/' and at(i + 1, j + 1)
    else:
      ok = j < ns and s[j] == pat[i] and at(i + 1, j + 1)
    if not ok: seen[key] = true
    ok
  at(0, 0)

type Collected* = object
  files*: seq[string]          ## paths relative to the root, sorted
  error*: string               ## "" or what is wrong (a pattern that matched nothing, too many files)

proc collectFiles*(root: string; patterns: seq[string]; skipDir = ".run"): Collected =
  ## the regular files under `root` that match at least one pattern (symbolic links are not followed or taken); every pattern has to match something
  var all: seq[string]
  if dirExists(root):
    for f in walkDirRec(root, yieldFilter = {pcFile}, relative = true):
      if f == skipDir or f.startsWith(skipDir & "/"): continue
      all.add f
  all.sort()
  var hit = newSeq[bool](patterns.len)
  for f in all:
    var take = false
    for i, p in patterns:
      if globMatch(p, f):
        hit[i] = true
        take = true
    if take: result.files.add f
  for i, p in patterns:
    if not hit[i]:
      result.error = "the pattern " & p & " matches no file under " & root
      return
  if result.files.len > maxFiles: result.error = "more than " & $maxFiles & " files match"

proc fileSha256*(path: string): string =
  var st = initSha_256()
  var f = open(path, fmRead)
  defer: f.close()
  var buf = newString(blockSize)
  while true:
    let n = f.readBuffer(addr buf[0], blockSize)
    if n <= 0: break
    st.update(buf.toOpenArray(0, n - 1))
  for c in st.digest(): result.add toHex(ord(c), 2).toLowerAscii

# ------------------------------------------------------------------ the transfer

type Transfer* = object
  ok*: bool
  status*: int
  detail*: string

proc readSome*(s: Socket; buf: pointer; size, timeoutMs: int): int =
  ## what has arrived, at most `size` bytes, waiting at most `timeoutMs` for the first of it (std/net's `recv` with a timeout insists on all `size` bytes)
  var pfd = TPollfd(fd: cint(s.getFd()), events: POLLIN)
  let r = poll(addr pfd, 1, cint(timeoutMs))
  if r == 0: raise newException(IOError, "the store did not answer in time")
  if r < 0: raise newException(IOError, "waiting for the store failed")
  s.recv(buf, size)

proc connect(u: Uri; timeoutMs: int): Socket =
  if u.scheme != "http": raise newException(IOError, "only http:// URLs are supported by the shim (the store is inside the cluster)")
  result = newSocket(buffered = false)    # an unbuffered socket: recv with a timeout returns what has arrived, a buffered one waits for the whole block
  try: result.connect(u.hostname, Port(if u.port.len > 0: parseInt(u.port) else: 80), timeout = timeoutMs)
  except CatchableError: result.close(); raise

proc target(u: Uri): string =
  ## the request target exactly as the URL has it: the signature covers the encoded path
  result = if u.path.len > 0: u.path else: "/"
  if u.query.len > 0: result.add "?" & u.query

proc readHead(s: Socket; timeoutMs: int): tuple[status: int; headers: seq[(string, string)]; rest: string] =
  var head = ""
  var buf = newString(4096)
  while "\r\n\r\n" notin head:
    let n = s.readSome(addr buf[0], buf.len, timeoutMs)
    if n <= 0: raise newException(IOError, "the store closed the connection")
    head.add buf[0 ..< n]
    if head.len > 65536: raise newException(IOError, "the store's answer has no end of headers")
  let cut = head.find("\r\n\r\n")
  result.rest = head[cut + 4 .. ^1]
  let lines = head[0 ..< cut].split("\r\n")
  let parts = lines[0].split(' ')
  result.status = if parts.len >= 2: (try: parseInt(parts[1]) except ValueError: 0) else: 0
  for l in lines[1 .. ^1]:
    let c = l.find(':')
    if c > 0: result.headers.add (l[0 ..< c].toLowerAscii, l[c + 1 .. ^1].strip)

proc header(h: seq[(string, string)]; name: string): string =
  for (k, v) in h:
    if k == name: return v

proc sendAll(s: Socket; buf: pointer; n: int) =
  var sent = 0
  while sent < n:
    let k = s.send(cast[pointer](cast[int](buf) + sent), n - sent)
    if k <= 0: raise newException(IOError, "the connection to the store broke")
    sent += k

proc putFile*(url, path: string; timeoutMs = 60000): Transfer =
  ## PUT of one file, streamed; the store must answer 2xx
  try:
    let u = parseUri(url)
    let size = getFileSize(path)
    let s = connect(u, 10000)
    defer: s.close()
    let hostHeader = u.hostname & (if u.port.len > 0: ":" & u.port else: "")
    s.send("PUT " & target(u) & " HTTP/1.1\r\nHost: " & hostHeader & "\r\nContent-Length: " & $size & "\r\nConnection: close\r\n\r\n")
    var f = open(path, fmRead)
    defer: f.close()
    var buf = newString(blockSize)
    while true:
      let n = f.readBuffer(addr buf[0], blockSize)
      if n <= 0: break
      s.sendAll(addr buf[0], n)
    let head = s.readHead(timeoutMs)
    result.status = head.status
    result.ok = head.status div 100 == 2
    if not result.ok: result.detail = "the store answered " & $head.status
  except CatchableError as e:
    result.detail = e.msg

proc getFile*(url, dest: string; expectSize: int64; timeoutMs = 60000): Transfer =
  ## GET into `dest` (through a `.part` file, so a cut transfer leaves nothing that looks whole); the size must be what core said
  try:
    let u = parseUri(url)
    let s = connect(u, 10000)
    defer: s.close()
    let hostHeader = u.hostname & (if u.port.len > 0: ":" & u.port else: "")
    s.send("GET " & target(u) & " HTTP/1.1\r\nHost: " & hostHeader & "\r\nConnection: close\r\n\r\n")
    let head = s.readHead(timeoutMs)
    result.status = head.status
    if head.status div 100 != 2:
      result.detail = "the store answered " & $head.status
      return
    if head.headers.header("transfer-encoding").len > 0:
      result.detail = "the store answered with a chunked body, which the shim does not read"
      return
    let want = try: parseBiggestInt(head.headers.header("content-length")) except ValueError: -1
    if want != expectSize:
      result.detail = "the store says " & $want & " bytes, core said " & $expectSize
      return
    createDir(parentDir(dest))
    let part = dest & ".part"
    var f = open(part, fmWrite)
    var got = int64(head.rest.len)
    if head.rest.len > 0: f.write head.rest
    var buf = newString(blockSize)
    while got < want:
      let n = s.readSome(addr buf[0], min(blockSize, int(want - got)), timeoutMs)
      if n <= 0: break
      discard f.writeBuffer(addr buf[0], n)
      got += n
    f.close()
    if got != want:
      removeFile(part)
      result.detail = "the transfer ended after " & $got & " of " & $want & " bytes"
      return
    moveFile(part, dest)
    result.ok = true
  except CatchableError as e:
    result.detail = e.msg
