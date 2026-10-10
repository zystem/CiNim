## RUN-016 / docs/conductors.md section 12: a controller keeps a connection to the core and the core pushes work to it at once (against a real
## rqlite and real CURVE sockets). Needs CINIM_RQLITE_URL (a scratch rqlite); otherwise the suite is skipped.
import std/[unittest, json, os, options, atomics, sequtils]
import common/[rqlite, stream, zmqcurve]
import core/[schema, scheduler, loggate, logcircuit, streamhub, workkick, retrypolicy, hubmetrics]
import std/strutils

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
    free_pod_slots: uint32(slots), inventory_complete: true)), id = id, ack = ack, key = ns)

proc starts(f: StreamFrame): seq[string] =
  let resp = decodeWork(f.payload)
  for cmd in resp.commands:
    if cmd.body.kind == CommandBodyKind.start: result.add cmd.body.start.step.run_id

proc runStream(a: tuple[co: Core, port: int]) {.thread.} = serveStream(a.co, a.port, workers = 4)

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
    safetyPassSeconds = 6.0           # the test of a quiet report must be able to tell it from the safety pass, with a database that answers slowly
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

    proc nextStarts(cl: ZConnection; ms = 8000): Option[StreamFrame] =
      ## the next frame that carries steps to start (the answer to a report holds the settings; the steps are pushed after it)
      for _ in 0 ..< 10:
        let f = cl.next(ms)
        if f.isNone: return f
        if f.get.starts.len > 0: return f
      none(StreamFrame)

    test "a report is answered with the settings; the steps that may go are pushed after it, numbered":
      let o = newOrg()
      let r = co.createRun("p", "return 1", "t1", o.profile)
      for i in 1 .. 3: c.addStep(r, o.profile, i)
      var cl = connectStream(serverAddr, corePub, clientKeys)
      check cl.sendFrame(report("s-a-" & sfx, o.ns, 10))
      let a = cl.next()
      check a.isSome and a.get.kind == "controller.work" and a.get.id == 1
      check a.get.re == 1 and a.get.starts.len == 0               # the answer to report number 1: the settings, no steps
      let w = cl.nextStarts()
      check w.isSome and w.get.id == 2 and w.get.re == 0          # then the push, which answers nothing
      check w.get.starts.len == 3
      cl.close()
    test "work created later is pushed without the controller asking":
      let o = newOrg()
      var cl = connectStream(serverAddr, corePub, clientKeys)
      let ses = "s-b-" & sfx
      check cl.sendFrame(report(ses, o.ns, 10))
      discard cl.next(8000)                                     # the answer to the report: the settings
      # a second quiet report and its answer: by then the core has finished what the first report set going, so the step below is the kick's
      check cl.sendFrame(report(ses, o.ns, 10, ack = 1, id = 2))
      for _ in 0 ..< 10:
        let f = cl.receive(8000)
        if f.isNone or f.get.re == 2: break
      let r = co.createRun("p", "return 1", "t1", o.profile)
      c.addStep(r, o.profile, 1)
      kickProfile(o.profile)
      let w = cl.nextStarts()
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
      let w = cl.nextStarts()
      check w.isSome and w.get.starts.len == 2
      kickProfile(o.profile)
      check cl.next(1500).isNone                                  # no credit left: nothing more until it reports again
      check cl.sendFrame(report(ses, o.ns, 2, ack = w.get.id))
      let w2 = cl.nextStarts()
      check w2.isSome and w2.get.starts.len == 2
      cl.close()
    test "what is not acknowledged is sent again on a new connection, once acknowledged it is not":
      let o = newOrg()
      let r = co.createRun("p", "return 1", "t1", o.profile)
      c.addStep(r, o.profile, 1)
      let ses = "s-d-" & sfx
      var cl = connectStream(serverAddr, corePub, clientKeys)
      check cl.sendFrame(report(ses, o.ns, 10))
      let w = cl.nextStarts()
      check w.isSome and w.get.id == 2                             # 1: the settings, 2: the step
      cl.close()                                                   # the controller lost the frames (or its connection) without acknowledging
      var again = connectStream(serverAddr, corePub, clientKeys)
      check again.sendFrame(report(ses, o.ns, 10, ack = 0))
      let w2 = again.nextStarts()
      check w2.isSome and w2.get.id == 2 and w2.get.starts == @[r]    # the same frame, the same number
      check again.sendFrame(report(ses, o.ns, 10, ack = 2))
      var third = connectStream(serverAddr, corePub, clientKeys)
      check third.sendFrame(report(ses, o.ns, 10, ack = 2))
      check third.nextStarts(1500).isNone                          # acknowledged: not sent again
      again.close()
      third.close()
    test "a quiet report hands out nothing; the step waiting without a kick is found by the safety pass":
      let o = newOrg()
      var cl = connectStream(serverAddr, corePub, clientKeys)
      let ses = "s-q-" & sfx
      check cl.sendFrame(report(ses, o.ns, 10, id = 1))
      discard cl.next(8000)                                       # the settings
      # a second quiet report, and its answer: by then the core has finished everything the first report set going
      check cl.sendFrame(report(ses, o.ns, 10, ack = 1, id = 2))
      var answered = false
      for _ in 0 ..< 10:
        let f = cl.receive(8000)
        if f.isNone: break
        if f.get.re == 2:
          answered = true
          break
      check answered
      let r = co.createRun("p", "return 1", "t1", o.profile)
      c.addStep(r, o.profile, 1)                                  # no kick: made behind the core's back
      check cl.sendFrame(report(ses, o.ns, 10, ack = 1, id = 3))   # nothing changed for the controller
      check cl.nextStarts(1200).isNone                            # a quiet report does not look at the queue
      let found = cl.nextStarts(9000)                             # the pass that looks at the profiles with waiting steps does
      check found.isSome and found.get.starts == @[r]
      cl.close()
    test "a controller that was replaced: the newest session of an organisation is the only one, and what was pushed to the old one unacknowledged goes to it":
      let o = newOrg()
      var old = connectStream(serverAddr, corePub, clientKeys)
      let sOld = "s-old-" & sfx
      check old.sendFrame(report(sOld, o.ns, 10))
      discard old.next(8000)                                       # the settings
      let r = co.createRun("p", "return 1", "t1", o.profile)
      c.addStep(r, o.profile, 1)
      kickProfile(o.profile)
      let pushed = old.nextStarts()
      check pushed.isSome and pushed.get.starts == @[r]            # the step is claimed for the old controller
      check c.query(%*[["SELECT state, controller_id FROM steps WHERE run_id = ?", r]])["results"][0]["values"][0][0].getStr == "STARTING"
      old.close()                                                  # the controller is replaced before it acknowledged anything
      var fresh = connectStream(serverAddr, corePub, clientKeys)
      check fresh.sendFrame(report("s-new-" & sfx, o.ns, 10))
      let again = fresh.nextStarts()
      check again.isSome and again.get.starts == @[r]              # the step was taken back from the old session and pushed to the new one
      let now = c.query(%*[["SELECT state, controller_id FROM steps WHERE run_id = ?", r]])["results"][0]["values"][0]
      check now[0].getStr == "STARTING" and now[1].getStr == "s-new-" & sfx
      fresh.close()
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
    test "the pool: many organisations at once, each served in order, each gets only its own steps":
      var orgs: seq[tuple[profile, ns: string]]
      var runs: seq[string]
      for i in 0 ..< 8:
        let o = newOrg()
        let r = co.createRun("p", "return 1", "t1", o.profile)
        for k in 1 .. 2: c.addStep(r, o.profile, k)
        orgs.add o
        runs.add r
      var cls: seq[ZConnection]
      for i, o in orgs:
        cls.add connectStream(serverAddr, corePub, clientKeys)
        check cls[i].sendFrame(report("s-p" & $i & "-" & sfx, o.ns, 10))
      for i in 0 ..< orgs.len:
        let w = cls[i].nextStarts(15000)
        check w.isSome and w.get.starts == @[runs[i], runs[i]]       # its own run only, both steps in one frame
        check w.get.id == 2                                          # numbered in order: the settings were frame 1
        cls[i].close()
    test "the hub tells about itself: frames, pushed steps, the waits and the workers":
      let m = renderHubMetrics()
      check "cinim_stream_workers 4" in m
      check "cinim_stream_frames_total{direction=\"in\",kind=\"report\"}" in m
      check not ("cinim_stream_pushed_steps_total 0\n" in m)
      check not ("cinim_stream_frame_wait_seconds_count 0\n" in m)
      check not ("cinim_stream_kick_wait_seconds_count 0\n" in m)
    stopServers.store(true)
    joinThread(th)
