## RUN-016 / docs/conductors.md section 12: a controller keeps a connection to the core and the core pushes work to it at once (against a real
## rqlite and real CURVE sockets). Needs CINIM_RQLITE_URL (a scratch rqlite); otherwise the suite is skipped.
import std/[unittest, json, os, options, atomics, sequtils]
import common/[rqlite, stream, zmqcurve]
import core/[schema, scheduler, loggate, logcircuit, streamhub, workkick, retrypolicy]

let url = getEnv("CINIM_RQLITE_URL")
let certs = getCurrentDir() / "tests" / "certs"
const port = 29846

proc addStep(c: var RqClient; runId, profileId: string; ordinal: int) =
  let jobId = newId()
  discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, ?, 'RUNNING', ?)", jobId, runId, "j" & $ordinal, profileId]])
  discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at) " &
    "VALUES (?, ?, ?, ?, 'sh', 'PENDING', ?, 'alpine', 'true', '', ?)", newId(), runId, jobId, ordinal, profileId, $ordinal]])

proc report(session, ns: string; slots: int; ack = 0'u64; id = 1'u64): StreamFrame =
  frame(session, "controller.report", encodeReport(PollRequest(header: Header(protocol: 1), session_id: session, namespace: ns,
    free_pod_slots: uint32(slots), inventory_complete: true)), id = id, ack = ack)

proc starts(f: StreamFrame): seq[string] =
  let resp = decodeWork(f.payload)
  for cmd in resp.commands:
    if cmd.body.kind == CommandBodyKind.start: result.add cmd.body.start.step.run_id

proc runStream(a: tuple[co: Core, port: int]) {.thread.} = serveStream(a.co, a.port)

suite "RUN-016 the push channel":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns", certs: certs)
    stopServers.store(false)
    var th: Thread[tuple[co: Core, port: int]]
    createThread(th, runStream, (co, port))
    let corePub = loadPublicKey(certs, "core")
    let clientKeys = loadKeypair(certs, "client")
    let serverAddr = "tcp://127.0.0.1:" & $port
    sleep 300
    var n = 0
    proc newOrg(podLimit = 20): tuple[profile, ns: string] =
      inc n
      let org = c.addOrganization("st" & $n & "-" & sfx, "S")
      let ns = "cinim-001-st" & $n & "-" & sfx
      let prof = c.ensureOrganizationProfile(org, ns)
      var s = defaultSettings()
      s.podLimit = podLimit
      s.jobPodLimitPercent = 100
      co.setProfileSettings(s, prof)
      (prof, ns)
    proc next(cl: ZConnection; ms = 8000): Option[StreamFrame] =
      ## the next frame that is not just 'heard you'
      for _ in 0 ..< 10:
        let f = cl.receive(ms)
        if f.isNone: return f
        if f.get.kind != "ping": return f
      none(StreamFrame)

    test "a report is answered like a poll: the steps that may go, numbered":
      let o = newOrg()
      let r = co.createRun("p", "return 1", "t1", o.profile)
      for i in 1 .. 3: c.addStep(r, o.profile, i)
      var cl = connectStream(serverAddr, corePub, clientKeys)
      check cl.sendFrame(report("s-a-" & sfx, o.ns, 10))
      let w = cl.next()
      check w.isSome and w.get.kind == "controller.work" and w.get.id == 1
      check w.get.re == 1                                         # it answers report number 1
      check w.get.starts.len == 3
      cl.close()
    test "work created later is pushed without the controller asking":
      let o = newOrg()
      var cl = connectStream(serverAddr, corePub, clientKeys)
      let ses = "s-b-" & sfx
      check cl.sendFrame(report(ses, o.ns, 10))
      discard cl.receive(2000)                                  # the answer to the report: nothing to tell (a ping)
      let r = co.createRun("p", "return 1", "t1", o.profile)
      c.addStep(r, o.profile, 1)
      kickProfile(o.profile)
      let w = cl.next(8000)
      check w.isSome and w.get.kind == "controller.work"
      check w.get.starts == @[r]
      cl.close()
    test "the controller's credit is not exceeded: a push carries at most the free slots it reported":
      let o = newOrg()
      let r = co.createRun("p", "return 1", "t1", o.profile)
      for i in 1 .. 5: c.addStep(r, o.profile, i)
      var cl = connectStream(serverAddr, corePub, clientKeys)
      let ses = "s-c-" & sfx
      check cl.sendFrame(report(ses, o.ns, 2))
      let w = cl.next()
      check w.isSome and w.get.starts.len == 2
      kickProfile(o.profile)
      check cl.next(1500).isNone                                  # no credit left: nothing more until it reports again
      check cl.sendFrame(report(ses, o.ns, 2, ack = w.get.id))
      let w2 = cl.next()
      check w2.isSome and w2.get.starts.len == 2
      cl.close()
    test "what is not acknowledged is sent again on a new connection, once acknowledged it is not":
      let o = newOrg()
      let r = co.createRun("p", "return 1", "t1", o.profile)
      c.addStep(r, o.profile, 1)
      let ses = "s-d-" & sfx
      var cl = connectStream(serverAddr, corePub, clientKeys)
      check cl.sendFrame(report(ses, o.ns, 10))
      let w = cl.next()
      check w.isSome and w.get.id == 1
      cl.close()                                                   # the controller lost the frame (or its connection) without acknowledging
      var again = connectStream(serverAddr, corePub, clientKeys)
      check again.sendFrame(report(ses, o.ns, 10, ack = 0))
      let w2 = again.next()
      check w2.isSome and w2.get.id == 1 and w2.get.starts == @[r]     # the same frame, the same number
      check again.sendFrame(report(ses, o.ns, 10, ack = 1))
      var third = connectStream(serverAddr, corePub, clientKeys)
      check third.sendFrame(report(ses, o.ns, 10, ack = 1))
      check third.next(1500).isNone                                # acknowledged: not sent again
      again.close()
      third.close()
    test "a frame from a session the core does not know is answered with resync":
      var cl = connectStream(serverAddr, corePub, clientKeys)
      check cl.sendFrame(frame("nobody-" & sfx, "ping"))
      let f = cl.receive(3000)
      check f.isSome and f.get.kind == "resync"
      cl.close()
    test "a controller of another organisation gets none of this one's work":
      let a = newOrg()
      let b = newOrg()
      let ra = co.createRun("p", "return 1", "t1", a.profile)
      c.addStep(ra, a.profile, 1)
      var cb = connectStream(serverAddr, corePub, clientKeys)
      check cb.sendFrame(report("s-e-" & sfx, b.ns, 10))
      let w = cb.next(1500)                                        # at most its settings: no step of the other organisation
      check w.isNone or w.get.starts.len == 0
      kickProfile(a.profile)
      kickProfile(b.profile)
      let again = cb.next(1500)
      check again.isNone or again.get.starts.len == 0
      cb.close()
    stopServers.store(true)
    joinThread(th)
