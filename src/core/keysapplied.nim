## D-105, SHD-008: which pair of transport keys the core last put in the Secret of a namespace's controller. The core may create and delete Secrets and not read them (T-45), so it
## cannot compare the Secret with the pair it has now; it remembers what it put there, in memory, as `ctrlpresence` remembers when it last heard a controller. A core that has just
## started remembers nothing, so it makes every Secret again once (the pair may have been renewed while it was down).
import std/[locks, tables]

var
  lock: Lock
  seen: Table[string, int64]
initLock(lock)

proc keysSeen*(namespace: string): int64 =
  ## the digest (`orgprovision.keysDigest`) of the pair in the Secret of that namespace as the core put it there; 0: the core has not put one there since it started
  {.cast(gcsafe).}:
    withLock lock: result = seen.getOrDefault(namespace, 0)

proc noteKeys*(namespace: string; digest: int64) =
  {.cast(gcsafe).}:
    withLock lock: seen[namespace] = digest

proc forgetKeys*(namespace: string) =
  {.cast(gcsafe).}:
    withLock lock: seen.del namespace
