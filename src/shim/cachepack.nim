## The archive of a cache (DAT-004): the files a step asked to keep (`paths` of its `cache` option, under the workspace) as a tar stream cut into chunks that are compressed one by
## one, so that nothing is held in memory but a chunk (E-003; the cache of a build is gigabytes). The file is
##
##     "CICDCCH1"  then, for every chunk:  a 4-byte big-endian length, that many bytes of gzip  - and at the end a length of 0
##
## where the chunks, decompressed and put one after another, are a POSIX ustar archive of regular files, directories and symbolic links (names of up to 255 characters, split into
## the `prefix` and `name` fields; a longer name, a device, a socket or a hard link is left out and counted). The end marker is how a reader knows that the file was not cut short.
## Unpacking is what a poisoned cache would attack, so it is strict: a name that is absolute or has `..`, a type that is not one of the three, a path whose parent is a symbolic
## link and a symbolic link that points outside the workspace are refused (the entry is skipped and counted), and nothing is made outside the root.
import std/[os, strutils, algorithm, times, posix, sequtils]
import zippy

const
  magic = "CICDCCH1"
  chunkSize = 4 * 1024 * 1024
  blockSize = 512
  maxEntries* = 500_000
  defaultMaxBytes* = 8'i64 * 1024 * 1024 * 1024        ## of the tar stream, before compression

type
  PackStats* = object
    files*, dirs*, links*, skipped*: int
    bytes*: int64              ## of the tar stream
    error*: string

# ------------------------------------------------------------------ the tar header

func octal(n: int64; width: int): string =
  ## `width` - 1 octal digits and a NUL
  var s = toOct(n, width - 1)
  if s.len > width - 1: s = s[s.len - (width - 1) .. ^1]
  s & "\0"

func field(s: string; width: int): string =
  result = s
  if result.len > width: result.setLen(width)
  result.add repeat('\0', width - result.len)

func splitName(name: string): tuple[ok: bool, prefix, rest: string] =
  ## a name of up to 100 characters goes in `name`; a longer one is cut at a '/' so that the part after fits in 100 and the part before in 155
  if name.len <= 100: return (true, "", name)
  if name.len > 255: return
  var i = name.high
  while i > 0:
    if name[i] == '/' and i <= 155 and name.len - i - 1 <= 100 and name.len - i - 1 > 0: return (true, name[0 ..< i], name[i + 1 .. ^1])
    dec i

proc header(name: string; mode: int64; size: int64; mtime: int64; typeflag: char; link: string): string =
  ## the 512 bytes; "" when the name or the link does not fit
  let sp = splitName(name)
  if not sp.ok or link.len > 100: return ""
  var h = field(sp.rest, 100) & octal(mode and 0o7777, 8) & octal(0, 8) & octal(0, 8) & octal(size, 12) & octal(max(mtime, 0), 12) & "        " & $typeflag &
          field(link, 100) & "ustar\0" & "00" & field("", 32) & field("", 32) & octal(0, 8) & octal(0, 8) & field(sp.prefix, 155)
  h.add repeat('\0', blockSize - h.len)
  var sum = 0
  for ch in h: sum += ord(ch)
  let ck = toOct(sum, 6) & "\0 "
  for k in 0 ..< 8: h[148 + k] = ck[k]
  h

func parseOctal(s: string): int64 =
  var t = s.strip(chars = {'\0', ' '})
  if t.len == 0: return 0
  for ch in t:
    if ch notin {'0' .. '7'}: return -1
    result = result * 8 + int64(ord(ch) - ord('0'))

# ------------------------------------------------------------------ the output

type Sink = object
  f: File
  buf: string
  bytes: int64

proc frame(s: var Sink; data: string) =
  let z = compress(data, 1, dfGzip)
  let n = z.len
  s.f.write char((n shr 24) and 255); s.f.write char((n shr 16) and 255); s.f.write char((n shr 8) and 255); s.f.write char(n and 255)
  s.f.write z

proc put(s: var Sink; data: string) =
  s.bytes += data.len
  s.buf.add data
  while s.buf.len >= chunkSize:
    s.frame(s.buf[0 ..< chunkSize])
    s.buf = s.buf[chunkSize .. ^1]

proc finish(s: var Sink) =
  if s.buf.len > 0: s.frame(s.buf)
  s.buf = ""
  s.f.write "\0\0\0\0"

proc modeOf(path: string): int64 =
  var st: Stat
  if stat(path.cstring, st) != 0: return 0o644
  int64(st.st_mode) and 0o7777

proc mtimeOf(path: string): int64 =
  try: getLastModificationTime(path).toUnix except CatchableError: 0

proc packCache*(root: string; paths: seq[string]; outFile: string; maxBytes = defaultMaxBytes): PackStats =
  ## The files and directories named by `paths` (relative to `root`; one that is not there is left out, not an error), into `outFile`.
  var found: seq[string]
  for p in paths:
    let abs = root / p
    if symlinkExists(abs) or fileExists(abs):
      found.add p
    elif dirExists(abs):
      found.add p
      for sub in walkDirRec(abs, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir}, followFilter = {pcDir}, relative = true):
        found.add p & "/" & sub
        if found.len > maxEntries:
          result.error = "more than " & $maxEntries & " files"
          return
  found.sort()
  var f: File
  try:
    f = open(outFile, fmWrite)
  except IOError as e:
    result.error = e.msg
    return
  defer: f.close()
  f.write magic
  var s = Sink(f: f)
  var seen: seq[string]
  for rel in found:
    if seen.len > 0 and seen[^1] == rel: continue
    seen.add rel
    if rel.len == 0: continue
    let abs = root / rel
    try:
      if symlinkExists(abs):
        let h = header(rel, 0o777, 0, 0, '2', expandSymlink(abs))
        if h.len == 0: inc result.skipped
        else:
          s.put h
          inc result.links
      elif dirExists(abs):
        let h = header(rel & "/", modeOf(abs), 0, mtimeOf(abs), '5', "")
        if h.len == 0: inc result.skipped
        else:
          s.put h
          inc result.dirs
      elif fileExists(abs):
        let size = getFileSize(abs)
        let h = header(rel, modeOf(abs), size, mtimeOf(abs), '0', "")
        if h.len == 0:
          inc result.skipped
          continue
        s.put h
        var left = size
        var src = open(abs, fmRead)
        var buf = newString(64 * 1024)
        while left > 0:
          let n = src.readBuffer(addr buf[0], int(min(left, int64(buf.len))))
          if n <= 0: break                                  # shorter than it was: padded below
          s.put buf[0 ..< n]
          left -= n
        src.close()
        if left > 0: s.put repeat('\0', int(left))
        let pad = int((blockSize - size mod blockSize) mod blockSize)
        if pad > 0: s.put repeat('\0', pad)
        inc result.files
      else: inc result.skipped
    except CatchableError: inc result.skipped
    if s.bytes > maxBytes:
      result.error = "the cache is more than " & $maxBytes & " bytes before compression"
      return
  s.put repeat('\0', blockSize * 2)                         # the end of a tar archive
  s.finish()
  result.bytes = s.bytes

# ------------------------------------------------------------------ unpacking

type Unpacker = object
  root: string
  pending: string
  stats: PackStats
  cur: File
  curOpen: bool
  curLeft: int64
  curPad: int64
  skipLeft: int64            ## bytes of a body that is being skipped
  skipPad: int64
  curPath: string
  curMode, curMtime: int64
  done: bool

func safeRelative(name: string): bool =
  if name.len == 0 or name[0] == '/' or '\0' in name: return false
  for part in name.strip(chars = {'/'}).split('/'):
    if part == ".." or part.len == 0: return false
  true

func linkStaysInside(entry, target: string): bool =
  ## lexically: the link at `entry` (relative to the root) points at `target` without leaving the root
  if target.len == 0 or target[0] == '/' or '\0' in target: return false
  var parts = entry.strip(chars = {'/'}).split('/')
  if parts.len > 0: parts.setLen(parts.len - 1)         # the directory the link is in
  for p in target.split('/'):
    if p == "" or p == ".": continue
    if p == "..":
      if parts.len == 0: return false
      parts.setLen(parts.len - 1)
    else: parts.add p
  true

proc parentsAreReal(root, rel: string): bool =
  ## no component of the path above the entry is a symbolic link (a link already in the workspace must not take a file out of it)
  var cur = root
  let parts = rel.strip(chars = {'/'}).split('/')
  for i in 0 ..< parts.len - 1:
    cur = cur / parts[i]
    if symlinkExists(cur): return false
  true

proc beginEntry(u: var Unpacker; h: string) =
  let name0 = h[0 ..< 100].strip(chars = {'\0'})
  let prefix = h[345 ..< 500].strip(chars = {'\0'})
  var name = (if prefix.len > 0: prefix & "/" & name0 else: name0)
  let typ = h[156]
  let size = parseOctal(h[124 ..< 136])
  let mode = parseOctal(h[100 ..< 108])
  let mtime = parseOctal(h[136 ..< 148])
  let link = h[157 ..< 257].strip(chars = {'\0'})
  if size < 0 or mode < 0 or mtime < 0 or not safeRelative(name):
    inc u.stats.skipped
    u.skipLeft = max(size, 0)
    u.skipPad = (blockSize - max(size, 0) mod blockSize) mod blockSize
    return
  name = name.strip(chars = {'/'})
  let abs = u.root / name
  case typ
  of '5':
    if parentsAreReal(u.root, name):
      try:
        if symlinkExists(abs): removeFile(abs)
        createDir(abs)
        inc u.stats.dirs
      except CatchableError: inc u.stats.skipped
    else: inc u.stats.skipped
  of '2':
    if parentsAreReal(u.root, name) and linkStaysInside(name, link):
      try:
        createDir(parentDir(abs))
        if symlinkExists(abs) or fileExists(abs): removeFile(abs)
        createSymlink(link, abs)
        inc u.stats.links
      except CatchableError: inc u.stats.skipped
    else: inc u.stats.skipped
  of '0', '\0':
    var opened = false
    if parentsAreReal(u.root, name) and not dirExists(abs):
      try:
        createDir(parentDir(abs))
        if symlinkExists(abs): removeFile(abs)
        u.cur = open(abs, fmWrite)
        u.curOpen = true
        opened = true
        u.curPath = abs
        u.curMode = mode
        u.curMtime = mtime
        inc u.stats.files
      except CatchableError: discard
    if opened:
      u.curLeft = size
      u.curPad = (blockSize - size mod blockSize) mod blockSize
      if size == 0:
        u.cur.close()
        u.curOpen = false
        discard chmod(u.curPath.cstring, Mode(mode and 0o7777))
      return
    inc u.stats.skipped
    u.skipLeft = size
    u.skipPad = (blockSize - size mod blockSize) mod blockSize
  else:
    inc u.stats.skipped
    u.skipLeft = size
    u.skipPad = (blockSize - size mod blockSize) mod blockSize

proc closeCurrent(u: var Unpacker) =
  u.cur.close()
  u.curOpen = false
  try:
    discard chmod(u.curPath.cstring, Mode(u.curMode and 0o7777))
    if u.curMtime > 0: setLastModificationTime(u.curPath, fromUnix(u.curMtime))
  except CatchableError: discard

proc feed(u: var Unpacker; data: string) =
  u.pending.add data
  var pos = 0
  while pos < u.pending.len and not u.done and u.stats.error.len == 0:
    if u.curOpen:
      let n = int(min(int64(u.pending.len - pos), u.curLeft))
      if n > 0:
        discard u.cur.writeBuffer(unsafeAddr u.pending[pos], n)
        pos += n
        u.curLeft -= n
      if u.curLeft == 0:
        u.closeCurrent()
        u.skipLeft = 0
        u.skipPad = u.curPad
      continue
    if u.skipLeft > 0 or u.skipPad > 0:
      let take = int(min(int64(u.pending.len - pos), u.skipLeft + u.skipPad))
      let body = min(int64(take), u.skipLeft)
      u.skipLeft -= body
      u.skipPad -= int64(take) - body
      pos += take
      continue
    if u.pending.len - pos < blockSize: break
    let h = u.pending[pos ..< pos + blockSize]
    pos += blockSize
    if h.allIt(it == '\0'):
      u.done = true
      break
    # the checksum: a header that is damaged or is not tar at all ends the unpacking
    var sum = 0
    for k in 0 ..< blockSize: sum += (if k in 148 ..< 156: 32 else: ord(h[k]))
    if parseOctal(h[148 ..< 156]) != int64(sum):
      u.stats.error = "the archive is damaged (a header does not match its checksum)"
      break
    if u.stats.files + u.stats.dirs + u.stats.links + u.stats.skipped >= maxEntries:
      u.stats.error = "more than " & $maxEntries & " entries"
      break
    u.beginEntry(h)
  u.pending = u.pending[pos .. ^1]

proc unpackCache*(inFile, root: string): PackStats =
  ## Unpacks into `root` (which exists). `error` says what is wrong with the file; entries that were refused are counted in `skipped`.
  var f: File
  try:
    f = open(inFile, fmRead)
  except IOError as e:
    result.error = e.msg
    return
  defer: f.close()
  var m = newString(magic.len)
  if f.readBuffer(addr m[0], magic.len) != magic.len or m != magic:
    result.error = "this is not a cache archive"
    return
  var u = Unpacker(root: root)
  var ended = false
  while true:
    var lenBytes: array[4, byte]
    if f.readBuffer(addr lenBytes[0], 4) != 4:
      u.stats.error = "the archive is cut short"
      break
    let n = (int(lenBytes[0]) shl 24) or (int(lenBytes[1]) shl 16) or (int(lenBytes[2]) shl 8) or int(lenBytes[3])
    if n == 0:
      ended = true
      break
    if n > chunkSize * 2:
      u.stats.error = "the archive is damaged (a chunk is too long)"
      break
    var z = newString(n)
    if f.readBuffer(addr z[0], n) != n:
      u.stats.error = "the archive is cut short"
      break
    var chunk = ""
    try: chunk = uncompress(z)
    except CatchableError:
      u.stats.error = "the archive is damaged (a chunk does not decompress)"
      break
    u.feed(chunk)
    if u.stats.error.len > 0: break
  if u.curOpen: u.closeCurrent()
  if u.stats.error.len == 0 and not ended: u.stats.error = "the archive is cut short"
  u.stats
