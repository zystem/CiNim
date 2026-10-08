## The cache of opened data keys (core/dekcache.nim): a key is kept for a short time, then asked for again.
import std/unittest
import ../../src/core/dekcache

suite "the cache of data keys":
  test "a key put in is found until its time is over, then it is gone":
    var c = initDekCache(60.0)
    c.put("t1", @[1'u8, 2, 3], 1000.0)
    check c.get("t1", 1000.0).found and c.get("t1", 1059.9).dek == @[1'u8, 2, 3]
    check not c.get("t1", 1060.0).found and c.len == 0
  test "tenants are kept apart, and one can be forgotten":
    var c = initDekCache(60.0)
    c.put("a", @[1'u8], 0.0); c.put("b", @[2'u8], 0.0)
    check c.get("a", 1.0).dek == @[1'u8] and c.get("b", 1.0).dek == @[2'u8]
    c.forget("a")
    check not c.get("a", 1.0).found and c.get("b", 1.0).found
  test "clear drops all; a cache of no time keeps nothing":
    var c = initDekCache(60.0)
    c.put("a", @[1'u8], 0.0); c.clear()
    check c.len == 0
    var z = initDekCache(0.0)
    z.put("a", @[1'u8], 0.0)
    check not z.get("a", 0.0).found
