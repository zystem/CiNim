## A stand-in for vlagent's /insert/jsonline (core/logcollector.nim forwards the blocks of the log there): answers 200 to every POST and counts the bodies it took. For the tests of the
## collector's path, which must work with nothing else (D-75).
import std/locks
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
  let s = newService(onRequest)
  discard s.start(port, 2)

proc stopFakeVlagent*() =
  shutdown()
