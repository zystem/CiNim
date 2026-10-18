## std/httpclient reads the status line of an answer with `split(' ')` and indexes the parts: an answer cut short (a server or a proxy under load that drops the connection in the middle of the line)
## raises an `IndexDefect` ("index 2 not in 0 .. 1"). A Defect is not a `CatchableError`, so the `except CatchableError` of every loop in the core let it through and the process ended (measured
## 2026-10-18: the core exited twice under a stalled database, with nothing in the log but the message). At the boundary of the library the Defect becomes an error that can be handled.
template guardedHttp*(what: string; body: untyped): untyped =
  try: body
  except IndexDefect as e: raise newException(IOError, what & ": the answer was cut short (" & e.msg & ")")
