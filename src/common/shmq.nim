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
    bBase: pointer               # when `b` points into a block that starts earlier (pushOwned): the block to free
  ShmQueue* = object
    lock: Lock
    cond: Cond
    head, tail: ptr Node
    count: int

proc cMalloc(n: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc shmAlloc*(n: int): pointer = cMalloc(csize_t(max(n, 1)))
  ## memory that any thread may free, a ZeroMQ I/O thread included (it knows nothing of the allocator of Nim): plain `malloc`
proc shmFree*(p: pointer) = cFree(p)

proc newNode(): ptr Node =
  result = cast[ptr Node](shmAlloc(sizeof(Node)))
  zeroMem(result, sizeof(Node))

proc copyIn(s: string): ptr UncheckedArray[char] =
  if s.len == 0: return nil
  result = cast[ptr UncheckedArray[char]](shmAlloc(s.len))
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
  let n = newNode()
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

proc pushOwned*(q: var ShmQueue; kind: int; a: string; base: pointer; b: ptr UncheckedArray[char]; lb: int) =
  ## `b` (`lb` bytes, inside the block `base` made with `shmAlloc`) goes in without a copy, and the queue frees `base` itself unless the receiver takes the block with `popOwned`
  let n = newNode()
  n.kind = kind
  n.a = copyIn(a); n.la = a.len
  n.b = b; n.lb = lb; n.bBase = base
  acquire(q.lock)
  if q.tail == nil: q.head = n
  else: q.tail.next = n
  q.tail = n
  inc q.count
  signal(q.cond)
  release(q.lock)

proc popNode(q: var ShmQueue; timeoutMs: int): ptr Node =
  acquire(q.lock)
  if q.head == nil and timeoutMs > 0:
    let deadline = epochTime() + timeoutMs.float / 1000.0
    while q.head == nil:
      let left = int((deadline - epochTime()) * 1000)
      if left <= 0: break
      discard timedWait(q.cond, q.lock, left)
  if q.head != nil:
    result = q.head
    q.head = result.next
    if q.head == nil: q.tail = nil
    dec q.count
  release(q.lock)

proc popOwned*(q: var ShmQueue; timeoutMs: int; kind: var int; a: var string; b: var ptr UncheckedArray[char]; lb: var int; base: var pointer): bool =
  ## like `pop`, but the second part is not copied: the caller gets the block (`base`, to free with `shmFree`) and the bytes in it (`b`, `lb`)
  let n = popNode(q, timeoutMs)
  if n == nil: return false
  kind = n.kind
  a = copyOut(n.a, n.la)
  if n.a != nil: shmFree(n.a)
  b = n.b; lb = n.lb; base = if n.bBase != nil: n.bBase else: cast[pointer](n.b)
  shmFree(n)
  true

proc pop*(q: var ShmQueue; timeoutMs: int; kind: var int; a, b: var string): bool =
  ## the oldest message, waiting up to `timeoutMs` for one; false if none came. A spurious wake-up or a message taken by another receiver sends the wait back to what is left of the time
  let n = popNode(q, timeoutMs)
  if n == nil: return false
  kind = n.kind
  a = copyOut(n.a, n.la)
  b = copyOut(n.b, n.lb)
  if n.a != nil: shmFree(n.a)
  if n.bBase != nil: shmFree(n.bBase)
  elif n.b != nil: shmFree(n.b)
  shmFree(n)
  true

proc destroy*(q: var ShmQueue) =
  var kind: int
  var a, b: string
  while q.pop(0, kind, a, b): discard
  deinitCond(q.cond)
  deinitLock(q.lock)
