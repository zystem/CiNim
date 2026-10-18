## A server that answers with a status line cut short must not end the core (std/httpclient raises an IndexDefect for it, which no `except CatchableError` catches): the clients turn it into an error.
import std/[unittest, net, httpclient, json, os, strutils]
import common/[rqlite, httpguard]

proc serveOnce(reply: string): Port =
  ## a one-shot server on a thread of its own: reads the request, sends `reply`, closes
  var s = newSocket()
  s.setSockOpt(OptReuseAddr, true)
  s.bindAddr(Port(0), "127.0.0.1")
  s.listen()
  let port = s.getLocalAddr()[1]
  var th {.global.}: Thread[tuple[s: Socket, reply: string]]
  createThread(th, proc (a: tuple[s: Socket, reply: string]) {.thread.} =
    var c: Socket
    a.s.accept(c)
    discard c.recv(1, 2000)
    sleep 100
    c.send(a.reply)
    c.close()
    a.s.close(), (s, reply))
  port

suite "an answer cut short does not end the program":
  test "a status line with one part: the library raises an IndexDefect, the guard turns it into an IOError":
    let port = serveOnce("HTTP/1.1\r\n\r\n")
    var raised = ""
    try:
      var c = newHttpClient(timeout = 3000)
      guardedHttp("test"): discard c.request("http://127.0.0.1:" & $port & "/")
    except IOError as e: raised = e.msg
    except Defect as e: raised = "DEFECT " & e.msg
    except CatchableError as e: raised = "OTHER " & e.msg
    check raised.len > 0 and not raised.startsWith("DEFECT")
  test "the rqlite client reports it as an RqError or another error that a loop handles":
    let port = serveOnce("HTTP/1.1\r\n\r\n")
    var c = newRq("http://127.0.0.1:" & $port)
    var handled = false
    try: discard c.query(%*[["SELECT 1"]])
    except CatchableError: handled = true
    check handled

suite "a request that timed out leaves no answer behind for the next one":
  test "the rqlite client does not read the late answer of the request before":
    # the server answers the first request after the client has given up, on the same connection; the second request gets its own answer
    var srv = newSocket()
    srv.setSockOpt(OptReuseAddr, true)
    srv.bindAddr(Port(0), "127.0.0.1")
    srv.listen()
    let port = srv.getLocalAddr()[1]
    proc answer(value: int): string =
      let body = """{"results":[{"columns":["v"],"types":["integer"],"values":[[""" & $value & """]]}]}"""
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " & $body.len & "\r\n\r\n" & body
    var th: Thread[tuple[s: Socket, a1, a2: string]]
    createThread(th, proc (a: tuple[s: Socket, a1, a2: string]) {.thread.} =
      var n = 0
      while n < 2:
        var c: Socket
        try: a.s.accept(c)
        except CatchableError: return
        while n < 2:
          var line = ""
          try:
            # read one request: the header, then the body of the length it says
            var len = 0
            while true:
              line = c.recvLine(timeout = 4000)
              if line.len == 0: break
              if line == "\r\n": break
              if line.toLowerAscii.startsWith("content-length:"): len = parseInt(line.split(':')[1].strip)
            if line.len == 0: break                               # the client closed this connection
            discard c.recv(len, 2000)
          except CatchableError: break
          inc n
          if n == 1: sleep 450                                      # slower than the client's patience (300 ms), quicker than a second wait
          try: c.send(if n == 1: a.a1 else: a.a2)
          except CatchableError: discard
        c.close()
      a.s.close(), (srv, answer(1), answer(2)))
    var c = newRq("http://127.0.0.1:" & $port, timeoutMs = 300)
    var timedOut = false
    try: discard c.query(%*[["SELECT 1"]])
    except CatchableError: timedOut = true
    check timedOut
    let r = c.query(%*[["SELECT 2"]])
    check r["results"][0]["values"][0][0].getInt == 2
