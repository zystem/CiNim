## Application metrics declaration and sample parsing (docs/metrics.md).
import std/[unittest, options]
import shim/appmetrics

suite "declaration":
  test "the canonical JSON from the Lua sandbox is read back":
    let d = parseDeclaration("""{"runtime":"jvm","scrape":[{"format":"prometheus","include":["jvm_*"],"interval":10,"name":"app1","timeout":5,"url":"http://127.0.0.1:9404/metrics"}]}""")
    check d.isSome
    check d.get.runtime == "jvm" and d.get.scrapes.len == 1
    check d.get.scrapes[0].url == "http://127.0.0.1:9404/metrics" and d.get.scrapes[0].interval == 10
    check d.get.scrapes[0].patterns == @["jvm_*"]
  test "nothing or garbage is no declaration (never stops the step)":
    check parseDeclaration("").isNone
    check parseDeclaration("{broken").isNone
    check parseDeclaration("""{"scrape":[{"nourl":1}]}""").isNone

suite "wildcards":
  test "patterns":
    check wildcardMatch("jvm_*", "jvm_memory_bytes_used")
    check wildcardMatch("*_total", "http_requests_total")
    check wildcardMatch("a*c*e", "abcde")
    check not wildcardMatch("jvm_*", "go_gc")
    check wildcardMatch("exact", "exact") and not wildcardMatch("exact", "exactly")

suite "prometheus text":
  const text = """
# HELP jvm_memory_bytes_used Used bytes
# TYPE jvm_memory_bytes_used gauge
jvm_memory_bytes_used{area="heap"} 1000
jvm_memory_bytes_used{area="nonheap"} 234.5
jvm_threads_current 42 1700000000
go_goroutines 7
bad name 1
nan_metric NaN
inf_metric +Inf
"""
  test "labels are summed away, timestamps and non-finite values dropped":
    let s = parsePrometheus(text, @[])
    check s.len == 3
    check s[0].name == "jvm_memory_bytes_used" and s[0].value == 1234.5
    check s[1].name == "jvm_threads_current" and s[1].value == 42
  test "include filters by name":
    let s = parsePrometheus(text, @["go_*"])
    check s.len == 1 and s[0].name == "go_goroutines"
  test "the sample count is bounded":
    var big = ""
    for i in 0 ..< 500: big.add "m" & $i & " 1\n"
    check parsePrometheus(big, @[]).len == maxSamples

suite "expvar":
  test "Go /debug/vars becomes go_* numbers":
    let s = parseExpvar("""{"cmdline":["x"],"memstats":{"Alloc":1024,"NumGC":3,"BySize":[{"Size":1}],"PauseNs":[1,2]},"custom.count":5}""", @[])
    var names: seq[string]
    for x in s: names.add x.name
    check "go_memstats_alloc" in names and "go_memstats_numgc" in names and "go_custom_count" in names
    check "go_memstats_bysize" notin names
  test "not JSON -> nothing":
    check parseExpvar("<html>", @[]).len == 0
