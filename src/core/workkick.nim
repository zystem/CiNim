## "There is work for this organisation": the thread that makes a step, changes a limit or frees a place tells the push channel, which looks at
## that organisation's controller at once (docs/conductors.md section 12). Ids cross threads in fixed arrays under a lock, never as strings
## (a string allocated in one thread and freed in another crashes - CLAUDE.md); the taker makes its own strings.
import std/locks

const
  kickSlots = 256
  kickLen = 64

type Slot = array[kickLen, char]

var
  kickLock: Lock
  slots: array[kickSlots, Slot]
  used: int
  overflowed: bool

initLock(kickLock)

proc same(s: Slot; id: string): bool =
  if id.len >= kickLen: return false
  for i in 0 ..< id.len:
    if s[i] != id[i]: return false
  s[id.len] == '\0'

proc kickProfile*(profileId: string) =
  ## safe from any thread; an empty or overlong id is ignored
  if profileId.len == 0 or profileId.len >= kickLen: return
  {.cast(gcsafe).}:
    withLock kickLock:
      for i in 0 ..< used:
        if slots[i].same(profileId): return
      if used >= kickSlots:
        overflowed = true
        return
      for i in 0 ..< profileId.len: slots[used][i] = profileId[i]
      slots[used][profileId.len] = '\0'
      inc used

proc takeKicks*(): seq[string] =
  ## the organisations kicked since the last call, each once
  {.cast(gcsafe).}:
    withLock kickLock:
      for i in 0 ..< used:
        var s = ""
        var j = 0
        while j < kickLen and slots[i][j] != '\0':
          s.add slots[i][j]
          inc j
        result.add s
      used = 0

proc kickedAll*(): bool =
  ## true once after the buffer overflowed: some kicks were lost, so every connected controller is looked at
  {.cast(gcsafe).}:
    withLock kickLock:
      result = overflowed
      overflowed = false
      if result: used = 0

proc drainKicks*() =
  discard takeKicks()
  discard kickedAll()
