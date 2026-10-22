## SHD-004, D-66: the identifiers of a shard: the shard's prefix and the time in microseconds in base32, made in the core, which is one process.
import std/[unittest, strutils, sequtils, algorithm, sets, os]
import ../../src/common/ids

const alphabet = "0123456789abcdefghjkmnpqrstvwxyz"

suite "SHD-004 the identifiers of a shard (D-66)":
  test "SHD-004 an id is the shard's prefix and 11 characters of base32, the time in microseconds":
    let id = newId()
    check id.startsWith("s1_") and id.len == 14
    check id[3 .. ^1].allIt(it in alphabet)
    check idAt(0) == "s1_00000000000"
    check idAt(1) == "s1_00000000001"
    check idAt(32) == "s1_00000000010"
    check idAt(1_792_484_469_123_456'i64) == "s1_1jy8580rac0"     # a time of 2026 in microseconds (computed apart, in Python)
  test "SHD-004 the order of the strings is the order of the times, so an id is the cursor of a list":
    var ids: seq[string]
    for ns in [5'i64, 31, 32, 1000, 1_000_000_000, 1_792_484_469_123_456, 1_792_484_469_123_457, 36_028_797_018_963_967]:
      ids.add idAt(ns)
    check ids == ids.sorted
    check ids.toHashSet.len == ids.len
  test "SHD-004 two ids made at the same microsecond (or when the clock goes back) are still different, the later one the greater":
    var clock: IdClock
    let a = clock.next(100)
    let b = clock.next(100)               # the same time
    let c = clock.next(50)                # the clock went back
    let d = clock.next(500)
    check a == 100 and b == 101 and c == 102 and d == 500
  test "SHD-004 a million ids in a row are all different and rise":
    var prev = newId()
    for i in 0 ..< 1_000_000:
      let id = newId()
      doAssert id > prev, "id " & id & " does not rise above " & prev
      prev = id
    check true
  test "SHD-004 threads that make ids at once never make the same one":
    const threads = 8
    const each = 20000
    var found: array[threads, seq[string]]
    var workers: array[threads, Thread[int]]
    proc work(n: int) {.thread.} =
      {.gcsafe.}:
        for i in 0 ..< each: found[n].add newId()
    for n in 0 ..< threads: createThread(workers[n], work, n)
    joinThreads(workers)
    var all = initHashSet[string]()
    for n in 0 ..< threads:
      for id in found[n]: all.incl id
    check all.len == threads * each
  test "SHD-004 an id is good for a Kubernetes name: lowercase letters and digits, with the underscore turned into a dash (a Pod's name, which starts with the shard's prefix)":
    let name = newId().replace("_", "-") & "-4294967295-99"
    check name.len <= 63 and name.allIt(it in {'a' .. 'z', '0' .. '9', '-'})
  test "SHD-004 the time of an id can be read back":
    check idTimeUs(idAt(1_792_484_469_123_456'i64)) == 1_792_484_469_123_456'i64
