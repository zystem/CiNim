## A stand-in for vlagent's /insert/jsonline (core/logcollector.nim forwards the blocks of the log there): answers 200 to every POST and counts the bodies it took. For the tests of the
## collector's path, which must work with nothing else (D-75).
import std/locks
import freeport
import ../../src/common/httpsrv
import guildenstern/guildenserver

var
  lock: Lock
  taken*: int                        ## how many requests came
  answerCode = 200
initLock(lock)

proc setAnswer*(code: int) =
  withLock lock: answerCode = code

proc takenCount*(): int =
  withLock lock: result = taken

proc onRequest() {.raises: [], gcsafe.} =
  {.cast(gcsafe).}:
    var code = 200
    withLock lock:
      inc taken
      code = answerCode
    reply(HttpCode(code), "ok")

proc startFakeVlagent*(port: int) =
  requireFreePort(port, "startFakeVlagent")
  let s = newService(onRequest)
  doAssert s.start(port, 2), "the stand-in could not bind port " & $port & " (something holds it)"

proc stopFakeVlagent*() =
  shutdown()
