## D-29: the shim's state vocabulary - one definition shared by the Pod log, ZeroMQ and rqlite. Pure.
import std/[unittest, json, options, strutils, os, osproc, sequtils]
import common/[shimstate, states]

proc st(n: int; ev: ShimEvent; cmdExit = none(int); reason = ""; exitCode = none(int)): ShimState =
  ShimState(run: "s1_r", seq: 0, attempt: 1, n: n, event: ev, phase: phaseAfter[ev], cmdStarted: ev != seStarted,
            cmdExit: cmdExit, logs: (if logsAfter[ev].isSome: logsAfter[ev].get else: lsNone), reason: reason, exitCode: exitCode)

suite "the event table":
  test "every event has a phase; the phases only move forward":
    var last = spStarting
    for e in [seStarted, seCommandStarted, seCommandExited, seLogsDelivering, seLogsDelivered, seDone]:
      check phaseAfter[e] >= last
      last = phaseAfter[e]
    check phaseAfter[seStopping] == spStopping and phaseAfter[seKilling] == spStopping
  test "the happy path is a chain of allowed successors":
    let path = [seStarted, seCommandStarted, seCommandExited, seLogsDelivering, seLogsDelivered, seDone]
    for i in 0 ..< path.high: check path[i + 1] in successors(path[i])
  test "the stop path (timeout / SIGTERM) and the rejected-environment path are allowed":
    let stop = [seStarted, seCommandStarted, seStopping, seKilling, seCommandExited, seLogsDelivering, seLogsUndelivered, seDone]
    for i in 0 ..< stop.high: check stop[i + 1] in successors(stop[i])
    check seDone in successors(seStarted)
  test "nothing follows done; nothing goes backwards":
    check successors(seDone).card == 0
    check not reachable(seCommandExited, seCommandStarted)
    check not reachable(seDone, seStarted)
    check not reachable(seLogsDelivered, seLogsUndelivered)
  test "a reader that missed events can still check order: reachable skips what it did not see":
    check reachable(seStarted, seDone)
    check reachable(seCommandStarted, seLogsDelivered)
    check reachable(seCommandStarted, seCommandStarted)

suite "mapping to the step state machine (states.nim)":
  test "the shim's phase gives the step's non-final state":
    check stepStateOf(st(1, seStarted)) == ssStarting
    check stepStateOf(st(2, seCommandStarted)) == ssRunning
    check stepStateOf(st(3, seStopping, reason = "timeout")) == ssRunning
    check stepStateOf(st(5, seCommandExited, cmdExit = some 0)) == ssRunning       # not final until the verdict: the log may be in flight
    check stepStateOf(st(7, seLogsDelivered, cmdExit = some 0)) == ssRunning
  test "only done gives a final state, by the outcome":
    check stepStateOf(st(8, seDone, some 0, "ok", some 0)) == ssSucceeded
    check stepStateOf(st(8, seDone, some 3, "failed", some 3)) == ssFailed
    check stepStateOf(st(8, seDone, some 143, "timeout", some 124)) == ssTimedOut
    check stepStateOf(st(8, seDone, some 143, "terminated", some 143)) == ssLost          # cut off from outside: outcome unknown
    check stepStateOf(st(8, seDone, none(int), "env_rejected", some 70)) == ssFailed
  test "logs_undelivered keeps the command's own result":
    check stepStateOf(st(8, seDone, some 0, "logs_undelivered", some 72)) == ssSucceeded
    check stepStateOf(st(8, seDone, some 2, "logs_undelivered", some 72)) == ssFailed
  test "every mapped transition is a legal edge of the step state machine":
    check canStep(ssStarting, ssRunning)
    for fin in [ssSucceeded, ssFailed, ssTimedOut, ssLost]: check canStep(ssRunning, fin)
    check canStep(ssStarting, ssFailed) and canStep(ssStarting, ssLost)       # env_rejected / lost before the command ran

suite "wire form and merge":
  test "line -> state -> line is lossless":
    let s = st(8, seDone, some 3, "failed", some 3)
    let line = marker & $toJson(s, 1790000000000)
    let back = parseLine(line)
    check back.isSome
    check back.get == s
  test "garbage, other output and unknown vocabulary are none, never an exception":
    check parseLine("just output").isNone
    check parseLine("CICD-SHIM {broken").isNone
    check parseLine("CICD-SHIM {\"ev\":\"teleported\",\"n\":1,\"ph\":\"running\"}").isNone
    check parseLine("CICD-SHIM {\"ev\":\"started\",\"n\":0,\"ph\":\"starting\"}").isNone
  test "the newest state of a log tail; a step cannot fake it with a lower n":
    let a = marker & $toJson(st(2, seCommandStarted), 1)
    let b = marker & $toJson(st(3, seStopping, reason = "timeout"), 2)
    let faked = marker & $toJson(st(1, seStarted), 3)
    check lastState("out\n" & a & "\nmore out\n" & b & "\n" & faked & "\n").get.n == 3
    check lastState("out\n" & a & "\nmore out\n" & b & "\n" & faked & "\n").get.event == seStopping
    check lastState("nothing here").isNone
  test "the merge rule: only a later event replaces what is known (any order, repeats are harmless)":
    let known = st(4, seCommandExited, some 0)
    check not newer(known, st(4, seCommandExited, some 0))
    check not newer(known, st(2, seCommandStarted))
    check newer(known, st(6, seLogsDelivered, some 0))

suite "the real shim writes exactly this vocabulary":
  test "a run of the shim: every line parses, n counts 1..k, each event is an allowed successor of the previous":
    let exe = getTempDir() / "cinim-shim-test"
    check execCmd("nim c --hints:off --warnings:off -o:" & exe & " src/shim/shim.nim") == 0
    for (cmd, args) in [("echo hi", newSeq[string]()), ("exit 3", newSeq[string]()),
                        ("sleep 30", @["--timeout", "1", "--term-grace", "1"])]:
      let d = getTempDir() / "shimstate-run"
      createDir d
      let (output, _) = execCmdEx(exe & " --run-dir " & d & " --termination-log " & d / "tl " & args.join(" ") & " -- sh -c '" & cmd & "'")
      var states: seq[ShimState]
      for l in output.splitLines:
        let p = parseLine(l)
        if p.isSome: states.add p.get
      check states.len >= 6
      for i, s in states:
        check s.n == i + 1
        if i > 0: check s.event in successors(states[i - 1].event)
        check s.phase == phaseAfter[s.event]
      check states[^1].event == seDone and states[^1].phase == spDone
      check states[^1].exitCode.isSome
