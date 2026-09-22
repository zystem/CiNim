## Fixed-capacity FIFO ring buffer. Every queue in the platform is bounded (E-003).

type
  BoundedQueue*[T] = object
    buf: seq[T]
    head, count: int

proc initBoundedQueue*[T](capacity: int): BoundedQueue[T] =
  doAssert capacity > 0
  BoundedQueue[T](buf: newSeq[T](capacity))

proc capacity*[T](q: BoundedQueue[T]): int = q.buf.len
proc len*[T](q: BoundedQueue[T]): int = q.count

proc tryPush*[T](q: var BoundedQueue[T]; x: sink T): bool =
  ## False when full: the caller applies backpressure instead of growing.
  if q.count == q.buf.len: return false
  q.buf[(q.head + q.count) mod q.buf.len] = x
  inc q.count
  true

proc tryPop*[T](q: var BoundedQueue[T]; x: var T): bool =
  if q.count == 0: return false
  x = move q.buf[q.head]
  q.head = (q.head + 1) mod q.buf.len
  dec q.count
  true
