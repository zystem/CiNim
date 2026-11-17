## SEC-009: the parsers of bytes that something else wrote are fuzzed (tests/support/fuzz.nim: valid seeds from the program's own encoders, damaged in the ways that hurt a parser; the
## parser must end, must not grow the heap, and must answer with a result or with the exception it promises). The parsers and their seeds are in tests/fuzz/targets.nim, the same list that
## the libFuzzer harness (tests/fuzz/harness.nim, tools/test/fuzz.sh: clang, coverage-guided) runs:
##   * the directory's answers (BER in src/common/ldapclient.nim) and the filters and URLs an administrator types;
##   * the CBOR, the authenticator data and the signature of a security key (src/core/webauthn.nim), which a browser, that is the person at the other end, sends;
##   * the frames of the push channel (src/common/stream.nim) and the pipe of a run process (src/common/runpipe.nim);
##   * the Protobuf of a peer (the report of a controller, the hello of a conductor), through the library that the core uses.
## CINIM_FUZZ_ITERATIONS (default 20 000 inputs for each parser) and CINIM_FUZZ_SEED are in tests/support/fuzz.nim; under AddressSanitizer a memory error is a failure too.
## A find is kept as a file in tests/fuzz/regressions/<target>/ (the input that the fuzzer printed or libFuzzer saved): it is run first, every time.
import std/[unittest, os, strutils, sequtils]
import common/ldapclient
import ../support/fuzz
import ../fuzz/targets

type NoException = object of CatchableError      ## a parser that promises no exception here (`call` has caught the ones it promises): any one that is raised is a find

template settle(name: string; result: FuzzResult; mustRefuseChanged = false) =
  ## `mustRefuseChanged`: a check that vouches for something (a signature, a key) must say no to every input that is not a seed
  let r = result
  report(name, r)
  check r.failure == ""
  if mustRefuseChanged: check r.changedAccepted == 0
  check r.iterations > 0
  check r.refused > 0                              # the damage reached the refusals: a fuzzer that never makes a refusal tests nothing

suite "SEC-009 the parsers of bytes that something else wrote":
  for t in allTargets():
    test "SEC-009 " & t.name & ", damaged: ends, keeps the heap, answers with a result or its own exception":
      var seeds = t.seeds
      for f in walkFiles(currentSourcePath().parentDir / ".." / "fuzz" / "regressions" / t.name / "*"):     # what once broke it, first
        seeds.add readFile(f)
      for s in t.seeds:
        if not t.call(s):                            # the seeds are valid: a seed that is refused is a mistake of the list
          echo "  the seed of ", t.name, " is refused: ", hex(s)
          fail()
      settle(t.name, run[NoException](seeds, t.call), mustRefuseChanged = t.strict)

suite "SEC-009 limits that a fuzzer found":
  test "SEC-009 a filter that nests a hundred thousand levels is refused with an LdapError, not a crash of the stack":
    for deep in ["(".repeat(200_000), "(&".repeat(100_000) & ")", "(!".repeat(100_000) & "(a=b)" & ")".repeat(100_000)]:
      expect LdapError:
        discard encodeFilter(deep)
