## The disk of a store node (docs/store.md, D-57): objects as plain files under `data/`, named by `layout.nim`, written atomically from `tmp/`.
##
## An object is written to a file in `tmp/`, its SHA-256 is compared with the one the client announced, the file is flushed (`fsync`), renamed into place, and the directory is flushed:
## a crash leaves a file in `tmp/` and never a half object under its name. A multipart upload keeps its parts in `tmp/up-<id>/` and is put together in `tmp/asm-<id>` at the end, in
## one pass that also takes the SHA-256 of the whole. `list` walks the tree in the order of the segments of the keys; a path can hold a file or a directory, not both, so the keys
## `a` and `a/b` cannot both exist (`conflict`).
import std/[os, strutils, algorithm, times, posix, sysrand]
import sha, layout
import ../common/shmq

const
  copyBlock = 1 shl 20
  maxParts* = 10000

type
  SyncMode* = enum
    smFull = "full"        ## the file and then its directory are flushed to the disk before the answer: a write that was answered survives a power cut (the default)
    smFile = "file"        ## the file only: the rename may be lost in a power cut (the object is then absent, never half there)
    smNone = "none"        ## nothing is flushed: the page cache decides; a process that is killed loses nothing, a machine that loses power may lose the last seconds

var syncMode* = smFull

type
  Disk* = object
    root*, data, tmp: string

  DiskResult* = object
    ok*: bool
    code*, error*: string       ## not_found, bad_key, bad_hash, bad_upload, bad_part, conflict, io

  Entry* = object
    key*: string
    size*, mtime*: int64
    exact*: bool

proc cRename(a, b: cstring): cint {.importc: "rename", header: "<stdio.h>".}

func good(): DiskResult = DiskResult(ok: true)
func bad(code, error: string): DiskResult = DiskResult(code: code, error: error)

proc randomId(): string =
  for b in urandom(16): result.add toHex(int(b), 2).toLowerAscii

proc openDisk*(root: string): Disk =
  result.root = root
  result.data = root / "data"
  result.tmp = root / "tmp"
  createDir(result.data)
  createDir(result.tmp)

proc fsyncPath(path: string) =
  ## flushes a file or a directory to the disk; a failure to open is not an error (the caller has already written what it has)
  if syncMode != smFull: return
  let fd = posix.open(path.cstring, O_RDONLY)
  if fd < 0: return
  discard posix.fsync(fd)
  discard posix.close(fd)

proc writeFlushed(path: string; content: openArray[char]): bool =
  var f: File
  try:
    f = open(path, fmWrite)
    if content.len > 0 and f.writeBuffer(unsafeAddr content[0], content.len) != content.len: raise newException(IOError, "short write")
    f.flushFile()
    if syncMode != smNone: discard posix.fsync(getFileHandle(f))
    f.close()
    true
  except IOError, OSError:
    if f != nil:
      try: f.close()
      except CatchableError: discard
    false

proc place(d: Disk; tmpFile, key: string): DiskResult =
  ## the file in `tmp/` becomes the object: a rename, then the directory flushed
  let final = d.data / keyToRel(key)
  let dir = final.parentDir
  try:
    createDir(dir)
  except CatchableError as e:
    removeFile(tmpFile)
    return bad("conflict", "a part of the key is a file already: " & e.msg)
  if dirExists(final):
    removeFile(tmpFile)
    return bad("conflict", "the key is a directory (other keys are below it)")
  if cRename(tmpFile.cstring, final.cstring) != 0:
    let why = $strerror(errno)
    removeFile(tmpFile)
    return bad("io", "rename: " & why)
  fsyncPath(dir)
  good()

proc putObject*(d: Disk; key: string; data: openArray[char]; sha256 = ""): DiskResult =
  let why = validKey(key)
  if why.len > 0: return bad("bad_key", why)
  if sha256.len > 0:
    var st = initSha256()
    st.update(data)
    if hexDigest(st) != sha256.toLowerAscii: return bad("bad_hash", "the SHA-256 of the data is not the one announced")
  let t = d.tmp / ("put-" & randomId())
  if not writeFlushed(t, data):
    removeFile(t)
    return bad("io", "the disk would not take the data")
  d.place(t, key)

# ------------------------------------------------------------------ multipart

proc upDir(d: Disk; id: string): string = d.tmp / ("up-" & id)

func validId(id: string): bool = id.len == 32 and id.allCharsInSet({'0' .. '9', 'a' .. 'f'})

proc mpCreate*(d: Disk; key: string): tuple[res: DiskResult, uploadId: string] =
  let why = validKey(key)
  if why.len > 0: return (bad("bad_key", why), "")
  let id = randomId()
  try:
    createDir(d.upDir(id))
  except OSError as e:
    return (bad("io", e.msg), "")
  if not writeFlushed(d.upDir(id) / "key", key): return (bad("io", "the disk would not take the upload"), "")
  (good(), id)

proc mpPart*(d: Disk; uploadId: string; part: int; data: openArray[char]): tuple[res: DiskResult, etag: string] =
  if not validId(uploadId) or not dirExists(d.upDir(uploadId)): return (bad("bad_upload", "no such upload"), "")
  if part < 1 or part > maxParts: return (bad("bad_part", "parts are numbered 1.." & $maxParts), "")
  var st = initSha256()
  st.update(data)
  let etag = hexDigest(st)
  let t = d.upDir(uploadId) / ("p" & $part & "-" & randomId())
  if not writeFlushed(t, data):
    removeFile(t)
    return (bad("io", "the disk would not take the part"), "")
  let final = d.upDir(uploadId) / ("part-" & $part)
  if cRename(t.cstring, final.cstring) != 0: return (bad("io", "rename: " & $strerror(errno)), "")
  # the etag of a part is kept beside it, so that the complete can check what the client says
  discard writeFlushed(final & ".etag", etag)
  (good(), etag)

proc mpAbort*(d: Disk; uploadId: string): DiskResult =
  if not validId(uploadId): return bad("bad_upload", "no such upload")
  try:
    removeDir(d.upDir(uploadId))
  except OSError: discard
  good()

proc mpComplete*(d: Disk; uploadId: string; parts: seq[(int, string)]; sha256 = ""): DiskResult =
  if not validId(uploadId) or not dirExists(d.upDir(uploadId)): return bad("bad_upload", "no such upload")
  if parts.len == 0 or parts.len > maxParts: return bad("bad_part", "an upload has 1.." & $maxParts & " parts")
  var last = 0
  for (n, etag) in parts:
    if n <= last: return bad("bad_part", "the parts are listed in ascending order, each once")
    last = n
    let ef = d.upDir(uploadId) / ("part-" & $n & ".etag")
    if not fileExists(ef): return bad("bad_part", "part " & $n & " was not uploaded")
    if readFile(ef).strip != etag.toLowerAscii: return bad("bad_part", "part " & $n & " is not the one with that etag")
  let key = readFile(d.upDir(uploadId) / "key")
  let asmFile = d.tmp / ("asm-" & uploadId)
  var st = initSha256()
  try:
    var o = open(asmFile, fmWrite)
    var buf = newString(copyBlock)
    for (n, _) in parts:
      var f = open(d.upDir(uploadId) / ("part-" & $n), fmRead)
      while true:
        let got = f.readBuffer(addr buf[0], copyBlock)
        if got <= 0: break
        st.update(buf.toOpenArray(0, got - 1))
        discard o.writeBuffer(addr buf[0], got)
      f.close()
    o.flushFile()
    if syncMode != smNone: discard posix.fsync(getFileHandle(o))
    o.close()
  except CatchableError as e:
    removeFile(asmFile)
    return bad("io", e.msg)
  if sha256.len > 0 and hexDigest(st) != sha256.toLowerAscii:
    removeFile(asmFile)
    return bad("bad_hash", "the SHA-256 of the whole is not the one announced")
  let r = d.place(asmFile, key)
  if r.ok:
    try: removeDir(d.upDir(uploadId))
    except OSError: discard
  r

# ------------------------------------------------------------------ reading

proc pathOf(d: Disk; key: string): tuple[res: DiskResult, path: string] =
  let why = validKey(key)
  if why.len > 0: return (bad("bad_key", why), "")
  let p = d.data / keyToRel(key)
  if not fileExists(p): return (bad("not_found", "no such object"), "")
  (good(), p)

proc objectSize*(d: Disk; key: string): tuple[res: DiskResult, size: int64] =
  let p = d.pathOf(key)
  if not p.res.ok: return (p.res, -1)
  (good(), getFileSize(p.path))

proc readRangeBuf*(d: Disk; key: string; offset, length: int64; headroom = 0): tuple[res: DiskResult, base: pointer, want: int, size: int64] =
  ## the bytes are read into a block of `shmAlloc` that has `headroom` free bytes before them (the caller puts the header of the reply there, so that the data is not copied again);
  ## the caller frees `base` with `shmFree`. `base` is nil when there is nothing to read
  let p = d.pathOf(key)
  if not p.res.ok: return (p.res, nil, 0, -1)
  try:
    var f = open(p.path, fmRead)
    defer: f.close()
    let size = f.getFileSize()
    if offset < 0 or length < 0 or offset > size: return (bad("bad_range", "the range is outside the object"), nil, 0, size)
    let want = int(min(length, size - offset))
    if want == 0: return (good(), nil, 0, size)
    let base = shmAlloc(headroom + want)
    f.setFilePos(offset)
    let got = f.readBuffer(cast[pointer](cast[uint](base) + uint(headroom)), want)
    if got < 0:
      shmFree(base)
      return (bad("io", "read"), nil, 0, -1)
    (good(), base, got, size)
  except CatchableError as e:
    (bad("io", e.msg), nil, 0, -1)

proc readRange*(d: Disk; key: string; offset, length: int64): tuple[res: DiskResult, data: string, size: int64] =
  let r = d.readRangeBuf(key, offset, length)
  if not r.res.ok: return (r.res, "", r.size)
  var s = newString(r.want)
  if r.want > 0:
    copyMem(addr s[0], r.base, r.want)
    shmFree(r.base)
  (good(), s, r.size)

proc hashOf*(d: Disk; key: string): tuple[res: DiskResult, sha256: string] =
  let p = d.pathOf(key)
  if not p.res.ok: return (p.res, "")
  try:
    var f = open(p.path, fmRead)
    defer: f.close()
    var st = initSha256()
    var buf = newString(copyBlock)
    while true:
      let got = f.readBuffer(addr buf[0], copyBlock)
      if got <= 0: break
      st.update(buf.toOpenArray(0, got - 1))
    (good(), hexDigest(st))
  except CatchableError as e:
    (bad("io", e.msg), "")

proc deleteObject*(d: Disk; key: string): DiskResult =
  ## a missing object is not an error; the directories left empty are removed up to `data/`
  let why = validKey(key)
  if why.len > 0: return bad("bad_key", why)
  let p = d.data / keyToRel(key)
  if not fileExists(p): return good()
  try:
    removeFile(p)
  except OSError as e:
    return bad("io", e.msg)
  var dir = p.parentDir
  while dir.len > d.data.len and dir != d.data:
    if posix.rmdir(dir.cstring) != 0: break           # not empty: stop (removeDir would take everything below it)
    dir = dir.parentDir
  good()

# ------------------------------------------------------------------ listing, statistics, upkeep

func segs(key: string): seq[string] = key.split('/')

func cmpSegs(a, b: seq[string]): int =
  for i in 0 ..< min(a.len, b.len):
    let c = cmp(a[i], b[i])
    if c != 0: return c
  cmp(a.len, b.len)

proc listKeys*(d: Disk; prefix, after: string; limit: int): tuple[entries: seq[Entry], next: string] =
  ## Up to `limit` objects whose key starts with `prefix`, in the order of the segments of the keys, those after the key `after` (a key from the previous page). `next` is the last key
  ## of a full page, "" when the listing is over.
  let pre = if prefix.len > 0: segs(prefix) else: @[]
  let fullPre = if pre.len > 0: pre[0 ..< pre.high] else: @[]
  let partial = if pre.len > 0: pre[^1] else: ""
  let aft = if after.len > 0: segs(after) else: @[]
  var done = false
  var entries: seq[Entry]
  var nextKey = ""
  proc walk(dirRel: string; here: seq[string]; exactSoFar: bool) =
    if done: return
    type Item = tuple[name: string, text: string, isDir: bool, exact: bool]
    var items: seq[Item]
    for kind, path in walkDir(d.data / dirRel, relative = true):
      let u = unescapeSegment(path)
      let text = if u.ok: u.text else: path
      items.add (path, text, kind in {pcDir, pcLinkToDir}, u.ok and u.exact)
    items.sort(proc (x, y: Item): int = cmp(x.text, y.text))
    for it in items:
      if done: return
      let mine = here & @[it.text]
      # the prefix: whole segments must be equal, the last (partial) one a beginning
      let depth = here.len
      if depth < fullPre.len and it.text != fullPre[depth]: continue
      if depth == fullPre.len and pre.len > 0 and not it.text.startsWith(partial): continue
      if aft.len > 0:
        let k = min(mine.len, aft.len)
        if cmpSegs(mine[0 ..< k], aft[0 ..< k]) < 0: continue            # all of it is before the cursor
      let rel = if dirRel.len > 0: dirRel / it.name else: it.name
      if it.isDir:
        walk(rel, mine, exactSoFar and it.exact)
      else:
        if aft.len > 0 and cmpSegs(mine, aft) <= 0: continue
        let info = getFileInfo(d.data / rel)
        let key = mine.join("/")
        entries.add Entry(key: key, size: info.size, mtime: info.lastWriteTime.toUnix, exact: exactSoFar and it.exact)
        if entries.len >= limit:
          done = true
          nextKey = key
  if limit > 0: walk("", @[], true)
  (entries, nextKey)

proc stats*(d: Disk): tuple[total, free: int64] =
  var s: Statvfs
  if statvfs(d.data.cstring, s) != 0: return (0, 0)
  (int64(s.f_blocks) * int64(s.f_frsize), int64(s.f_bavail) * int64(s.f_frsize))

proc sweepTmp*(d: Disk; olderThanSeconds: int64): int =
  ## removes what a crashed write left in `tmp/` (files and upload directories not touched for that long)
  let limit = getTime().toUnix - olderThanSeconds
  for kind, path in walkDir(d.tmp):
    try:
      if getFileInfo(path, followSymlink = false).lastWriteTime.toUnix >= limit: continue
      if kind == pcDir: removeDir(path) else: removeFile(path)
      inc result
    except OSError: discard
