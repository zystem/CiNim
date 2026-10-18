## IAM-003, SHD-008: when the core last took in a report of the controller of a namespace. The core is what keeps a controller healthy (it has no probe of its own and no
## Deployment behind it): a controller that was enrolled and has not been heard for a while is killed and made again (`orgreconcile.nim`). The time is kept in memory; a core
## that has just started has heard nobody, so it gives every controller the same time to report (the caller compares with the start of the core).
import std/[locks, tables]

var
  lock: Lock
  seen: Table[string, int64]
initLock(lock)

proc notePoll*(namespace: string; now: int64) =
  {.cast(gcsafe).}:
    withLock lock: seen[namespace] = now

proc lastPoll*(namespace: string): int64 =
  ## 0: not heard since the core started
  {.cast(gcsafe).}:
    withLock lock: result = seen.getOrDefault(namespace, 0)

proc forgetPolls*(namespace: string) =
  {.cast(gcsafe).}:
    withLock lock: seen.del namespace
