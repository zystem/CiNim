## RUN-016 / docs/conductors.md section 12: whoever creates work for an organisation says so, and the push channel looks at that organisation
## at once. The ids cross threads, so they are kept in fixed arrays (CLAUDE.md: a string made in one thread and freed in another crashes).
import std/[unittest, sequtils, algorithm, strutils]
import core/workkick

suite "RUN-016 work kicks":
  test "a kick is taken once, the same organisation twice counts once":
    drainKicks()
    kickProfile("p-1")
    kickProfile("p-2")
    kickProfile("p-1")
    check takeKicks().sorted == @["p-1", "p-2"]
    check takeKicks().len == 0
  test "kicks come from other threads and arrive whole":
    drainKicks()
    var ths: array[4, Thread[int]]
    proc worker(n: int) {.thread.} =
      for i in 0 ..< 20: kickProfile("prof-" & $n & "-" & $i)
    for i in 0 ..< 4: createThread(ths[i], worker, i)
    joinThreads(ths)
    let got = takeKicks()
    check got.len == 80
    check got.allIt(it.len > 7 and it[0 ..< 5] == "prof-")
  test "a flood beyond the buffer is not lost: the next take says 'look at everyone'":
    drainKicks()
    for i in 0 ..< 1000: kickProfile("flood-" & $i)
    check kickedAll()
    check not kickedAll()                     # said once
  test "an empty or overlong id is ignored":
    drainKicks()
    kickProfile("")
    kickProfile("x".repeat(200))
    check takeKicks().len == 0
