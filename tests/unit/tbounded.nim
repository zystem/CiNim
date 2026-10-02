import std/unittest
import common/bounded

suite "E-003 bounded queue":
  test "E-003 rejects push at capacity and never grows":
    var q = initBoundedQueue[int](3)
    check q.tryPush(1) and q.tryPush(2) and q.tryPush(3)
    check not q.tryPush(4)
    check q.len == 3 and q.capacity == 3

  test "E-003 preserves FIFO order across wraparound":
    var q = initBoundedQueue[string](2)
    var x: string
    check q.tryPush("a") and q.tryPush("b")
    check q.tryPop(x) and x == "a"
    check q.tryPush("c")
    check q.tryPop(x) and x == "b"
    check q.tryPop(x) and x == "c"
    check not q.tryPop(x)

  test "E-003 long churn keeps memory flat":
    var q = initBoundedQueue[string](8)
    var x: string
    let before = getOccupiedMem()
    for i in 0 ..< 200_000:
      discard q.tryPush("item" & $i)
      discard q.tryPop(x)
    check getOccupiedMem() - before < 64 * 1024
