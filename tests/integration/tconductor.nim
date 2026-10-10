## RUN-009 / docs/conductors.md section 5: the conductor program itself, started by hand against the hub of a core (real rqlite, real CURVE sockets):
## a run process per leased run, the run's host calls carried to the core, a run that waits for a step suspended and taken again, a refused
## credential, and a drain that leaves nothing behind. Needs CINIM_RQLITE_URL (a scratch rqlite); builds `build/conductor` if it is not there.
import std/[unittest, json, os, osproc, atomics, strutils, times, strtabs]
import common/[rqlite, ctrlauth]
import core/[schema, scheduler, loggate, logcircuit, streamhub, retrypolicy]

let url = getEnv("CINIM_RQLITE_URL")
let certs = getCurrentDir() / "tests" / "certs"
const port = 29848

proc runStream(a: tuple[co: Core, port: int]) {.thread.} = serveStream(a.co, a.port, workers = 2)

suite "RUN-009 the conductor":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    let binary = getCurrentDir() / "build" / "conductor"
    if not fileExists(binary):
      check execCmd("nim c --hints:off --warnings:off -p:src --outdir:build -o:build/conductor src/conductor/main.nim") == 0
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns", certs: certs)
    stopServers.store(false)
    safetyPassSeconds = 2.0
    var th: Thread[tuple[co: Core, port: int]]
    createThread(th, runStream, (co, port))
    sleep 300
    let master = coreSecretKey(certs)
    var n = 0
    proc newOrg(): tuple[profile, ns: string] =
      inc n
      let org = c.addOrganization("cn" & $n & "-" & sfx, "S")
      let ns = "cinim-001-cn" & $n & "-" & sfx
      (c.ensureOrganizationProfile(org, ns), ns)

    proc startConductor(ns, id: string; credential = ""; places = 10): Process =
      let env = newStringTable()
      for k, v in envPairs(): env[k] = v
      env["CINIM_CORE_STREAM_ADDR"] = "tcp://127.0.0.1:" & $port
      env["CINIM_CERTS"] = certs
      env["CINIM_NAMESPACE"] = ns
      env["CINIM_CONDUCTOR_ID"] = id
      env["CINIM_CONDUCTOR_CREDENTIAL"] = if credential.len > 0: credential else: conductorCredential(master, ns, id)
      env["CINIM_RUNS_PER_CONDUCTOR"] = $places
      startProcess(binary, env = env, options = {poStdErrToStdOut})

    proc stateOf(runId: string): string =
      c.query(%*[["SELECT state FROM runs WHERE id = ?", runId]])["results"][0]["values"][0][0].getStr

    proc waitState(runId, want: string; seconds = 30): bool =
      let deadline = epochTime() + seconds.float
      while epochTime() < deadline:
        if stateOf(runId) == want: return true
        sleep 200
      false

    proc stop(p: Process) =
      p.terminate()
      discard p.waitForExit(10000)
      p.close()

    test "RUN-009 a run is led by a run process of the conductor to its end":
      let o = newOrg()
      let p = startConductor(o.ns, "c-t1")
      let ok = co.createRun("p", "return 1", "t1", o.profile)
      let bad = co.createRun("p", "error('boom')", "t1", o.profile)
      check waitState(ok, "SUCCEEDED")
      check waitState(bad, "FAILED")
      stop p
    test "RUN-009 a run that waits for a step is suspended, and led again when the step is over":
      let o = newOrg()
      let p = startConductor(o.ns, "c-t2")
      let script = "return ci.pipeline({name='m', main=function(run) ci.job({image='busybox:1.36'}, function(j) j:sh('echo hi') end) return 'ok' end})"
      let r = co.createRun("p", script, "t1", o.profile)
      let deadline = epochTime() + 30
      var steps = 0
      while epochTime() < deadline and steps == 0:
        steps = c.query(%*[["SELECT COUNT(*) FROM steps WHERE run_id = ?", r]])["results"][0]["values"][0][0].getInt
        sleep 200
      check steps == 1
      check stateOf(r) == "RUNNING"
      sleep 1000
      check c.query(%*[["SELECT lease_until FROM runs WHERE id = ?", r]])["results"][0]["values"][0][0].getInt == 0     # given back while it waits
      let step = c.query(%*[["SELECT ordinal FROM steps WHERE run_id = ?", r]])["results"][0]["values"][0][0].getInt
      discard c.execute(%*[["UPDATE steps SET state = 'RUNNING' WHERE run_id = ?", r]])
      applyTransition(c, defaultPolicy(), PodTransition(step: StepRef(run_id: r, seq: uint32(step), attempt: 1),
                                                         state: STEP_STATE_SUCCEEDED, exit_code: 0, termination_reason: "ok"))
      check waitState(r, "SUCCEEDED")
      stop p
    test "IAM-003 a conductor with a credential the core does not accept stops with a refusal and leads nothing":
      let o = newOrg()
      let r = co.createRun("p", "return 1", "t1", o.profile)
      let p = startConductor(o.ns, "c-t3", credential = "wrong")
      check p.waitForExit(15000) == 3
      check stateOf(r) == "RUNNING"
      p.close()
    test "RUN-009 a conductor holds at most its places: more runs wait in the queue":
      let o = newOrg()
      var ids: seq[string]
      for i in 0 ..< 4: ids.add co.createRun("p", "return " & $i, "t1", o.profile)
      let p = startConductor(o.ns, "c-t4", places = 2)
      for r in ids: check waitState(r, "SUCCEEDED", 40)      # two at a time, the others as places free up
      stop p
    test "RUN-009 a conductor that is told to stop says so, exits with 0":
      let o = newOrg()
      let p = startConductor(o.ns, "c-t5")
      sleep 1500
      p.terminate()
      check p.waitForExit(15000) == 0
      p.close()
    proc finishStep(run: string; ordinal: int) =
      discard c.execute(%*[["UPDATE steps SET state = 'RUNNING' WHERE run_id = ? AND ordinal = ?", run, ordinal]])
      applyTransition(c, defaultPolicy(), PodTransition(step: StepRef(run_id: run, seq: uint32(ordinal), attempt: 1),
                                                         state: STEP_STATE_SUCCEEDED, exit_code: 0, termination_reason: "ok"))

    proc pendingOrdinals(run: string): seq[int] =
      let v = c.query(%*[["SELECT ordinal FROM steps WHERE run_id = ? AND state = 'PENDING' ORDER BY ordinal", run]])["results"][0]{"values"}
      if v != nil:
        for row in v: result.add row[0].getInt

    test "PIP-003 the steps of a run get the numbers of its table, not their places in the journal, and the run goes to its end":
      let o = newOrg()
      let p = startConductor(o.ns, "c-t6")
      let script = "ci.job({image='a'}, function(j)\n  for i = 1, 3 do j:sh('x' .. i) end\n  j:sh('tail')\nend)"
      let r = co.createRun("p", script, "t1", o.profile)
      var seen: seq[int]
      let deadline = epochTime() + 90
      while epochTime() < deadline and stateOf(r) == "RUNNING":
        for n in pendingOrdinals(r):
          if n notin seen:
            seen.add n
            finishStep(r, n)
        sleep 200
      check stateOf(r) == "SUCCEEDED"
      check seen == @[0, 1, 2, 10]                      # the loop has the block 0..9, the step after it starts at 10
      check c.query(%*[["SELECT step_table FROM runs WHERE id = ?", r]])["results"][0]["values"][0][0].getStr.startsWith("{\"v\":1")
      check c.query(%*[["SELECT group_concat(seq) FROM run_journal WHERE run_id = ? AND seq >= 0", r]])["results"][0]["values"][0][0].getStr == "0,1,2,3"
      stop p
    test "PIP-006 a script with more than 200 steps ends before it makes a single one, with step_limit":
      let o = newOrg()
      let p = startConductor(o.ns, "c-t7")
      let r = co.createRun("p", "ci.job({image='a'}, function(j) for i = 1, 201 do j:sh('x') end end)", "t1", o.profile)
      check waitState(r, "FAILED")
      check c.query(%*[["SELECT fail_code FROM runs WHERE id = ?", r]])["results"][0]["values"][0][0].getStr == "step_limit"
      check c.query(%*[["SELECT COUNT(*) FROM steps WHERE run_id = ?", r]])["results"][0]["values"][0][0].getInt == 0
      stop p
    test "PIP-018 an id used twice ends the run with duplicate_id before any step is made":
      let o = newOrg()
      let p = startConductor(o.ns, "c-t8")
      let r = co.createRun("p", "ci.job({image='a'}, function(j)\n j:sh('x', {id='same'})\n j:sh('y', {id='same'})\nend)", "t1", o.profile)
      check waitState(r, "FAILED")
      check c.query(%*[["SELECT fail_code FROM runs WHERE id = ?", r]])["results"][0]["values"][0][0].getStr == "duplicate_id"
      check c.query(%*[["SELECT COUNT(*) FROM steps WHERE run_id = ?", r]])["results"][0]["values"][0][0].getInt == 0
      stop p
    stopServers.store(true)
    joinThread(th)
