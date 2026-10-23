## A stand-in for the query side of VictoriaLogs (`/select/logsql/query`), for the tests of what the core asks of the store and does with the answer (D-77): it answers with the body it was given and
## remembers the query it was asked.
import std/[locks, strutils, uri]
import ../../src/common/httpsrv
import guildenstern/guildenserver

var
  lock: Lock
  body = ""
  lastQuery* = ""
initLock(lock)

proc setBody*(b: string) =
  withLock lock: body = b

proc askedFor*(): string =
  withLock lock: result = lastQuery

proc onRequest() {.raises: [], gcsafe.} =
  {.cast(gcsafe).}:
    let u = getUri()
    var answer = ""
    withLock lock:
      let q = if '?' in u: u[u.find('?') + 1 .. ^1] else: ""
      for k, v in decodeQuery(q):
        if k == "query": lastQuery = v
      answer = body
    reply(Http200, if answer.len > 0: answer else: "\n")

proc startFakeVlogs*(port: int) =
  let s = newService(onRequest)
  discard s.start(port, 2)

proc stopFakeVlogs*() =
  shutdown()
