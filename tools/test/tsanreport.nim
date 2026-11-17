## What the ThreadSanitizer reports of a test log are about (tools/test/run.sh, CINIM_TEST_TSAN=1). Usage: tsanreport LOG...
##
## A report of a data race is two accesses, each with a stack of frames. The origin of an access is the first frame that is not the runtime of Nim, of the C library or of the sanitizer; the report
## is of the class of the more interesting of its two origins:
##   ours          a frame of `src/` of this repository
##   nimgrpc       the gRPC library
##   test          a file of `tests/` or the unit test framework: the test itself shares what it must not
##   guildenstern  the HTTP library (known: docs of the repository, CLAUDE.md "A request that is slow loses its connection")
##   other         any other package or a C library
##   runtime       both origins are in the runtime: the start or the end of a thread, the exit of the program
## A report that is not a race (`thread leak`, `signal-unsafe call inside of a signal`) is counted under its own name and is never a failure.
## The exit code is 1 when any log has a report of the class ours, nimgrpc or test, 0 otherwise (the others are told and not failed on: the libraries' own races are not ours to fix here, and
## their count is what tells that they are still there). It is Nim and not a script of another language because the image of the tests has Nim and nothing else to run it with.
import std/[strutils, tables, algorithm, os, sequtils]

type
  Class* = enum
    clOurs = "ours", clNimgrpc = "nimgrpc", clTest = "test", clGuildenstern = "guildenstern", clOther = "other", clRuntime = "runtime"
  Frame* = tuple[fn, path: string; line: int]
  Access* = tuple[thread: string, frames: seq[Frame]]
  Report* = tuple[what: string, accesses: seq[Access]]

## (a path may be absolute or relative to the library of Nim: `lib/system/arc.nim` and `/home/u/.choosenim/toolchains/nim-2.4.0/lib/system/arc.nim` are both printed)
const runtimeMarks = ["lib/system/", "lib/system.nim", "lib/std/", "lib/pure/", "libsanitizer", "/usr/include/", "sanitizer_common", "tsan_", "/lib/x86_64"]

proc parseFrame*(line: string): Frame =
  ## `    #3 system::deallocImpl(pointer) lib/system/mm/malloc.nim:27 (tldap+0x1a1beb) (BuildId: ...)`: the name, then the place, then the module in brackets
  result = ("?", "?", 0)
  var rest = line.strip
  let sp = rest.find(' ')
  if sp < 0 or not rest.startsWith("#"): return
  rest = rest[sp + 1 .. ^1]
  while true:                                              # the brackets at the end are the module and the build id, not the place
    let r = rest.strip(trailing = true)
    if r.endsWith(")") and r.rfind(" (") > 0 and (r.rfind(" (") > r.rfind(':') or "+0x" in r[r.rfind(" (") .. ^1] or r.contains("(BuildId")): rest = r[0 ..< r.rfind(" (")]
    else:
      rest = r
      break
  let last = rest.rfind(' ')
  if last < 0: result.fn = rest; return
  result.fn = rest[0 ..< last]
  var place = rest[last + 1 .. ^1]
  var parts = place.split(':')
  if parts.len >= 3 and parts[^1].allCharsInSet(Digits) and parts[^2].allCharsInSet(Digits): parts.setLen(parts.len - 1)     # a column
  if parts.len >= 2 and parts[^1].allCharsInSet(Digits) and parts[^1].len > 0:
    result.line = parseInt(parts[^1])
    result.path = parts[0 ..< parts.len - 1].join(":")
  else: result.path = place

proc parseReports*(text: string): seq[Report] =
  for chunk in text.split("WARNING: ThreadSanitizer: ")[1 .. ^1]:
    let body = chunk.split("SUMMARY:")[0]
    var what = body.split(" (pid", 1)[0].splitLines[0].strip
    var accesses: seq[Access]
    var cur: Access
    var inAccess = false
    for line in body.splitLines:
      let t = line.strip
      if line.startsWith("  ") and not line.startsWith("   "):             # a heading of a section: two spaces
        if inAccess: accesses.add cur
        inAccess = false
        let low = t.toLowerAscii
        if low.startsWith("read of") or low.startsWith("write of") or low.startsWith("previous") or low.startsWith("atomic") or low.startsWith("previous atomic"):
          inAccess = true
          let who = if " by main thread" in t: "main" else: "thread"
          cur = (who, newSeq[Frame]())
      elif inAccess and t.startsWith("#"): cur.frames.add parseFrame(line)
    if inAccess: accesses.add cur
    result.add (what, accesses)

proc classOf*(path: string): Class =
  if path == "?" or path == "" or runtimeMarks.anyIt(it in path): return clRuntime
  if "/guildenstern" in path: return clGuildenstern
  if "/nimgrpc" in path: return clNimgrpc
  if "/tests/" in path or path.startsWith("tests/") or "/unittest2" in path: return clTest
  if ("/src/" in path or path.startsWith("src/")) and "/pkgs2/" notin path: return clOurs
  clOther

proc origin*(a: Access): Frame =
  for f in a.frames:
    if classOf(f.path) != clRuntime: return f
  if a.frames.len > 0: return a.frames[0]
  ("?", "?", 0)

proc classify*(r: Report): Class =
  ## the class of the report: the lowest of its accesses (ours before nimgrpc before test before guildenstern before other before runtime)
  result = clRuntime
  for a in r.accesses:
    let c = classOf(origin(a).path)
    if c < result: result = c

const failing* = {clOurs, clNimgrpc, clTest}

proc isRace*(r: Report): bool = r.what in ["data race", "heap-use-after-free", "data race on vptr (ctor/dtor vs virtual call)"] or r.what.startsWith("data race")

proc summarize*(text: string): tuple[counts: Table[string, int], failing: int, lines: seq[string]] =
  var seen = initCountTable[string]()
  for r in parseReports(text):
    if not r.isRace:
      result.counts.mgetOrPut(r.what, 0).inc
      continue
    let c = classify(r)
    result.counts.mgetOrPut($c, 0).inc
    if c in failing: inc result.failing
    let pair = $c & ": " & r.accesses.mapIt((let o = origin(it); it.thread & " " & o.fn.split("::")[^1].split('(')[0] & "@" & o.path.extractFilename & ":" & $o.line)).join(" || ")
    seen.inc pair
  for pair, n in seen.pairs: result.lines.add align($n, 3) & " " & pair
  result.lines.sort(proc (a, b: string): int = cmp(b, a))

when isMainModule:
  var bad = false
  var total = initTable[string, int]()
  var lines: seq[string]
  for log in commandLineParams():
    let s = summarize(readFile(log))
    if s.counts.len > 0:
      var cs: seq[string]
      for k, v in s.counts.pairs:
        cs.add k & "=" & $v
        total.mgetOrPut(k, 0).inc v
      cs.sort()
      echo log.extractFilename.alignLeft(44), cs.join("  ")
    if s.failing > 0: bad = true
    if s.failing > 0 or getEnv("TSAN_SHOW").len > 0: lines.add s.lines
  var ts: seq[string]
  for k, v in total.pairs: ts.add k & "=" & $v
  ts.sort()
  echo "TOTAL ", ts.join("  ")
  for l in lines: echo l
  quit(if bad: 1 else: 0)
