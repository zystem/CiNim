import std/[unittest, options, strutils, times, os, osproc, sequtils]
import executor/[sandbox, journal, replay]
import support/fixture

type CrashError = object of CatchableError

proc runClean(): (ExecResult, Journal) =
  var sb = newSandbox()
  var j = Journal()
  let r = sb.execute(j, scriptSrc, fakeHost)
  (r, j)

suite "PIP-003 run journal":
  test "PIP-003 every host call is journaled in order":
    let (r, j) = runClean()
    check r.code == "ok"
    check j.entries.len == fixtureCalls
    check j.entries[0].kind == "now"
    check j.entries[1].kind == "sh" and j.entries[1].payload == "echo one"
    check j.entries[5].result == "1\nboom"
    check j.verify()

  test "PIP-003 hash chain detects tampering":
    var (_, j) = runClean()
    j.entries[2].result = "0.99"
    check not j.verify()
    var sb = newSandbox()
    let r = sb.execute(j, scriptSrc, fakeHost)
    check r.code == "journal_corrupt"

  test "PIP-003 host calls inside nested coroutines are rejected":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, "coroutine.wrap(function() ci.now() end)()", fakeHost)
    check r.code == "script_error" and "nested" in r.message
    check sb.execute(j, "coroutine.yield(1)", fakeHost).code == "script_error"

  test "PIP-006 journal size limit ends the run with a limit code":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, scriptSrc, fakeHost, maxEntries = 3)
    check r.code == "journal_limit"
    check j.entries.len == 3

suite "PIP-004 replay":
  test "PIP-004 full replay makes no host calls and gives the same result":
    let (r1, j) = runClean()
    var calls = 0
    let counting: HostCall = proc(seq: int; kind, payload: string): Option[string] =
      inc calls
      fakeHost(seq, kind, payload)
    var sb = newSandbox()
    var j2 = j
    let r2 = sb.execute(j2, scriptSrc, counting)
    check calls == 0
    check r2.value == r1.value and r2.code == "ok"
    check j2.entries.len == j.entries.len

  test "PIP-004 replay ignores host drift because results come from the journal":
    let (r1, j) = runClean()
    let drifting: HostCall = proc(seq: int; kind, payload: string): Option[string] =
      some("garbage")
    var sb = newSandbox()
    var j2 = j
    check sb.execute(j2, scriptSrc, drifting).value == r1.value

  test "PIP-004 a changed script reports script_nondeterminism with seq":
    let (_, j) = runClean()
    var sb = newSandbox()
    var j2 = j
    let r = sb.execute(j2, scriptSrc.replace("echo one", "echo two"), fakeHost)
    check r.code == "script_nondeterminism"
    check "seq 1" in r.message and "echo one" in r.message and "echo two" in r.message

  test "PIP-004 suspended call resumes after replay":
    var answered = false
    let host: HostCall = proc(seq: int; kind, payload: string): Option[string] =
      if seq == 2 and not answered: none(string) else: fakeHost(seq, kind, payload)
    var sb = newSandbox()
    var j = Journal()
    let r1 = sb.execute(j, scriptSrc, host)
    check r1.status == esSuspended and j.entries.len == 2
    answered = true
    var sb2 = newSandbox()
    let r2 = sb2.execute(j, scriptSrc, host)
    check r2.status == esDone and r2.code == "ok"
    check j.entries.len == fixtureCalls

  test "PIP-004 crash at every journal point converges to the clean run":
    let (clean, cj) = runClean()
    for crashAt in 0 ..< fixtureCalls:
      for afterEffect in [false, true]:
        var j = Journal()
        var effects = newSeq[int]()
        var crashed = false
        let crashing: HostCall = proc(seq: int; kind, payload: string): Option[string] =
          if seq == crashAt and not crashed:
            crashed = true
            if afterEffect: effects.add seq
            raise newException(CrashError, "killed")
          effects.add seq
          fakeHost(seq, kind, payload)
        block first:
          var sb = newSandbox()
          try:
            discard sb.execute(j, scriptSrc, crashing)
            check false
          except CrashError: discard
        var sb2 = newSandbox()
        let r = sb2.execute(j, scriptSrc, crashing)
        check r.code == "ok" and r.value == clean.value
        check j.entries == cj.entries
        for s in 0 ..< fixtureCalls:  # completed calls never re-run; only the crashed one may repeat
          check effects.count(s) == (if s == crashAt and afterEffect: 2 else: 1)

  test "PIP-004 a really killed process resumes from its journal file":
    let (clean, cj) = runClean()
    let dir = getTempDir() / "cinim-crash"
    createDir(dir)
    let exe = dir / "crashhelper"
    check execCmd("nim c --hints:off -o:" & exe & " tests/unit/crashhelper.nim") == 0
    for crashAt in [0, 3, 6]:
      for mode in ["before", "after"]:
        let jf = dir / "journal.txt"
        let ef = dir / "effects.txt"
        removeFile(jf); removeFile(ef)
        check execCmd(exe & " " & jf & " " & ef & " " & $crashAt & " " & mode) == 9
        var j = loadJournal(jf)
        check j.verify()
        check j.entries.len == crashAt
        var effects = newSeq[int]()
        let host: HostCall = proc(seq: int; kind, payload: string): Option[string] =
          effects.add seq
          fakeHost(seq, kind, payload)
        var sb = newSandbox()
        let r = sb.execute(j, scriptSrc, host)
        check r.code == "ok" and r.value == clean.value
        check j.entries == cj.entries
        check effects == toSeq(crashAt ..< fixtureCalls)

suite "NFR-014 replay speed":
  test "NFR-014 replay of 10000 journal entries takes at most 2 s":
    let src = "local s = 0 for i = 1, 10000 do s = s + ci.now() end return s"
    var sb = newSandbox()
    var j = Journal()
    check sb.execute(j, src, fakeHost).code == "ok"
    check j.entries.len == 10000
    var sb2 = newSandbox()
    let t0 = epochTime()
    let r = sb2.execute(j, src, fakeHost)
    let dt = epochTime() - t0
    check r.code == "ok"
    check dt <= 2.0
