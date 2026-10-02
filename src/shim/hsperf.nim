## HotSpot's performance counters (hsperfdata, the file `jstat` reads), parsed without any JDK tooling (Lua `metrics.runtime =
## "jvm"`, docs/metrics.md). The JVM keeps a small memory-mapped file /tmp/hsperfdata_<user>/<pid> with its counters (GC, heap
## spaces, threads, classes). The format is stable and documented in the HotSpot sources (perfMemory / PerfData); it needs no
## attach, no JMX, no library in the image - only that PerfData is on (the default; -XX:-UsePerfData turns it off) and that the
## shim can read the file (same user, same /tmp). Pure parsing here; finding the file is `findFile`.
import std/[os, strutils, tables, algorithm, options, times]

type PerfValue* = object
  isString*: bool
  num*: int64
  str*: string
  units*: int                 ## 1 none, 2 bytes, 3 ticks, 4 events, 5 string, 6 hertz

func rd32(s: string; o: int; big: bool): int32 =
  if o + 4 > s.len: raise newException(ValueError, "short read")
  var v: uint32
  if big:
    v = (uint32(ord(s[o])) shl 24) or (uint32(ord(s[o + 1])) shl 16) or (uint32(ord(s[o + 2])) shl 8) or uint32(ord(s[o + 3]))
  else:
    v = (uint32(ord(s[o + 3])) shl 24) or (uint32(ord(s[o + 2])) shl 16) or (uint32(ord(s[o + 1])) shl 8) or uint32(ord(s[o]))
  cast[int32](v)

func rd64(s: string; o: int; big: bool): int64 =
  if o + 8 > s.len: raise newException(ValueError, "short read")
  var v: uint64
  for i in 0 ..< 8:
    let b = uint64(ord(s[if big: o + i else: o + 7 - i]))
    v = (v shl 8) or b
  cast[int64](v)

func parsePerfData*(data: string): Table[string, PerfValue] =
  ## Every counter in the file. A truncated or foreign file gives what could be read, never an exception.
  if data.len < 32: return
  # the magic 0xcafec0c0 is always written big-endian; byte 4 tells the byte order of everything else
  if data[0 ..< 4] != "\xCA\xFE\xC0\xC0": return
  let big = data[4] == '\0'
  try:
    let entryOffset = int(rd32(data, 24, big))
    let numEntries = int(rd32(data, 28, big))
    var pos = entryOffset
    for _ in 0 ..< min(numEntries, 4096):
      if pos < 0 or pos + 20 > data.len: break
      let length = int(rd32(data, pos, big))
      if length < 20: break
      let nameOff = int(rd32(data, pos + 4, big))
      let vecLen = int(rd32(data, pos + 8, big))
      let dtype = data[pos + 12]
      let units = ord(data[pos + 14])
      let dataOff = int(rd32(data, pos + 16, big))
      let nameStart = pos + nameOff
      if nameStart >= data.len: break
      var nameEnd = nameStart
      while nameEnd < data.len and data[nameEnd] != '\0': inc nameEnd
      let name = data[nameStart ..< nameEnd]
      var v = PerfValue(units: units)
      if dtype == 'J' and vecLen == 0:
        v.num = rd64(data, pos + dataOff, big)
      elif dtype == 'B':
        v.isString = true
        var e = pos + dataOff
        let stop = min(pos + dataOff + vecLen, data.len)
        while e < stop and data[e] != '\0': inc e
        v.str = data[pos + dataOff ..< e]
      else:
        pos += length
        continue
      result[name] = v
      pos += length
  except ValueError:
    discard

func jvmMetrics*(c: Table[string, PerfValue]): seq[(string, float)] =
  ## The counters worth having, named like the JMX exporter's (jvm_*), in base units. Whatever the JVM does not have
  ## (another collector, an older JDK) is simply absent.
  func num(c: Table[string, PerfValue]; n: string): Option[int64] =
    if n in c and not c[n].isString: some c[n].num else: none(int64)
  let freq = if "sun.os.hrt.frequency" in c: max(1'i64, c["sun.os.hrt.frequency"].num) else: 1_000_000_000'i64
  proc add(r: var seq[(string, float)]; name: string; v: Option[int64]; scale = 1.0) =
    if v.isSome: r.add (name, float(v.get) * scale)
  result.add ("jvm_up", 1.0)
  result.add("jvm_threads_current", num(c, "java.threads.live"))
  result.add("jvm_threads_daemon", num(c, "java.threads.daemon"))
  result.add("jvm_classes_loaded", num(c, "java.cls.loadedClasses"))
  result.add("jvm_classes_unloaded_total", num(c, "java.cls.unloadedClasses"))
  var used, capacity = 0'i64
  var any = false
  for n, v in c:
    if v.isString: continue
    if n.startsWith("sun.gc.generation.") and n.endsWith(".used") and ".space." in n:
      used += v.num
      any = true
    elif n.startsWith("sun.gc.generation.") and n.endsWith(".capacity") and ".space." in n:
      capacity += v.num
  if any:
    result.add ("jvm_heap_used_bytes", float(used))
    if capacity > 0: result.add ("jvm_heap_capacity_bytes", float(capacity))
  var gcCount, gcTicks = 0'i64
  for n, v in c:
    if v.isString: continue
    if n.startsWith("sun.gc.collector.") and n.endsWith(".invocations"): gcCount += v.num
    elif n.startsWith("sun.gc.collector.") and n.endsWith(".time"): gcTicks += v.num
  result.add ("jvm_gc_collections_total", float(gcCount))
  result.add ("jvm_gc_time_seconds_total", float(gcTicks) / float(freq))
  result.add("jvm_metaspace_used_bytes", num(c, "sun.gc.metaspace.used"))
  result.add("jvm_safepoints_total", num(c, "sun.rt.safepoints"))

proc findFile*(pid: int; tmpRoot = "/tmp"): string =
  ## The hsperfdata file of `pid` (or of a JVM the build started: the command is often a wrapper such as `sh -c` or `mvn`, so
  ## the newest file of the step's user is taken when `pid` itself has none). "" = no JVM seen.
  for dir in walkDirs(tmpRoot / "hsperfdata_*"):
    let direct = dir / $pid
    if fileExists(direct): return direct
  var best = ""
  var bestTime = 0.0
  for dir in walkDirs(tmpRoot / "hsperfdata_*"):
    for f in walkFiles(dir / "*"):
      if not extractFilename(f).allCharsInSet({'0' .. '9'}): continue
      let t = getLastModificationTime(f).toUnixFloat
      if t > bestTime:
        bestTime = t
        best = f
  best
