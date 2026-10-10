## docs/conductors.md section 12 / RUN-008 / IAM-003: a conductor on the push channel (against a real rqlite and real CURVE sockets): it proves
## itself, says how many runs it can take, and the core pushes it the runs of its organisation within that; its calls are answered, and it can
## call only for the runs it holds. Needs CINIM_RQLITE_URL (a scratch rqlite); otherwise the suite is skipped.
import std/[unittest, json, os, options, atomics, sequtils, strutils]
import common/[rqlite, stream, zmqcurve, ctrlauth]
import core/[schema, scheduler, loggate, logcircuit, streamhub, workkick, retrypolicy, hubmetrics]
import protobuf_serialization

let url = getEnv("CINIM_RQLITE_URL")
let certs = getCurrentDir() / "tests" / "certs"
const port = 29847

proc runStream(a: tuple[co: Core, port: int]) {.thread.} = serveStream(a.co, a.port, workers = 4)

suite "RUN-016 conductors on the push channel":
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
    safetyPassSeconds = 3.0
    var th: Thread[tuple[co: Core, port: int]]
    createThread(th, runStream, (co, port))
    let corePub = loadPublicKey(certs, "core")
    let clientKeys = loadKeypair(certs, "client")
    let master = coreSecretKey(certs)
    let serverAddr = "tcp://127.0.0.1:" & $port
    sleep 300
    var n = 0
    proc newOrg(podLimit = 20): tuple[profile, ns: string] =
      inc n
      let org = c.addOrganization("cd" & $n & "-" & sfx, "S")
      let ns = "cinim-001-cd" & $n & "-" & sfx
      let prof = c.ensureOrganizationProfile(org, ns)
      var s = defaultSettings()
      s.podLimit = podLimit
      co.setProfileSettings(s, prof)
      (prof, ns)

    proc hello(session, id, ns: string; places: int; ack = 0'u64; fid = 1'u64; held: seq[string] = @[]; credential = ""): StreamFrame =
      let cred = if credential.len > 0: credential else: conductorCredential(master, ns, id)
      frame(session, "conductor.hello", encodeHello(ConductorHello(conductor_id: id, namespace: ns, credential: cred, api_versions: @[1'u32],
        free_places: uint32(places), held_runs: held)), id = fid, ack = ack, key = ns)

    proc call(session, ns: string; fid: uint64; req: ExecutorRequest; ack = 0'u64): StreamFrame =
      frame(session, "conductor.call", encodeExecRequest(req), id = fid, ack = ack, key = ns)

    proc hostCall(runId, token, kind, payload: string; seq = 1): ExecutorRequest =
      ExecutorRequest(header: Header(protocol: 1), body: ExecutorRequestBody(kind: ExecutorRequestBodyKind.call,
        call: HostCall(run_id: runId, lease_token: token, seq: uint64(seq), kind: kind, payload: cast[seq[byte]](payload),
                       numbered: kind == "job_sh", step_no: uint32(seq))))

    proc finishReq(runId, token: string): ExecutorRequest =
      ExecutorRequest(header: Header(protocol: 1), body: ExecutorRequestBody(kind: ExecutorRequestBodyKind.finish,
        finish: FinishRun(run_id: runId, state: RUN_STATE_SUCCEEDED, lease_token: token)))

    proc nextKind(cl: ZConnection; kind: string; ms = 8000): Option[StreamFrame] =
      for _ in 0 ..< 20:
        let f = cl.receive(ms)
        if f.isNone: return f
        if f.get.kind == kind: return f
      none(StreamFrame)

    proc runState(runId: string): string =
      c.query(%*[["SELECT state FROM runs WHERE id = ?", runId]])["results"][0]["values"][0][0].getStr

    test "a conductor with a wrong credential is refused and gets no run":
      let o = newOrg()
      discard co.createRun("p", "return 1", "t1", o.profile)
      var cl = connectStream(serverAddr, corePub, clientKeys)
      check cl.sendFrame(hello("cd-bad-" & sfx, "c-bad", o.ns, 5, credential = "nope"))
      let w = cl.nextKind("conductor.welcome")
      check w.isSome and w.get.payload == "unauthorized" and w.get.re == 1
      check cl.nextKind("conductor.lease", 1500).isNone
      cl.close()
    test "the credential of another namespace, or of another conductor, is refused":
      let a = newOrg()
      let b = newOrg()
      var cl = connectStream(serverAddr, corePub, clientKeys)
      check cl.sendFrame(hello("cd-x-" & sfx, "c-x", a.ns, 5, credential = conductorCredential(master, b.ns, "c-x")))
      check cl.nextKind("conductor.welcome").get.payload == "unauthorized"
      check cl.sendFrame(hello("cd-y-" & sfx, "c-y", a.ns, 5, credential = conductorCredential(master, a.ns, "c-other")))
      check cl.nextKind("conductor.welcome").get.payload == "unauthorized"
      cl.close()
    test "a hello is welcomed and the runs that wait are pushed, numbered, within the free places":
      let o = newOrg()
      var ids: seq[string]
      for i in 0 ..< 3: ids.add co.createRun("p", "return " & $i, "t1", o.profile)
      var cl = connectStream(serverAddr, corePub, clientKeys)
      let ses = "cd-a-" & sfx
      check cl.sendFrame(hello(ses, "c-a", o.ns, 2))
      let w = cl.nextKind("conductor.welcome")
      check w.isSome and w.get.payload == "" and w.get.re == 1
      var got: seq[LeaseGranted]
      for _ in 0 ..< 2:
        let l = cl.nextKind("conductor.lease")
        check l.isSome and l.get.id > 0
        got.add decodeLeaseGranted(l.get.payload)
      check got.mapIt(it.run_id) == ids[0 .. 1]
      check got[0].script == "return 0" and got[0].lease_token.len > 0 and got[0].api_version == 1
      check cl.nextKind("conductor.lease", 1500).isNone         # no place left: the third waits
      # a place is free again (the conductor says so): the third run comes
      check cl.sendFrame(hello(ses, "c-a", o.ns, 1, ack = 2, fid = 2, held = ids[0 .. 0]))
      let third = cl.nextKind("conductor.lease")
      check third.isSome and decodeLeaseGranted(third.get.payload).run_id == ids[2]
      cl.close()
    test "a run made later is pushed without the conductor asking":
      let o = newOrg()
      var cl = connectStream(serverAddr, corePub, clientKeys)
      check cl.sendFrame(hello("cd-b-" & sfx, "c-b", o.ns, 3))
      check cl.nextKind("conductor.welcome").isSome
      let r = co.createRun("p", "return 1", "t1", o.profile)
      let l = cl.nextKind("conductor.lease")
      check l.isSome and decodeLeaseGranted(l.get.payload).run_id == r
      cl.close()
    test "a conductor gets the runs of its own organisation only":
      let a = newOrg()
      let b = newOrg()
      let rb = co.createRun("p", "return 1", "t1", b.profile)
      var cl = connectStream(serverAddr, corePub, clientKeys)
      check cl.sendFrame(hello("cd-c-" & sfx, "c-c", a.ns, 3))
      check cl.nextKind("conductor.welcome").isSome
      check cl.nextKind("conductor.lease", 1500).isNone
      check runState(rb) == "RUNNING"
      cl.close()
    test "the calls of the holder are answered; a finish ends the run":
      let o = newOrg()
      let r = co.createRun("p", "return 1", "t1", o.profile)
      var cl = connectStream(serverAddr, corePub, clientKeys)
      let ses = "cd-d-" & sfx
      check cl.sendFrame(hello(ses, "c-d", o.ns, 1))
      let lease = decodeLeaseGranted(cl.nextKind("conductor.lease").get.payload)
      check cl.sendFrame(call(ses, o.ns, 2, hostCall(r, lease.lease_token, "params", "{}")))
      let a = cl.nextKind("conductor.reply")
      check a.isSome and a.get.re == 2
      let ra = decodeExecResponse(a.get.payload)
      check ra.body.kind == ExecutorResponseBodyKind.result and not ra.body.result.suspended
      check cl.sendFrame(call(ses, o.ns, 3, finishReq(r, lease.lease_token)))
      let f = cl.nextKind("conductor.reply")
      check f.isSome and f.get.re == 3 and decodeExecResponse(f.get.payload).body.kind == ExecutorResponseBodyKind.result
      check runState(r) == "SUCCEEDED"
      cl.close()
    test "a step call suspends the run, makes the step, and gives the lease back":
      let o = newOrg()
      let r = co.createRun("p", "return 1", "t1", o.profile)
      var cl = connectStream(serverAddr, corePub, clientKeys)
      let ses = "cd-e-" & sfx
      check cl.sendFrame(hello(ses, "c-e", o.ns, 1))
      let lease = decodeLeaseGranted(cl.nextKind("conductor.lease").get.payload)
      check cl.sendFrame(call(ses, o.ns, 2, hostCall(r, lease.lease_token, "job_sh", "k1\talpine\t\t\techo hi")))
      let a = cl.nextKind("conductor.reply")
      check a.isSome and decodeExecResponse(a.get.payload).body.result.suspended
      check c.query(%*[["SELECT COUNT(*) FROM steps WHERE run_id = ? AND state = 'PENDING'", r]])["results"][0]["values"][0][0].getInt == 1
      check c.query(%*[["SELECT lease_until FROM runs WHERE id = ?", r]])["results"][0]["values"][0][0].getInt == 0
      cl.close()
    test "a conductor cannot call for a run of another organisation, or for one that another conductor holds":
      let a = newOrg()
      let b = newOrg()
      let rb = co.createRun("p", "return 1", "t1", b.profile)
      let ra = co.createRun("p", "return 1", "t1", a.profile)
      var held = connectStream(serverAddr, corePub, clientKeys)
      check held.sendFrame(hello("cd-h1-" & sfx, "c-h1", a.ns, 1))
      let lease = decodeLeaseGranted(held.nextKind("conductor.lease").get.payload)
      check lease.run_id == ra
      var other = connectStream(serverAddr, corePub, clientKeys)
      let ses = "cd-h2-" & sfx
      check other.sendFrame(hello(ses, "c-h2", a.ns, 0))
      check other.nextKind("conductor.welcome").isSome
      check other.sendFrame(call(ses, a.ns, 2, hostCall(rb, "x", "params", "{}")))        # another organisation's run
      check decodeExecResponse(other.nextKind("conductor.reply").get.payload).body.failure.code == "forbidden"
      check other.sendFrame(call(ses, a.ns, 3, hostCall(ra, lease.lease_token, "params", "{}")))   # a run of this organisation, held by another conductor
      check decodeExecResponse(other.nextKind("conductor.reply").get.payload).body.failure.code == "lease_lost"
      check runState(ra) == "RUNNING"
      held.close()
      other.close()
    test "a call from a session the core does not know is answered with resync":
      let o = newOrg()
      var cl = connectStream(serverAddr, corePub, clientKeys)
      check cl.sendFrame(call("nobody-" & sfx, o.ns, 1, hostCall("r", "t", "params", "{}")))
      check cl.nextKind("resync", 3000).isSome
      cl.close()
    test "the same conductor on a new connection: what was pushed to the old one and never acknowledged is given back, and goes to the new":
      let o = newOrg()
      let r = co.createRun("p", "return 1", "t1", o.profile)
      var old = connectStream(serverAddr, corePub, clientKeys)
      check old.sendFrame(hello("cd-old-" & sfx, "c-f", o.ns, 1))
      check decodeLeaseGranted(old.nextKind("conductor.lease").get.payload).run_id == r
      old.close()                                                  # gone before it acknowledged anything
      var fresh = connectStream(serverAddr, corePub, clientKeys)
      check fresh.sendFrame(hello("cd-new-" & sfx, "c-f", o.ns, 1))
      let again = fresh.nextKind("conductor.lease")
      check again.isSome and decodeLeaseGranted(again.get.payload).run_id == r
      check c.query(%*[["SELECT lease_attempt FROM runs WHERE id = ?", r]])["results"][0]["values"][0][0].getInt == 2
      fresh.close()
    test "a restarted conductor that holds nothing gets back the runs the core thought it held":
      let o = newOrg()
      let r = co.createRun("p", "return 1", "t1", o.profile)
      var first = connectStream(serverAddr, corePub, clientKeys)
      check first.sendFrame(hello("cd-g1-" & sfx, "c-g", o.ns, 1))
      let l1 = first.nextKind("conductor.lease")
      check first.sendFrame(frame("cd-g1-" & sfx, "ping", ack = l1.get.id, key = o.ns))     # acknowledged: it holds the run
      first.close()
      var second = connectStream(serverAddr, corePub, clientKeys)
      check second.sendFrame(hello("cd-g2-" & sfx, "c-g", o.ns, 1, held = @[]))             # it holds nothing: the process was restarted
      let l2 = second.nextKind("conductor.lease")
      check l2.isSome and decodeLeaseGranted(l2.get.payload).run_id == r
      second.close()
    test "RUN-009 an idle conductor above the number wanted is told to drain, one within it is not, and a draining one gets no run":
      let o = newOrg()                                     # nothing to do: one conductor is wanted (conductor_min 1)
      conductorIdleSeconds = 1.0
      drainPassSeconds = 1.0
      var keep = connectStream(serverAddr, corePub, clientKeys)
      var extra = connectStream(serverAddr, corePub, clientKeys)
      check keep.sendFrame(hello("cd-k1-" & sfx, "cond-1", o.ns, 0))
      check extra.sendFrame(hello("cd-k2-" & sfx, "cond-2", o.ns, 5))
      check extra.nextKind("conductor.drain", 8000).isSome
      check keep.nextKind("conductor.drain", 2500).isNone
      let r = co.createRun("p", "return 1", "t1", o.profile)
      check extra.nextKind("conductor.lease", 1500).isNone          # draining: no more runs
      check runState(r) == "RUNNING"
      conductorIdleSeconds = 300.0
      drainPassSeconds = 10.0
      keep.close()
      extra.close()
    test "a hello from a session the core does not know, with an acknowledgement above 0, is told to start again, and is welcomed when it does":
      let o = newOrg()
      let r = co.createRun("p", "return 1", "t1", o.profile)
      var cl = connectStream(serverAddr, corePub, clientKeys)
      let ses = "cd-rs-" & sfx
      check cl.sendFrame(hello(ses, "c-rs", o.ns, 3, ack = 4))
      check cl.nextKind("resync", 8000).isSome
      check cl.nextKind("conductor.lease", 1500).isNone               # nothing was leased to a conductor that does not count right
      check cl.sendFrame(hello(ses, "c-rs", o.ns, 3, ack = 0, fid = 2))
      check cl.nextKind("conductor.welcome").isSome
      let l = cl.nextKind("conductor.lease")
      check l.isSome and decodeLeaseGranted(l.get.payload).run_id == r
      cl.close()
    test "the metrics count the conductors' frames and the runs pushed":
      let m = renderHubMetrics()
      check "cinim_stream_frames_total{direction=\"in\",kind=\"hello\"}" in m
      check "cinim_stream_frames_total{direction=\"out\",kind=\"lease\"}" in m
      check not ("cinim_stream_pushed_runs_total 0\n" in m)
    stopServers.store(true)
    joinThread(th)
