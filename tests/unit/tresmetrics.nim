## D-29: the shim's resource metrics - pure parsers, and a fake cgroup/proc tree for `sample`.
import std/[unittest, os, tables]
import shim/resmetrics

suite "parsers":
  test "cpu.stat / memory.events key-value":
    let kv = parseKeyValue("usage_usec 5000000\nuser_usec 3000000\nsystem_usec 2000000\nnr_throttled 7\nthrottled_usec 1500\n")
    check kv["usage_usec"] == 5_000_000 and kv["nr_throttled"] == 7
    check parseKeyValue("garbage\nkey notanumber\noom_kill 2\n")["oom_kill"] == 2

  test "io.stat is summed over devices":
    let io = parseIoStat("8:0 rbytes=100 wbytes=200 rios=1 wios=2 dbytes=0 dios=0\n259:0 rbytes=5 wbytes=6 rios=1 wios=1\n")
    check io.read == 105 and io.write == 206

  test "/proc/<pid>/status":
    let st = parseProcStatus("Name:\tjava\nVmRSS:\t  204800 kB\nThreads:\t42\nvoluntary_ctxt_switches:\t10\nnonvoluntary_ctxt_switches:\t3\n")
    check st.rssBytes == 204800 * 1024 and st.threads == 42 and st.ctxVol == 10 and st.ctxInvol == 3

  test "limits: max, numbers, and cgroup v1's 'unlimited'":
    check parseLimit("max\n") == -1
    check parseLimit("536870912\n") == 536870912
    check parseLimit("9223372036854771712\n") == -1
    check parseLimit("") == -1

suite "sample":
  test "a cgroup v2 tree plus a /proc entry":
    let root = getTempDir() / "tresmetrics"
    removeDir root
    createDir root / "cg"
    createDir root / "proc" / "77" / "fd"
    writeFile root / "cg" / "cgroup.controllers", "cpu memory io pids"
    writeFile root / "cg" / "cpu.stat", "usage_usec 2500000\nuser_usec 2000000\nsystem_usec 500000\nnr_throttled 4\nthrottled_usec 9000\n"
    writeFile root / "cg" / "memory.current", "104857600\n"
    writeFile root / "cg" / "memory.peak", "209715200\n"
    writeFile root / "cg" / "memory.max", "1073741824\n"
    writeFile root / "cg" / "memory.events", "low 0\nhigh 0\nmax 1\noom 1\noom_kill 1\n"
    writeFile root / "cg" / "pids.current", "12\n"
    writeFile root / "cg" / "io.stat", "8:0 rbytes=10 wbytes=20\n"
    writeFile root / "proc" / "77" / "status", "VmRSS:\t1000 kB\nThreads:\t3\n"
    writeFile root / "proc" / "77" / "fd" / "0", ""
    writeFile root / "proc" / "77" / "fd" / "1", ""
    let u = sample(77, root / "cg", root / "proc")
    check u.ok and u.cpuUsec == 2_500_000 and u.throttledPeriods == 4
    check u.memBytes == 104857600 and u.memPeakBytes == 209715200 and u.memLimitBytes == 1073741824
    check u.oomKills == 1 and u.pids == 12 and u.ioReadBytes == 10 and u.ioWriteBytes == 20
    check u.procRssBytes == 1_024_000 and u.procThreads == 3 and u.procFds == 2
    removeDir root

  test "nothing readable leaves zeros and ok=false (never raises)":
    let u = sample(0, "/nonexistent/cg", "/nonexistent/proc")
    check not u.ok and u.cpuUsec == 0

  test "peaks survive samples":
    var prev = Usage(memPeakBytes: 500)
    check maxed(Usage(memBytes: 300), prev).memPeakBytes == 500
    check maxed(Usage(memBytes: 900), prev).memPeakBytes == 900

  test "the real host can be sampled":
    let u = sample(getCurrentProcessId())
    check u.procRssBytes > 0
