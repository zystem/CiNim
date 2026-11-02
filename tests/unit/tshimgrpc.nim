## RUN-007, D-29, D-75: the shim's log pipeline, its state and its report reach the core's real servers over gRPC with mutual TLS and are answered by the real handlers. The database is a port that
## nothing listens on and vlagent is a stand-in (as in tlogcollector): the log is acknowledged by vlagent alone, the state and the report are answered "later", which is an answer.
import std/[os, osproc, atomics, strutils]
import unittest2
import ../../src/core/[logcollector, scheduler]
import ../../src/shim/logclient
import ../support/fakevlagent

const
  logPort = 28743
  statusPort = 28746
  reportPort = 28742
  vlPort = 18796

proc runLog(a: tuple[co: Collector, certs: string, port: int]) {.thread.} = serveLogIngest(a.co, a.certs, a.port)
proc runStatus(a: tuple[url, certs: string, port: int]) {.thread.} = serveStatus(a.url, a.certs, a.port)
proc runReport(a: tuple[url, certs: string, port: int, profile: string]) {.thread.} = serveStepReport(a.url, a.certs, a.port, a.profile)

let base = getTempDir() / ("tshimgrpc-" & $getCurrentProcessId())
let certs = base / "certs"
var haveKeys = false

suite "RUN-007 the shim talks to the core's servers over gRPC":
  test "setup: keys, a stand-in for vlagent, the three servers":
    removeDir base
    createDir base
    copyDir(getCurrentDir() / "tests" / "certs" / "curve", certs / "curve")      # the master key of the core is made from it
    haveKeys = execCmd("sh " & quoteShell(getCurrentDir() / "tools" / "grpc" / "gen_tls.sh") & " " & quoteShell(certs) & " 2") == 0
    if not haveKeys: skip()
    startFakeVlagent(vlPort)
    stopServers.store(false)
    let dead = "http://127.0.0.1:1"
    var t1: Thread[tuple[co: Collector, certs: string, port: int]]
    var t2: Thread[tuple[url, certs: string, port: int]]
    var t3: Thread[tuple[url, certs: string, port: int, profile: string]]
    createThread(t1, runLog, (Collector(rqliteUrl: dead, vlagentUrl: "http://127.0.0.1:" & $vlPort & "/insert/jsonline"), certs, logPort))
    createThread(t2, runStatus, (dead, certs, statusPort))
    createThread(t3, runReport, (dead, certs, reportPort, "p"))
    sleep 800

  test "RUN-007 a step's output goes through the spool and the sender to vlagent, and every block is acknowledged":
    if not haveKeys: skip()
    let before = takenCount()
    var lp = newLogPipeline(LogCfg(collectorAddr: "tcp://127.0.0.1:" & $logPort, statusAddr: "tcp://127.0.0.1:" & $statusPort, certs: certs, spoolDir: base / "spool",
                                    step: StepRef(run_id: "s1_g1", seq: 0, attempt: 1), spoolCap: 64'i64 * 1024 * 1024, holdSeconds: 30))
    for i in 0 ..< 2000: lp.write("line " & $i & " of the step's output\n")
    lp.tick()
    check lp.finish(30)
    check stats().delivered > 0 and stats().dropped == 0
    check takenCount() > before

  test "D-29 the report and the request for secrets are answered by the core's handlers, not by silence":
    if not haveKeys: skip()
    let step = StepRef(run_id: "s1_g1", seq: 0, attempt: 1)
    check sendStepReport("tcp://127.0.0.1:" & $reportPort, certs, step, 0, "") == false       # "retry later": the database is away, but the core answered
    let s = fetchStepSecrets("tcp://127.0.0.1:" & $reportPort, certs, step, "token")
    check s.code != "no_answer" and not s.ok

  test "teardown":
    stopServers.store(true)
    sleep 1500
    stopFakeVlagent()
    if base.len > 0: removeDir base
