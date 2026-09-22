## Minimal repro (Nim 2.2.4, ORC): exceptions raised and caught inside async procs leave garbage.
## Build: nim c [-d:release] async_exception_leak.nim; run with sync|asyncok|async|asyncnoawait.
## Debug: async 791 B/iter, sync-inside-async 164 B/iter; release: 151 B and 116 B; asyncok 4 B.
## The same raise/catch outside an async proc leaks nothing (0 B/iter).
import std/[asyncdispatch, os]
type MyErr = object of CatchableError
proc failSync() = raise (ref MyErr)(msg: "x")
proc failAsync(): Future[void] {.async.} =
  await sleepAsync(0)
  raise (ref MyErr)(msg: "x")
proc failAsyncNoAwait(): Future[void] {.async.} =
  raise (ref MyErr)(msg: "x")
proc main() {.async.} =
  let mode = paramStr(1)
  let before = getOccupiedMem()
  for i in 1 .. 20000:
    try:
      case mode
      of "sync": failSync()
      of "async": await failAsync()
      of "asyncnoawait": await failAsyncNoAwait()
      of "asyncok": await sleepAsync(0)
    except MyErr: discard
  echo mode, ": growth per iteration = ", (getOccupiedMem() - before) div 20000, " bytes"
waitFor main()
