## RUN-016 / docs/conductors.md section 12: the queues between the threads of the push channel. A message is bytes in shared memory, copied in by
## the sender and copied out and freed by the receiver (CLAUDE.md: a string allocated in one thread and freed in another crashes). Pure.
import std/[unittest, times, strutils, os]
import common/shmq

suite "RUN-016 queues between threads":
  test "a message comes out as it went in, in order":
    var q = newShmQueue()
    q.push(1, "a", "alpha")
    q.push(2, "b", "")
    q.push(3, "", "gamma\x00with\xffbytes")
    var kind: int
    var x, y: string
    check q.pop(0, kind, x, y) and kind == 1 and x == "a" and y == "alpha"
    check q.pop(0, kind, x, y) and kind == 2 and x == "b" and y == ""
    check q.pop(0, kind, x, y) and kind == 3 and x == "" and y == "gamma\x00with\xffbytes"
    check q.len == 0
    q.destroy()
  test "an empty queue answers after the time asked, and not before":
    var q = newShmQueue()
    var kind: int
    var x, y: string
    let t0 = epochTime()
    check not q.pop(120, kind, x, y)
    check epochTime() - t0 >= 0.1
    q.destroy()
  test "a waiting receiver wakes as soon as something is pushed":
    var q = newShmQueue()
    var th: Thread[ptr ShmQueue]
    proc sender(p: ptr ShmQueue) {.thread.} =
      sleep 100
      p[].push(7, "late", "x")
    createThread(th, sender, addr q)
    var kind: int
    var x, y: string
    let t0 = epochTime()
    check q.pop(5000, kind, x, y) and kind == 7 and x == "late"
    check epochTime() - t0 < 2.0
    joinThread(th)
    q.destroy()
  test "four senders and four receivers: every message arrives once and whole":
    var q = newShmQueue()
    const perSender = 2000
    type Ctx = object
      q: ptr ShmQueue
      n: int
    var senders: array[4, Thread[Ctx]]
    var receivers: array[4, Thread[Ctx]]
    var got: array[4, int]
    var sums: array[4, int]
    proc send(c: Ctx) {.thread.} =
      for i in 0 ..< perSender:
        let payload = "p" & $c.n & "-" & $i & "-" & "x".repeat(i mod 50)
        c.q[].push(c.n, $i, payload)
    proc recv(c: Ctx) {.thread.} =
      var kind: int
      var a, b: string
      while c.q[].pop(300, kind, a, b):
        let i = parseInt(a)
        if b == "p" & $kind & "-" & $i & "-" & "x".repeat(i mod 50):
          {.cast(gcsafe).}:
            got[c.n] += 1
            sums[c.n] += i
    for i in 0 ..< 4: createThread(senders[i], send, Ctx(q: addr q, n: i))
    for i in 0 ..< 4: createThread(receivers[i], recv, Ctx(q: addr q, n: i))
    joinThreads(senders)
    joinThreads(receivers)
    check got[0] + got[1] + got[2] + got[3] == 4 * perSender
    check sums[0] + sums[1] + sums[2] + sums[3] == 4 * (perSender * (perSender - 1) div 2)
    q.destroy()
