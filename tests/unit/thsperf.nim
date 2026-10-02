## HotSpot's counters read straight from its hsperfdata file (docs/metrics.md). Uses a real JVM when the machine has one.
import std/[unittest, os, osproc, strutils, tables, times]
import shim/hsperf

suite "hsperfdata parser":
  test "garbage and truncated files are no counters, never an exception":
    check parsePerfData("").len == 0
    check parsePerfData("not a perf file at all, just text").len == 0
    check parsePerfData("\xCA\xFE\xC0\xC0\x01\x02\x00\x01" & repeat("\0", 10)).len == 0
  test "a real JVM: threads, heap, GC, classes":
    if findExe("java").len == 0 or findExe("javac").len == 0:
      skip()
    else:
      let d = getTempDir() / "hsperf-test"
      removeDir d
      createDir d
      writeFile(d / "Spin.java", "public class Spin { public static void main(String[] a) throws Exception { byte[] k = new byte[20 << 20]; System.gc(); Thread.sleep(30000); } }")
      check execCmd("cd " & d & " && javac Spin.java") == 0
      let p = startProcess(findExe("java"), args = @["-cp", d, "Spin"], options = {poStdErrToStdOut})
      defer: (p.kill(); p.close())
      var f = ""
      for _ in 0 ..< 60:
        f = findFile(p.processID)
        if f.len > 0 and f.endsWith($p.processID): break
        sleep 250
      check f.endsWith($p.processID)
      sleep 1500
      let c = parsePerfData(readFile(f))
      check c.len > 50
      check c["java.threads.live"].num >= 1
      let m = jvmMetrics(c)
      var got: Table[string, float]
      for (n, v) in m: got[n] = v
      check got["jvm_up"] == 1.0
      check got["jvm_heap_used_bytes"] > 20.0 * 1024 * 1024        # the 20 MiB array is live
      check got["jvm_gc_collections_total"] >= 1.0                  # System.gc()
      check got["jvm_threads_current"] >= 1.0 and got["jvm_classes_loaded"] > 0.0
