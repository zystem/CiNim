## Resource metrics of the step's container, sampled by the shim (D-29). What a CI wants to know about a step is
## the same for any language: CPU seconds, throttling, peak memory, OOM kills, process/thread/fd counts, I/O. All of it is
## in the container's cgroup and in /proc - no cooperation from the step, no tooling in the image - so the shim reads it
## itself (cgroup v2, with a v1 fallback). Language runtimes (JVM, Go, ...) are layered on top in runtimemetrics.nim.
##
## The shim sends the numbers to core inside its heartbeat (ShimStatus.metrics); core renders them for Prometheus as
## aggregates (Pods are short-lived: scraping them or one series per Pod would be the wrong tool). The final numbers also
## go into the Pod log's closing event, and an `oom_kills` > 0 turns "killed" into a verdict of its own: out of memory
## is the step's problem, not an infrastructure loss to retry (podverdict, retrypolicy).
##
## The parsers are pure (text in, numbers out) and unit-tested; `sample` only reads files.
import std/[os, strutils, tables, parseutils]

type
  Usage* = object
    cpuUsec*, cpuUserUsec*, cpuSystemUsec*: int64
    throttledUsec*, throttledPeriods*: int64      ## CPU limit hit: the step was slowed, not slow
    memBytes*, memPeakBytes*, memLimitBytes*: int64   ## limit < 0 = unlimited
    oomKills*: int64
    pids*: int64
    ioReadBytes*, ioWriteBytes*: int64
    procRssBytes*: int64                           ## the step's main process (VmRSS), as opposed to the whole cgroup
    procThreads*, procFds*: int64
    ctxVoluntary*, ctxInvoluntary*: int64
    ok*: bool                                      ## at least the cgroup was readable

func parseKeyValue*(text: string): Table[string, int64] =
  ## "key value" per line (cpu.stat, memory.events, ...); lines that do not fit are skipped.
  for line in text.splitLines:
    let parts = line.splitWhitespace
    if parts.len == 2:
      var v: int64
      if parseBiggestInt(parts[1], v) == parts[1].len: result[parts[0]] = v

func parseIoStat*(text: string): tuple[read, write: int64] =
  ## io.stat: "8:0 rbytes=1 wbytes=2 rios=.. wios=.. dbytes=.." per device; summed over devices.
  for line in text.splitLines:
    for field in line.splitWhitespace:
      if field.startsWith("rbytes="): result.read += parseBiggestInt(field[7 .. ^1])
      elif field.startsWith("wbytes="): result.write += parseBiggestInt(field[7 .. ^1])

func parseProcStatus*(text: string): tuple[rssBytes, threads, ctxVol, ctxInvol: int64] =
  ## /proc/<pid>/status: VmRSS is in kB.
  for line in text.splitLines:
    let c = line.find(':')
    if c < 0: continue
    let key = line[0 ..< c]
    let val = line[c + 1 .. ^1].strip
    var n: int64
    case key
    of "VmRSS":
      if parseBiggestInt(val.split(' ')[0], n) > 0: result.rssBytes = n * 1024
    of "Threads":
      if parseBiggestInt(val, n) > 0: result.threads = n
    of "voluntary_ctxt_switches":
      if parseBiggestInt(val, n) > 0: result.ctxVol = n
    of "nonvoluntary_ctxt_switches":
      if parseBiggestInt(val, n) > 0: result.ctxInvol = n
    else: discard

func parseLimit*(text: string): int64 =
  ## memory.max: a number or "max" (= unlimited, -1). cgroup v1 reports a huge number for unlimited.
  let t = text.strip
  if t == "max" or t.len == 0: return -1
  var n: int64
  if parseBiggestInt(t, n) != t.len: return -1
  if n >= (1'i64 shl 60): -1 else: n

proc readOpt(path: string): string =
  try: readFile(path) except CatchableError: ""

proc readInt(path: string): int64 =
  let t = readOpt(path).strip
  var n: int64
  if t.len > 0 and parseBiggestInt(t, n) == t.len: n else: 0

proc sample*(pid: int; cgroupRoot = "/sys/fs/cgroup"; procRoot = "/proc"): Usage =
  ## One reading. Missing files leave zeros (a node without a controller must not break the shim).
  let v2 = fileExists(cgroupRoot / "cgroup.controllers")
  if v2:
    let cpu = parseKeyValue(readOpt(cgroupRoot / "cpu.stat"))
    result.cpuUsec = cpu.getOrDefault("usage_usec")
    result.cpuUserUsec = cpu.getOrDefault("user_usec")
    result.cpuSystemUsec = cpu.getOrDefault("system_usec")
    result.throttledUsec = cpu.getOrDefault("throttled_usec")
    result.throttledPeriods = cpu.getOrDefault("nr_throttled")
    result.memBytes = readInt(cgroupRoot / "memory.current")
    result.memPeakBytes = readInt(cgroupRoot / "memory.peak")      # kernel >= 5.19; else the shim's own max (see maxed)
    result.memLimitBytes = parseLimit(readOpt(cgroupRoot / "memory.max"))
    result.oomKills = parseKeyValue(readOpt(cgroupRoot / "memory.events")).getOrDefault("oom_kill")
    result.pids = readInt(cgroupRoot / "pids.current")
    let io = parseIoStat(readOpt(cgroupRoot / "io.stat"))
    result.ioReadBytes = io.read
    result.ioWriteBytes = io.write
    result.ok = fileExists(cgroupRoot / "cpu.stat")
  else:                       # cgroup v1: the controllers are separate mounts
    let cpuacct = cgroupRoot / "cpuacct"
    let mem = cgroupRoot / "memory"
    result.cpuUsec = readInt(cpuacct / "cpuacct.usage") div 1000
    let thr = parseKeyValue(readOpt(cgroupRoot / "cpu" / "cpu.stat"))
    result.throttledPeriods = thr.getOrDefault("nr_throttled")
    result.throttledUsec = thr.getOrDefault("throttled_time") div 1000
    result.memBytes = readInt(mem / "memory.usage_in_bytes")
    result.memPeakBytes = readInt(mem / "memory.max_usage_in_bytes")
    result.memLimitBytes = parseLimit(readOpt(mem / "memory.limit_in_bytes"))
    result.oomKills = parseKeyValue(readOpt(mem / "memory.oom_control")).getOrDefault("oom_kill")
    result.pids = readInt(cgroupRoot / "pids" / "pids.current")
    result.ok = fileExists(mem / "memory.usage_in_bytes")
  if pid > 0:
    let st = parseProcStatus(readOpt(procRoot / $pid / "status"))
    result.procRssBytes = st.rssBytes
    result.procThreads = st.threads
    result.ctxVoluntary = st.ctxVol
    result.ctxInvoluntary = st.ctxInvol
    try:
      for _ in walkDir(procRoot / $pid / "fd"): inc result.procFds
    except CatchableError: discard

func maxed*(cur, previous: Usage): Usage =
  ## Peaks survive across samples: the kernel's own memory.peak is missing on older kernels, and the process's RSS peak
  ## is not tracked by it at all.
  result = cur
  result.memPeakBytes = max(cur.memPeakBytes, max(cur.memBytes, previous.memPeakBytes))

func toMetrics*(u: Usage): seq[(string, float)] =
  ## Names follow the Prometheus conventions of the node/cadvisor exporters (base units, _total for counters).
  result = @[
    ("cinim_step_cpu_seconds_total", u.cpuUsec.float / 1e6),
    ("cinim_step_cpu_throttled_seconds_total", u.throttledUsec.float / 1e6),
    ("cinim_step_cpu_throttled_periods_total", u.throttledPeriods.float),
    ("cinim_step_memory_bytes", u.memBytes.float),
    ("cinim_step_memory_peak_bytes", u.memPeakBytes.float),
    ("cinim_step_memory_limit_bytes", u.memLimitBytes.float),
    ("cinim_step_oom_kills_total", u.oomKills.float),
    ("cinim_step_pids", u.pids.float),
    ("cinim_step_io_read_bytes_total", u.ioReadBytes.float),
    ("cinim_step_io_write_bytes_total", u.ioWriteBytes.float),
    ("cinim_step_process_rss_bytes", u.procRssBytes.float),
    ("cinim_step_process_threads", u.procThreads.float),
    ("cinim_step_process_open_fds", u.procFds.float),
    ("cinim_step_context_switches_voluntary_total", u.ctxVoluntary.float),
    ("cinim_step_context_switches_involuntary_total", u.ctxInvoluntary.float)]
