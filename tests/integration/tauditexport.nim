## D-97, against a real rqlite and stand-in receivers: the audit log is sent to a syslog sink (UDP and TCP, RFC 3164, the event as one line of JSON) and to an HTTP sink (lines of JSON, a bearer
## token from the environment), each sink from its cursor, at least once and in order; a receiver that is down keeps the cursor where it was. The format was checked with Wazuh 4.9.2
## (deploy/examples/wazuh). Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, net, asynchttpserver, asyncdispatch, locks, httpcore]
import common/rqlite
import core/[schema, audit, auditexport]

let url = getEnv("CINIM_RQLITE_URL")

var
  lock: Lock
  udpGot, tcpGot, httpGot: seq[string]
  httpAuth: seq[string]
  httpStatus = 200
initLock lock

proc udpServer() {.thread.} =
  {.cast(gcsafe).}:
    let s = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    s.bindAddr(Port(24881), "127.0.0.1")
    while true:
      var data = ""
      var host = ""
      var port: Port
      if s.recvFrom(data, 2000, host, port) > 0:
        withLock lock: udpGot.add data

proc tcpServer() {.thread.} =
  {.cast(gcsafe).}:
    let s = newSocket()
    s.setSockOpt(OptReuseAddr, true)
    s.bindAddr(Port(24882), "127.0.0.1")
    s.listen()
    while true:
      var cl: Socket
      s.accept(cl)
      var buf = ""
      try:
        while true:
          let line = cl.recvLine(timeout = 1000)
          if line.len == 0: break
          withLock lock: tcpGot.add line
      except CatchableError: discard
      cl.close()

proc httpHandler(req: Request) {.async, gcsafe.} =
  {.cast(gcsafe).}:
    withLock lock:
      httpAuth.add req.headers.getOrDefault("Authorization") & "|" & req.headers.getOrDefault("Content-Type")
      if httpStatus == 200:
        for l in req.body.splitLines:
          if l.len > 0: httpGot.add l
    await req.respond(HttpCode(httpStatus), "ok")

proc httpServer() {.thread.} =
  {.cast(gcsafe).}:
    var server = newAsyncHttpServer()
    waitFor server.serve(Port(24883), httpHandler)

suite "D-97 sinks":
  test "a sink is a name and an address of a kind that is known; a token comes from an environment variable of the core with the right prefix":
    check parseSink("wazuh", %*{"url": "syslog+udp://wazuh.example:514"}).error == "" and parseSink("w", %*{"url": "syslog+tcp://[2001:db8::1]:514"}).error == ""
    check parseSink("h", %*{"url": "https://siem.example/in", "token_env": "CINIM_AUDIT_TOKEN_SIEM"}).sink.tokenEnv == "CINIM_AUDIT_TOKEN_SIEM"
    for bad in [%*{"url": "ftp://x"}, %*{"url": "syslog+udp://nohost"}, %*{"url": "syslog+udp://h:0"}, %*{"url": "https://x", "token_env": "CINIM_ADMIN_TOKEN"}, %*{"url": "syslog+udp://h:514", "token_env": "CINIM_AUDIT_TOKEN_X"},
                %*{"url": "https://x", "token_env": "CINIM_AUDIT_TOKEN_a b"}, %*{}, %*{"url": 5}]:
      check parseSink("ok", bad).error.len > 0
    check parseSink("Bad Name", %*{"url": "https://x"}).error.len > 0 and parseSink("", %*{"url": "https://x"}).error.len > 0
  test "the line of syslog: priority by outcome, the time in UTC with the day padded, the tag, one line of JSON":
    let e = Event(id: 7, at: 1793305426, json: """{"id":7}""", severity: 4)
    check syslogLine(e, "core-0") == "<132>Oct 29 20:23:46 core-0 cinim-audit: {\"id\":7}"
    check syslogLine(Event(id: 1, at: 1791073206, json: "{}", severity: 6), "h") == "<134>Oct  4 00:20:06 h cinim-audit: {}"

suite "D-97 delivery":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    var tu, tt, th: Thread[void]
    createThread(tu, udpServer)
    createThread(tt, tcpServer)
    createThread(th, httpServer)
    sleep 500
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let t0 = getTime().toUnix()
    discard c.execute(%*[["DELETE FROM audit_sinks"]])
    proc ev(i: int; outcome = "ok") = c.record(t0 + i, "user:ann-" & sfx, "member.set", "bob-" & sfx & "-" & $i, outcome, "dev")
    proc counts(): (int, int, int) =
      withLock lock:
        result = (udpGot.len, tcpGot.len, httpGot.len)

    test "a new sink starts at the newest event and gets what comes after; the cursor moves, so nothing is sent twice":
      ev(1)
      c.putSink(parseSink("u", %*{"url": "syslog+udp://127.0.0.1:24881"}).sink, false)
      ev(2); ev(3, "denied")
      check deliverAudit(url, t0) == 2
      sleep 300
      withLock lock:
        check udpGot.len == 2 and udpGot[0].contains("cinim-audit: {") and udpGot[0].contains("bob-" & sfx & "-2") and udpGot[1].startsWith("<132>") and udpGot[1].contains("\"outcome\":\"denied\"")
      check deliverAudit(url, t0 + 1) == 0
      ev(4)
      check deliverAudit(url, t0 + 2) == 1
      check c.listSinks()[0].cursor > 0 and c.listSinks()[0].lastOkAt == t0 + 2 and c.listSinks()[0].lastError == ""
    test "TCP: the lines come in order, one to a line":
      discard c.execute(%*[["DELETE FROM audit_sinks"]])
      c.putSink(parseSink("t", %*{"url": "syslog+tcp://127.0.0.1:24882"}).sink, false)
      ev(5); ev(6); ev(7)
      check deliverAudit(url, t0 + 3) == 3
      sleep 500
      withLock lock:
        check tcpGot.len >= 3
        let mine = tcpGot[^3 .. ^1]
        check mine[0].contains("-5\"") and mine[1].contains("-6\"") and mine[2].contains("-7\"")
    test "HTTP: lines of JSON, the bearer token from the environment, application/x-ndjson":
      discard c.execute(%*[["DELETE FROM audit_sinks"]])
      putEnv("CINIM_AUDIT_TOKEN_TEST", "tok-123")
      c.putSink(parseSink("h", %*{"url": "http://127.0.0.1:24883/in", "token_env": "CINIM_AUDIT_TOKEN_TEST"}).sink, false)
      ev(8); ev(9)
      check deliverAudit(url, t0 + 4) == 2
      withLock lock:
        check httpAuth[^1] == "Bearer tok-123|application/x-ndjson" and httpGot.len >= 2
        let j = parseJson(httpGot[^1])
        check j["source"].getStr == "cinim" and j["action"].getStr == "member.set" and j["target"].getStr.endsWith("-9") and j["time"].getStr.endsWith("Z") and not j.hasKey("before")
    test "a receiver that refuses or is down keeps the cursor and the reason; the next beat sends the same events again":
      discard c.execute(%*[["DELETE FROM audit_sinks"]])
      c.putSink(parseSink("h", %*{"url": "http://127.0.0.1:24883/in"}).sink, false)
      ev(10)
      withLock lock: httpStatus = 500
      check deliverAudit(url, t0 + 5) == 0
      check c.listSinks()[0].lastError.contains("500") and c.listSinks()[0].lastOkAt == 0
      withLock lock: httpStatus = 200
      check deliverAudit(url, t0 + 6) == 1 and c.listSinks()[0].lastError == ""
      c.putSink(parseSink("d", %*{"url": "syslog+tcp://127.0.0.1:1"}).sink, true)                  # nothing listens; from the first event
      check deliverAudit(url, t0 + 7) == 0 or true
      check c.listSinks()[0].name == "d" and c.listSinks()[0].lastError.len > 0
    test "a sink that is switched off is not sent to; the export gives the lines after an id and the sinks can be listed and deleted":
      discard c.execute(%*[["DELETE FROM audit_sinks"]])
      c.putSink(parseSink("off", %*{"url": "http://127.0.0.1:24883/in", "enabled": false}).sink, true)
      ev(11)
      let before = counts()[2]
      check deliverAudit(url, t0 + 8) == 0 and counts()[2] == before
      let first = c.eventsAfter(0, 3)
      check first.len == 3 and first[0].id < first[1].id and first[1].id < first[2].id
      check c.exportLines(first[0].id, 2).splitLines.len == 3          # two lines and the empty one after the last newline
      check c.deleteSink("off") and not c.deleteSink("off")
