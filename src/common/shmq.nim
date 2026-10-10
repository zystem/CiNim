## A queue between threads for the push channel (docs/conductors.md section 12). A message is a number and two byte strings, copied into shared
## memory by the sender and copied out and freed by the receiver: no Nim string or ref is ever allocated in one thread and freed in another (which
## crashes - CLAUDE.md). One lock and one condition for the queue; the receiver may wait with a time limit.
import std/[locks, times]

type Timespec {.importc: "struct timespec", header: "<time.h>".} = object
  tv_sec: clong
  tv_nsec: clong

proc pthreadCondTimedwait(c, m, ts: pointer): cint {.importc: "pthread_cond_timedwait", header: "<pthread.h>".}

proc timedWait(c: var Cond; l: var Lock; ms: int): bool =
  ## wait for a signal for at most `ms` milliseconds (std/locks has no timed wait); false when the time ran out
  let t = epochTime() + ms.float / 1000.0
  var ts = Timespec(tv_sec: clong(t), tv_nsec: clong((t - float(clong(t))) * 1e9))
  pthreadCondTimedwait(addr c, addr l, addr ts) == 0

type
  Node = object
    next: ptr Node
    kind: int
    a, b: ptr UncheckedArray[char]
    la, lb: int
  ShmQueue* = object
    lock: Lock
    cond: Cond
    head, tail: ptr Node
    count: int

proc copyIn(s: string): ptr UncheckedArray[char] =
  if s.len == 0: return nil
  result = cast[ptr UncheckedArray[char]](allocShared(s.len))
  copyMem(result, unsafeAddr s[0], s.len)

proc copyOut(p: ptr UncheckedArray[char]; n: int): string =
  result = newString(n)
  if n > 0: copyMem(addr result[0], p, n)

proc initShmQueue*(q: var ShmQueue) =
  ## in place: a lock must not be copied once it is made
  initLock(q.lock)
  initCond(q.cond)

proc newShmQueue*(): ShmQueue =
  initShmQueue(result)

proc len*(q: var ShmQueue): int =
  acquire(q.lock)
  result = q.count
  release(q.lock)

proc push*(q: var ShmQueue; kind: int; a, b: string) =
  let n = cast[ptr Node](allocShared0(sizeof(Node)))
  n.kind = kind
  n.a = copyIn(a); n.la = a.len
  n.b = copyIn(b); n.lb = b.len
  acquire(q.lock)
  if q.tail == nil: q.head = n
  else: q.tail.next = n
  q.tail = n
  inc q.count
  signal(q.cond)
  release(q.lock)

proc pop*(q: var ShmQueue; timeoutMs: int; kind: var int; a, b: var string): bool =
  ## the oldest message, waiting up to `timeoutMs` for one; false if none came
  var n: ptr Node
  acquire(q.lock)
  if q.head == nil and timeoutMs > 0:
    # wait for a push or the time; a spurious wake-up or a message taken by another receiver sends it back to waiting for what is left of the time
    let deadline = epochTime() + timeoutMs.float / 1000.0
    while q.head == nil:
      let left = int((deadline - epochTime()) * 1000)
      if left <= 0: break
      discard timedWait(q.cond, q.lock, left)
  if q.head != nil:
    n = q.head
    q.head = n.next
    if q.head == nil: q.tail = nil
    dec q.count
  release(q.lock)
  if n == nil: return false
  kind = n.kind
  a = copyOut(n.a, n.la)
  b = copyOut(n.b, n.lb)
  if n.a != nil: deallocShared(n.a)
  if n.b != nil: deallocShared(n.b)
  deallocShared(n)
  true

proc destroy*(q: var ShmQueue) =
  var kind: int
  var a, b: string
  while q.pop(0, kind, a, b): discard
  deinitCond(q.cond)
  deinitLock(q.lock)
