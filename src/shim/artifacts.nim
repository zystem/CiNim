## The artifacts of a step (DAT-003, docs/artifacts.md), the shim's part: find the files, hash them, read them in blocks, and keep a manifest of what is still
## to be delivered. The blocks go to the core over the authenticated channel (logclient.nim, like the log); the shim knows nothing of the store.
##
## The manifest (`artifacts.manifest` in the spool directory) lists what the command left and the core has not yet taken. It is what makes the spool fallback
## possible: when the core cannot be reached the shim ends with `artifacts_undelivered`, the Pod stays with its workspace, and the job controller, when the
## core orders it, reads the files out through `exec` (`cicd-shim --read-artifact`, below in shim.nim) and hands them to the core's ArtifactIngest with the
## step's own credential, then removes the manifest (`--ack-artifacts`).
import std/[os, strutils, algorithm, json]
import checksums/sha2

const
  blockSize = 64 * 1024
  maxFiles* = 1000
  partSize* = 8 * 1024 * 1024         ## a block of an upload: the same as core/storagebackend.nim's
  readSize* = 4 * 1024 * 1024         ## a block of a download

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

proc readBlock*(path: string; offset, length: int64): string =
  ## `length` bytes of the file from `offset` (fewer at its end)
  var f = open(path, fmRead)
  defer: f.close()
  f.setFilePos(offset)
  result = newString(int(length))
  let n = f.readBuffer(addr result[0], int(length))
  result.setLen(n)

type ManifestFile* = object
  path*: string
  size*: int64
  sha256*: string

proc writeManifest*(path: string; files: seq[ManifestFile]) =
  var a = newJArray()
  for f in files: a.add %*{"path": f.path, "size": f.size, "sha256": f.sha256}
  writeFile(path & ".tmp", $a)
  moveFile(path & ".tmp", path)

proc readManifest*(path: string): seq[ManifestFile] =
  if not fileExists(path): return
  try:
    for f in parseJson(readFile(path)):
      result.add ManifestFile(path: f{"path"}.getStr, size: f{"size"}.getBiggestInt, sha256: f{"sha256"}.getStr)
  except CatchableError: discard

proc declaredArtifacts*(opts: JsonNode): tuple[upload, download: seq[string]] =
  ## the `artifacts` of the step's options; a list that is not declared (nil) is none. (`for x in items(node)` over a nil node is a segmentation fault: the
  ## elements are taken from `.elems` only when the node is an array.)
  if opts == nil or opts.kind != JObject: return
  let a = opts{"artifacts"}
  if a == nil or a.kind != JObject: return
  for key in ["upload", "download"]:
    let l = a{key}
    if l != nil and l.kind == JArray:
      for e in l.elems:
        if e.kind == JString: (if key == "upload": result.upload.add e.getStr else: result.download.add e.getStr)
