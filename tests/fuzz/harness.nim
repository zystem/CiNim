## libFuzzer (clang, coverage-guided, AddressSanitizer) over the parsers of tests/fuzz/targets.nim: `FUZZ_TARGET=<name> build/fuzz/harness corpus-dir`. tools/test/fuzz.sh builds and runs it.
## `call` handles the exceptions that its parser promises; anything else that escapes (a Defect, an exception that is not promised) is a find: it is told and the process aborts, so that
## libFuzzer saves the input that did it. A sanitizer report or a timeout is a find too. The input goes to tests/fuzz/regressions/<target>/ and tests/unit/tfuzz.nim runs it from then on.
import std/[os, strutils]
import targets

proc cAbort() {.importc: "abort", header: "<stdlib.h>", noreturn.}
proc NimMain() {.importc: "NimMain".}

var chosen: FuzzTarget

proc LLVMFuzzerInitialize(argc: ptr cint; argv: pointer): cint {.exportc: "LLVMFuzzerInitialize", cdecl.} =
  NimMain()                                   # --noMain: libFuzzer has the main, the runtime of Nim is started here
  let name = getEnv("FUZZ_TARGET")
  var names: seq[string]
  for t in allTargets():
    names.add t.name
    if t.name == name: chosen = t
  if chosen.call == nil:
    stderr.writeLine "FUZZ_TARGET is '", name, "'; it must be one of: ", names.join(" ")
    quit(2)
  0

proc LLVMFuzzerTestOneInput(data: ptr uint8; size: csize_t): cint {.exportc: "LLVMFuzzerTestOneInput", cdecl.} =
  var s = newString(int(size))
  if size > 0: copyMem(addr s[0], data, int(size))
  try:
    discard chosen.call(s)
  except Exception as e:                      # a Defect, or an exception that the parser does not promise
    stderr.writeLine "fuzz find in ", chosen.name, ": ", e.name, ": ", e.msg.splitLines[0]
    cAbort()
  0
