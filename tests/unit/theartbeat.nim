## RUN-013 / D-29: the liveness of a job controller. The controller writes a heartbeat file each time the core has answered it and accepted it; the probe of its Pod (`controller --healthcheck`)
## reads the file's age. A controller that is alive but cut off from the core - refused, or the core not answering - stops being touched, and Kubernetes restarts it.
import std/[unittest, os, times, osproc, strutils]
import common/heartbeat

suite "RUN-013 the heartbeat file of the controller":
  let dir = getTempDir() / "cinim-heartbeat-test"
  removeDir dir
  createDir dir
  let path = heartbeatPath(dir)
  test "the file is in the state directory, and a missing one is not alive":
    check path == dir / "heartbeat"
    check not isAlive(path, 1000, 180)
    check heartbeatAge(path, 1000) < 0
  test "touched, it is alive for as long as the limit says, and then it is not":
    touchHeartbeat(path, 1000)
    check heartbeatAge(path, 1100) == 100
    check isAlive(path, 1100, 180) and isAlive(path, 1180, 180)
    check not isAlive(path, 1181, 180)
  test "touched again, it is alive again (the controller was accepted by the core once more)":
    touchHeartbeat(path, 5000)
    check isAlive(path, 5100, 180)
  test "a directory that does not exist yet is made; a file that is not a time is not alive":
    let deep = dir / "a" / "b"
    touchHeartbeat(heartbeatPath(deep), 1)
    check fileExists(heartbeatPath(deep))
    writeFile(path, "not a time")
    check not isAlive(path, 10, 180)
  test "a time in the future (the clock was set back) does not count as alive for ever":
    touchHeartbeat(path, 9_000_000)
    check not isAlive(path, 1000, 180)
