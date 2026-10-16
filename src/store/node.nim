## What a store node does with a request (docs/store.md, D-57): the token is checked, the operation is run on the disk, and the answer is a reply body. No sockets here, so it is tested
## without any (tests/unit/tstorenode.nim); `main.nim` carries the messages.
import std/[strutils, options]
import disk, layout, wire
import ../common/shmq

const
  maxPutBytes* = 8 * 1024 * 1024         ## a whole object in one request
  maxPartBytes* = 16 * 1024 * 1024
  maxReadBytes* = 8 * 1024 * 1024
  maxList* = 1000

func equalConstTime(a, b: string): bool =
  ## no early exit on the first difference
  var diff = a.len xor b.len
  for i in 0 ..< min(a.len, b.len): diff = diff or (ord(a[i]) xor ord(b[i]))
  diff == 0

func failure(code, error: string): Msg =
  result.add(tOk, "0")
  result.add(tCode, code)
  result.add(tError, error)

func okReply(): Msg = @[(tOk, "1")]

func fromDisk(r: DiskResult): Msg =
  if r.ok: okReply() else: failure(r.code, r.error)

type Reply* = object
  ## the fields of the answer, and for a `read` the bytes besides: they are in `base` (a block of `shmAlloc`, the bytes start `headroom` bytes into it) and are not in `fields`;
  ## whoever takes the reply frees `base` with `shmFree`
  fields*: Msg
  base*: pointer
  dataLen*: int

template bytes(s: Span): untyped = s.p.toOpenArray(0, s.n - 1)

proc handleView*(d: Disk; token: string; req: View; headroom = 0): Reply =
  ## `token` empty means the node was started without one and refuses everything: a node must be told whom to trust. The request is read in place, so the data of a put is
  ## written to the disk from the buffer it arrived in
  if token.len == 0 or not equalConstTime(req.get(tToken), token): return Reply(fields: failure("unauthorized", "a store request carries the token"))
  let key = req.get(tKey)
  var f: Msg
  case req.get(tOp)
  of "ping":
    f = okReply()
  of "put":
    let data = req.span(tData)
    if data.n > maxPutBytes: return Reply(fields: failure("too_big", "a put is at most " & $maxPutBytes & " bytes; use a multipart upload"))
    f = fromDisk(d.putObject(key, data.bytes, req.get(tSha256)))
  of "mp_create":
    let r = d.mpCreate(key)
    f = fromDisk(r.res)
    if r.res.ok: f.add(tUploadId, r.uploadId)
  of "mp_part":
    let data = req.span(tData)
    if data.n > maxPartBytes: return Reply(fields: failure("too_big", "a part is at most " & $maxPartBytes & " bytes"))
    let r = d.mpPart(req.get(tUploadId), int(req.getInt(tPart)), data.bytes)
    f = fromDisk(r.res)
    if r.res.ok: f.add(tEtag, r.etag)
  of "mp_complete":
    var parts: seq[(int, string)]
    for p in req.all(tParts):
      let pp = parsePart(p)
      if pp.isNone: return Reply(fields: failure("bad_part", "a part is `<number>:<etag>`"))
      parts.add pp.get
    f = fromDisk(d.mpComplete(req.get(tUploadId), parts, req.get(tSha256)))
  of "mp_abort":
    f = fromDisk(d.mpAbort(req.get(tUploadId)))
  of "read":
    let length = min(req.getInt(tLength), maxReadBytes.int64)
    let r = d.readRangeBuf(key, req.getInt(tOffset), length, headroom)
    f = fromDisk(r.res)
    if r.res.ok:
      f.add(tSize, r.size)
      return Reply(fields: f, base: r.base, dataLen: r.want)
  of "size":
    let r = d.objectSize(key)
    f = fromDisk(r.res)
    if r.res.ok: f.add(tSize, r.size)
  of "delete":
    f = fromDisk(d.deleteObject(key))
  of "hash":
    let r = d.hashOf(key)
    f = fromDisk(r.res)
    if r.res.ok: f.add(tSha256, r.sha256)
  of "list":
    let l = d.listKeys(req.get(tPrefix), req.get(tAfter), int(max(0'i64, min(req.getInt(tLimit, 100), maxList.int64))))
    f = okReply()
    for e in l.entries: f.add(tEntries, entryText(e.key, e.size, e.mtime, e.exact))
    if l.next.len > 0: f.add(tNext, l.next)
  of "stats":
    let s = d.stats
    f = okReply()
    f.add(tTotal, s.total)
    f.add(tFree, s.free)
  else:
    f = failure("bad_op", "no such operation")
  Reply(fields: f)

proc handle*(d: Disk; token: string; req: Msg): Msg =
  ## the same on a message that is in memory already (the tests); a read's bytes are copied into the field `tData`
  let s = encode(req)
  let v = view(cast[ptr UncheckedArray[char]](if s.len > 0: unsafeAddr s[0] else: nil), s.len)
  let r = handleView(d, token, v.get)
  result = r.fields
  if r.base != nil:
    var data = newString(r.dataLen)
    if r.dataLen > 0: copyMem(addr data[0], r.base, r.dataLen)
    shmFree(r.base)
    result.add(tData, data)
