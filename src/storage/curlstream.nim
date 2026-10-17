## A body sent as a stream to one or more servers at once, through libcurl (docs/storage-module.md, "The streaming PUT"). The module takes the body of a PUT from the socket piece by piece
## (storage/service.nim) and hands each piece on to the stores before it reads the next, so that a block of 8 MiB is never in memory: a piece is passed on when every transfer that is
## still alive has taken the one before, and a slow store slows the sender down. A transfer that ends before the body does (refused, reset, answered early) is dropped from the pass and its
## result kept; the others go on; the caller decides whether enough of them succeeded. Built with libcurl found at run time (`libcurl.so.4`), or linked in with `-d:curlStatic`
## and `--passL:"-L/opt/k8s/lib -lcurl -lssl -lcrypto -lz"` (tools/image/Dockerfile.kaniko), the way the image of the module is made.
import std/strutils
import ../common/storagebackend

when defined(curlStatic):
  {.pragma: curlImp, cdecl, importc.}
else:
  {.pragma: curlImp, cdecl, dynlib: "libcurl.so.4", importc.}

type
  Curl = pointer
  CurlM = pointer
  CurlMsgRec = object
    msg: cint
    easy: pointer
    result: int64          ## the union of the message: the result code is its first four bytes

const
  CURLOPT_WRITEDATA = 10001.cint
  CURLOPT_URL = 10002.cint
  CURLOPT_READDATA = 10009.cint
  CURLOPT_HTTPHEADER = 10023.cint
  CURLOPT_HEADERDATA = 10029.cint
  CURLOPT_CAINFO = 10065.cint
  CURLOPT_CUSTOMREQUEST = 10036.cint
  CURLOPT_UPLOAD = 46.cint
  CURLOPT_NOSIGNAL = 99.cint
  CURLOPT_CONNECTTIMEOUT_MS = 156.cint
  CURLOPT_LOW_SPEED_LIMIT = 19.cint
  CURLOPT_LOW_SPEED_TIME = 20.cint
  CURLOPT_WRITEFUNCTION = 20011.cint
  CURLOPT_READFUNCTION = 20012.cint
  CURLOPT_HEADERFUNCTION = 20079.cint
  CURLOPT_INFILESIZE_LARGE = 30115.cint
  CURLINFO_RESPONSE_CODE = 2097154.cint
  CURLMSG_DONE = 1.cint
  CURL_READFUNC_PAUSE = 0x10000001.csize_t
  CURLPAUSE_CONT = 0.cint

proc curl_global_init(flags: clong): cint {.curlImp.}
proc curl_easy_init(): Curl {.curlImp.}
proc curl_easy_cleanup(h: Curl) {.curlImp.}
proc curl_easy_pause(h: Curl; bits: cint): cint {.curlImp.}
proc curl_easy_setopt(h: Curl; opt: cint): cint {.curlImp, varargs.}
proc curl_easy_getinfo(h: Curl; info: cint): cint {.curlImp, varargs.}
proc curl_easy_strerror(code: cint): cstring {.curlImp.}
proc curl_slist_append(l: pointer; s: cstring): pointer {.curlImp.}
proc curl_slist_free_all(l: pointer) {.curlImp.}
proc curl_multi_init(): CurlM {.curlImp.}
proc curl_multi_cleanup(m: CurlM): cint {.curlImp.}
proc curl_multi_add_handle(m: CurlM; h: Curl): cint {.curlImp.}
proc curl_multi_remove_handle(m: CurlM; h: Curl): cint {.curlImp.}
proc curl_multi_perform(m: CurlM; running: ptr cint): cint {.curlImp.}
proc curl_multi_poll(m: CurlM; extra: pointer; n: cuint; timeoutMs: cint; ret: ptr cint): cint {.curlImp.}
proc curl_multi_info_read(m: CurlM; left: ptr cint): ptr CurlMsgRec {.curlImp.}

type
  UpTarget* = object
    url*: string
    headers*: seq[string]            ## "Name: value"
    caFile*: string                  ## for https; empty: the system's roots
    timeoutMs*: int                  ## a transfer that moves less than a byte a second for this long is given up (0: 30 s)

  UpResult* = object
    status*: int                     ## 0: there was no answer
    error*: string                   ## when status is 0: what libcurl said
    headers*: seq[(string, string)]  ## of the answer, names in lower case
    body*: string                    ## the start of the answer, up to 4 KiB

  Piece = object
    data: ptr UncheckedArray[char]
    len: int

  HState = object
    piece: ptr Piece
    off: int
    eof: bool
    done: bool
    rawHead: string
    body: string

var globalDone {.global.} = false

proc ensureInit() =
  if not globalDone:
    discard curl_global_init(3)
    globalDone = true

proc readCb(buf: pointer; size, nitems: csize_t; user: pointer): csize_t {.cdecl.} =
  let h = cast[ptr HState](user)
  let have = h.piece.len - h.off
  if have <= 0: return (if h.eof: 0.csize_t else: CURL_READFUNC_PAUSE)
  let n = min(int(size * nitems), have)
  copyMem(buf, addr h.piece.data[h.off], n)
  h.off += n
  csize_t(n)

proc writeCb(buf: pointer; size, nmemb: csize_t; user: pointer): csize_t {.cdecl.} =
  let h = cast[ptr HState](user)
  let n = int(size * nmemb)
  if h.body.len < 4096 and n > 0:
    let take = min(n, 4096 - h.body.len)
    let old = h.body.len
    h.body.setLen(old + take)
    copyMem(addr h.body[old], buf, take)
  csize_t(n)

proc headerCb(buf: pointer; size, nitems: csize_t; user: pointer): csize_t {.cdecl.} =
  let h = cast[ptr HState](user)
  let n = int(size * nitems)
  if n > 0 and h.rawHead.len < 16384:
    let old = h.rawHead.len
    h.rawHead.setLen(old + n)
    copyMem(addr h.rawHead[old], buf, n)
  csize_t(n)

proc parseHeaders(raw: string): seq[(string, string)] =
  # the headers of the last response in `raw` (curl hands over those of a redirect or a 100 first); names in lower case
  var blocks = raw.split("\r\n\r\n")
  var last = ""
  for b in blocks:
    if b.startsWith("HTTP/"): last = b
  for line in last.split("\r\n")[1 .. ^1]:
    let c = line.find(':')
    if c > 0: result.add (line[0 ..< c].strip.toLowerAscii, line[c + 1 .. ^1].strip)

proc streamUpload*(targets: seq[UpTarget]; size: int64; src: BodySource): tuple[results: seq[UpResult], sourceOk: bool] =
  ## PUT `size` bytes read from `src` to every target. `sourceOk` is false if the sender broke off (then no result is to be trusted). The method of every target is PUT.
  ensureInit()
  let n = targets.len
  var outRes = newSeq[UpResult](n)
  var srcOk = false
  var states = newSeq[HState](n)
  var easy = newSeq[Curl](n)
  var lists = newSeq[pointer](n)
  var live = newSeq[bool](n)
  var piece = Piece()
  let multi = curl_multi_init()
  for i in 0 ..< n:
    states[i].piece = addr piece
    let h = curl_easy_init()
    easy[i] = h
    discard curl_easy_setopt(h, CURLOPT_URL, cstring(targets[i].url))
    discard curl_easy_setopt(h, CURLOPT_UPLOAD, 1.clong)
    discard curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1.clong)
    discard curl_easy_setopt(h, CURLOPT_INFILESIZE_LARGE, size)
    discard curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT_MS, 5000.clong)
    discard curl_easy_setopt(h, CURLOPT_LOW_SPEED_LIMIT, 1.clong)
    discard curl_easy_setopt(h, CURLOPT_LOW_SPEED_TIME, clong(if targets[i].timeoutMs > 0: max(1, targets[i].timeoutMs div 1000) else: 30))
    discard curl_easy_setopt(h, CURLOPT_READFUNCTION, cast[pointer](readCb))
    discard curl_easy_setopt(h, CURLOPT_READDATA, addr states[i])
    discard curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, cast[pointer](writeCb))
    discard curl_easy_setopt(h, CURLOPT_WRITEDATA, addr states[i])
    discard curl_easy_setopt(h, CURLOPT_HEADERFUNCTION, cast[pointer](headerCb))
    discard curl_easy_setopt(h, CURLOPT_HEADERDATA, addr states[i])
    if targets[i].caFile.len > 0: discard curl_easy_setopt(h, CURLOPT_CAINFO, cstring(targets[i].caFile))
    var l: pointer = nil
    l = curl_slist_append(l, "Expect:")                     # no 100-continue: the answer to it would wait for the first piece
    for hd in targets[i].headers: l = curl_slist_append(l, cstring(hd))
    lists[i] = l
    discard curl_easy_setopt(h, CURLOPT_HTTPHEADER, l)
    discard curl_multi_add_handle(multi, h)
    live[i] = true

  proc collectDone() =
    var left: cint
    while true:
      let m = curl_multi_info_read(multi, addr left)
      if m == nil: break
      if m.msg != CURLMSG_DONE: continue
      for i in 0 ..< n:
        if easy[i] == m.easy and not states[i].done:
          states[i].done = true
          live[i] = false
          if cint(m.result and 0xffffffff'i64) != 0:
            outRes[i].status = 0
            outRes[i].error = $curl_easy_strerror(cint(m.result and 0xffffffff'i64))

  var running: cint = cint(n)
  var ret: cint
  proc pump(untilTaken: bool): bool =
    ## drive the transfers until every live one has taken the piece (untilTaken), or until they are all over
    while true:
      for i in 0 ..< n:
        if live[i]: discard curl_easy_pause(easy[i], CURLPAUSE_CONT)
      discard curl_multi_perform(multi, addr running)
      collectDone()
      var anyLive = false
      var allTaken = true
      for i in 0 ..< n:
        if live[i]:
          anyLive = true
          if states[i].off < piece.len: allTaken = false
      if untilTaken:
        if not anyLive or allTaken: return anyLive
      elif not anyLive: return true
      discard curl_multi_poll(multi, nil, 0, 50, addr ret)

  var anyAlive = true
  srcOk = src(proc (chunk: string): bool =
    if not anyAlive or chunk.len == 0: return anyAlive
    piece.data = cast[ptr UncheckedArray[char]](unsafeAddr chunk[0])
    piece.len = chunk.len
    for i in 0 ..< n: states[i].off = 0
    anyAlive = pump(true)
    anyAlive)
  if srcOk:
    piece.len = 0
    for i in 0 ..< n:
      states[i].off = 0
      states[i].eof = true
    discard pump(false)
  for i in 0 ..< n:
    var code: clong
    discard curl_easy_getinfo(easy[i], CURLINFO_RESPONSE_CODE, addr code)
    if states[i].done or srcOk:
      if outRes[i].error.len == 0: outRes[i].status = int(code)
    else:
      outRes[i].status = int(code)
      if code == 0: outRes[i].error = "the transfer was cut off"
    outRes[i].headers = parseHeaders(states[i].rawHead)
    outRes[i].body = states[i].body
    discard curl_multi_remove_handle(multi, easy[i])
    curl_easy_cleanup(easy[i])
    curl_slist_free_all(lists[i])
  discard curl_multi_cleanup(multi)
  (outRes, srcOk)
