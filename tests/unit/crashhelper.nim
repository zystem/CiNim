## Child process for the kill test: runs the fixture script against a journal
## file and dies with _exit(9) at a chosen host call, "before" or "after" its effect.
import std/[os, options, strutils]
import executor/[sandbox, journal, replay]
import support/fixture

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>".}

let args = commandLineParams()
let (jf, ef, crashAt, mode) = (args[0], args[1], parseInt(args[2]), args[3])

proc effect(seq: int) =
  let f = open(ef, fmAppend)
  f.writeLine($seq)
  f.close()

let host: HostCall = proc(seq: int; kind, payload: string): Option[string] =
  if seq == crashAt:
    if mode == "after": effect(seq)
    cExit(9)
  effect(seq)
  fakeHost(seq, kind, payload)

var sb = newSandbox()
var j = loadJournal(jf)
discard sb.execute(j, scriptSrc, host, onAppend = proc (e: Entry) = appendToFile(jf, e))
