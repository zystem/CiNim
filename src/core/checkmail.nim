## Where the answer of a script check waits for the API thread that asked (PIP-016, core/preflight.nim): the worker of the push channel that heard the conductor puts it here by
## the id of the check, the API thread takes it. The two are different threads, so what crosses is not a Nim string (CLAUDE.md): the id is a fixed array and the answer is a block of
## shared memory that the taker frees. A fixed number of slots; an answer nobody takes is dropped when its slot is needed again.
import std/[locks, times, os]

const
  slots = 128
  idLen = 48

type Slot = object
  id: array[idLen, char]
  used: bool
  at: float
  data: ptr UncheckedArray[char]
  len: int

var
  boxLock: Lock
  box: array[slots, Slot]

initLock(boxLock)

proc sameId(s: Slot; id: string): bool =
  if id.len >= idLen or not s.used: return false
  for i in 0 ..< id.len:
    if s.id[i] != id[i]: return false
  s.id[id.len] == '\0'

proc clearSlot(s: var Slot) =
  if s.data != nil: deallocShared(s.data)
  s = Slot()

proc put*(id, answer: string) =
  ## safe from any thread; an id that is too long is ignored
  if id.len == 0 or id.len >= idLen: return
  {.cast(gcsafe).}:
    withLock boxLock:
      var free = -1
      var oldest = 0
      for i in 0 ..< slots:
        if box[i].sameId(id):
          free = i
          break
        if not box[i].used and free < 0: free = i
        if box[i].used and box[i].at < box[oldest].at: oldest = i
      if free < 0: free = oldest                # all are used: the oldest answer is the one nobody came for
      clearSlot(box[free])
      box[free].used = true
      box[free].at = epochTime()
      for i in 0 ..< id.len: box[free].id[i] = id[i]
      box[free].id[id.len] = '\0'
      box[free].len = answer.len
      if answer.len > 0:
        box[free].data = cast[ptr UncheckedArray[char]](allocShared(answer.len))
        copyMem(box[free].data, unsafeAddr answer[0], answer.len)

proc tryTake*(id: string): tuple[found: bool, answer: string] =
  {.cast(gcsafe).}:
    withLock boxLock:
      for i in 0 ..< slots:
        if box[i].sameId(id):
          result.found = true
          result.answer = newString(box[i].len)
          if box[i].len > 0: copyMem(addr result.answer[0], box[i].data, box[i].len)
          clearSlot(box[i])
          return

proc take*(id: string; seconds: float): tuple[found: bool, answer: string] =
  ## waits up to `seconds` for the answer
  let until = epochTime() + seconds
  while true:
    result = tryTake(id)
    if result.found or epochTime() >= until: return
    sleep 10
