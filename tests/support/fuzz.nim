## A mutation fuzzer for the parsers of bytes that something else wrote (SEC-009: the directory's answers, a browser's security-key data, the frames of the push channel, the pipe of a run
## process, the Protobuf of a peer). There is no clang here, so no libFuzzer: this is the same idea in plain Nim, and it runs in the ordinary suite, under AddressSanitizer
## (`CINIM_TEST_ASAN=1 tools/test/run.sh tests/unit/tfuzz.nim`) and under ThreadSanitizer.
##
## A run takes valid inputs (the seeds, made by the program's own encoders), damages them in the ways that hurt a parser (a flipped bit, a byte that becomes 0, 1, 0x7f, 0x80 or 0xff, a part
## cut out, a part repeated, a part of another seed spliced in, the tail cut off, a window of length bytes set to 0xff or 0), and calls the parser with each result. What it asks of the
## parser: it ends (no call takes a second), it does not grow the heap (no call leaves a lot of memory behind), and it answers with a result or with the exception the parser promises
## (`Expected`); a `Defect` (an index, a range, an overflow, a nil), any other exception, a crash or a sanitizer report is a failure, and the input that caused it is printed in hex so that
## it can be made a test of its own.
##
## The same seed gives the same inputs (`CINIM_FUZZ_SEED`, a number; the default is fixed so that a failure is the same on every machine); `CINIM_FUZZ_ITERATIONS` is the number of
## inputs for each parser (default 20 000; a nightly run can ask for millions).
import std/[random, os, strutils, times]

const
  defaultIterations = 20_000
  defaultSeed = 20261118
  slowSeconds = 1.0                      ## one call that takes longer is a hang, for the purpose of a test
  growthLimit = 64 * 1024 * 1024         ## the heap may not be this much larger after the run than before it

type
  FuzzResult* = object
    iterations*, accepted*, refused*: int
    changedAccepted*: int                ## accepted inputs that are none of the seeds: for a check that must say no to anything that was changed (a signature), it must stay 0
    failure*: string                     ## "" when nothing went wrong; otherwise what, with the input in hex and the iteration

proc iterations*(): int =
  let e = getEnv("CINIM_FUZZ_ITERATIONS")
  if e.len > 0: parseInt(e) else: defaultIterations

proc seed*(): int64 =
  let e = getEnv("CINIM_FUZZ_SEED")
  if e.len > 0: parseBiggestInt(e) else: defaultSeed

proc hex*(s: string): string =
  for c in s: result.add toHex(ord(c), 2).toLowerAscii

proc mutate*(rng: var Rand; seeds: openArray[string]; maxLen = 4096): string =
  ## one input: a seed damaged one to four times, or now and then bytes that are not any seed
  if rng.rand(30) == 0:
    result = newString(rng.rand(0 .. 64))
    for i in 0 ..< result.len: result[i] = char(rng.rand(0 .. 255))
    return
  result = rng.sample(seeds)
  for _ in 0 ..< rng.rand(1 .. 4):
    if result.len == 0:
      result.add char(rng.rand(0 .. 255))
      continue
    let at = rng.rand(0 ..< result.len)
    case rng.rand(0 .. 9)
    of 0: result[at] = char(ord(result[at]) xor (1 shl rng.rand(0 .. 7)))
    of 1: result[at] = char(rng.rand(0 .. 255))
    of 2: result[at] = char(rng.sample([0, 1, 0x7f, 0x80, 0x81, 0xfe, 0xff]))
    of 3:                                                       # cut a part out
      let n = rng.rand(1 .. min(8, result.len - at))
      result.delete(at ..< at + n)
    of 4:                                                       # insert bytes
      var ins = newString(rng.rand(1 .. 8))
      for i in 0 ..< ins.len: ins[i] = char(rng.rand(0 .. 255))
      result.insert(ins, at)
    of 5: result.setLen(at)                                     # the tail cut off
    of 6:                                                       # a part repeated
      let n = rng.rand(1 .. min(16, result.len - at))
      result.insert(result[at ..< at + n], at)
    of 7:                                                       # a part of another seed
      let other = rng.sample(seeds)
      if other.len > 0:
        let o = rng.rand(0 ..< other.len)
        let n = rng.rand(1 .. min(16, other.len - o))
        result.insert(other[o ..< o + n], at)
    of 8, 9:                                                    # a window that is a length: all ones or all zeros
      let n = rng.rand(1 .. min(4, result.len - at))
      let v = if rng.rand(1) == 0: '\xff' else: '\0'
      for i in at ..< at + n: result[i] = v
    else: discard
  if result.len > maxLen: result.setLen(maxLen)

proc run*[E: CatchableError](seeds: openArray[string]; parse: proc (input: string): bool; maxLen = 4096): FuzzResult =
  ## `parse` returns true when the input was taken and false when the parser said "not valid" in its own way (a result, not an exception); the exception `E` is the parser's promised
  ## refusal. The seeds themselves are run first: a seed that the parser refuses is a mistake of the test, not a find.
  var rng = initRand(seed())
  let seedList = @seeds
  let heapBefore = getOccupiedMem()
  proc one(input: string; n: int; res: var FuzzResult): bool {.closure.} =
    let t0 = epochTime()
    try:
      if parse(input):
        inc res.accepted
        if input notin seedList: inc res.changedAccepted
      else: inc res.refused
    except Defect as e:
      res.failure = "a " & $e.name & " (" & e.msg.splitLines[0] & ") at input " & $n & ": " & hex(input)
      return false
    except CatchableError as e:
      if e of E:
        inc res.refused
      else:
        res.failure = "an exception that the parser does not promise, " & $e.name & " (" & e.msg.splitLines[0] & "), at input " & $n & ": " & hex(input)
        return false
    if epochTime() - t0 > slowSeconds:
      res.failure = "a call took " & $(epochTime() - t0) & " s at input " & $n & ": " & hex(input)
      return false
    true
  for s in seeds:
    if not one(s, -1, result): return
  for n in 0 ..< iterations():
    let input = mutate(rng, seeds, maxLen)
    inc result.iterations
    if not one(input, n, result): return
  GC_fullCollect()
  let grown = getOccupiedMem() - heapBefore
  if grown > growthLimit: result.failure = "the heap grew by " & $(grown div (1024 * 1024)) & " MiB over " & $result.iterations & " inputs"

proc report*(name: string; r: FuzzResult) =
  ## one line for the log of the run: what was done and how it went
  echo "  fuzz ", name, ": ", r.iterations, " inputs, ", r.accepted, " taken (", r.changedAccepted, " of them changed), ", r.refused, " refused (seed ", seed(), ")", (if r.failure.len > 0: " FAILED: " & r.failure else: "")
