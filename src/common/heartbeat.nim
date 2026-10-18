## The liveness of a controller (and of a conductor): a file that is written each time the core has answered and accepted it, and read by the probe of the Pod (`--healthcheck` of the
## same program). A process that is cut off from the core - refused, the core not answering, its own loop stuck - stops writing, the file grows old, and Kubernetes restarts the Pod. The
## file holds the time of the last contact in seconds since the epoch; the age is judged by the clock of the probe, and a time in the future (the clock was set back) is not alive.
import std/[os, strutils]

func heartbeatPath*(dir: string): string = dir / "heartbeat"

proc touchHeartbeat*(path: string; now: int64) =
  ## written whole and moved into place, so that the probe never reads half of it
  createDir(parentDir(path))
  let tmp = path & ".tmp"
  writeFile(tmp, $now)
  moveFile(tmp, path)

proc heartbeatAge*(path: string; now: int64): int64 =
  ## seconds since the last contact; -1 when there is no file, it holds no time, or the time is in the future
  try:
    let at = parseBiggestInt(readFile(path).strip)
    if at > now: -1 else: now - at
  except CatchableError:
    -1

proc isAlive*(path: string; now: int64; maxAgeSeconds: int): bool =
  let age = heartbeatAge(path, now)
  age >= 0 and age <= maxAgeSeconds
