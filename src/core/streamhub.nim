## The core's end of the push channel (docs/conductors.md section 12): controllers keep a connection open, report their state, and the core
## pushes work to them as soon as there is some - no waiting for the next poll.
##
## A controller sends `controller.report` (a PollRequest: transitions, inventory, free slots) when something changes and at least every few
## seconds; the core answers it as it answered a poll (the same `handlePoll`, so every rule of the poll holds) and, besides, pushes
## `controller.work` (a PollResponse) whenever a kick says there is work for the controller's organisation (core/workkick.nim) and the controller
## has credit - the free slots it last reported, less what was pushed since. Work frames are numbered and kept until the controller's `ack`
## covers them; after a reconnect or after a few seconds without an acknowledgement they are sent again (common/streamstate.nim).
## A frame from a session the core does not know (a new connection, a restarted core) is answered with `resync`: the controller then sends its
## whole state. The core never dials a controller.
##
## The hub is a pool: one I/O thread owns the socket, reads the frames, takes the kicks and hands both to N workers (one per core of the Pod by
## default, CINIM_STREAM_WORKERS), and sends what the workers have to say. A frame goes to the worker of its `key` (the organisation's namespace;
## a frame without one, to the worker of its session), so everything of one organisation - its controller's report, the replacement of an old
## session, the credit, the pushes - is done by one worker, in order, and the workers share nothing but the database. Every worker has its own
## database client and its own table of controllers. Messages cross threads in shared memory (common/shmq.nim), never as Nim strings.
import std/[tables, options, times, os, atomics, sequtils, json, hashes]
import std/strutils
import common/[stream, streamstate, rqlite, zmqcurve, states, shmq, podcpu, ctrlauth]
import scheduler, schema, workkick, hubmetrics, components

const
  resendAfterSeconds = 5.0
  silentAfterSeconds = 60.0
  maxPeers = 5000

var safetyPassSeconds* = 3.0   ## the safety net under the kicks: a controller whose organisation has a step waiting is looked at this often (a pause that ended, a step the watchdog put back)

type
  Peer = object
    session, routingId, namespace, credential, profileId: string
    outbox: Outbox
    credit: Credit
    lastSeen, lastPush: float
    lastConfig, lastGate: string      ## what the controller was last told, so that an unchanged answer is not sent again

  Cond = object
    ## a conductor (docs/conductors.md): it takes runs, not steps; its credit is its free places
    session, routingId, id, namespace, profileId: string
    versions: seq[int]
    outbox: Outbox
    credit: Credit
    lastSeen, lastPush: float

  Hub = object
    co: Core
    conds: Table[string, Cond]
    outq: ptr ShmQueue                ## what the worker wants sent: the I/O thread owns the socket
    idx: int
    peers: Table[string, Peer]
    c: RqClient
    defaultProfile, master: string

func startCount(resp: PollResponse): int =
  for cmd in resp.commands:
    if cmd.body.kind == CommandBodyKind.start: inc result

proc worth(resp: PollResponse; p: Peer): bool =
  ## is there anything in the answer the controller does not have: commands, volumes to release, an identity matter, a changed setting or gate
  resp.commands.len > 0 or resp.release_storage.len > 0 or resp.issued_credential.len > 0 or resp.unauthorized or
    encodeConfig(resp.config) != p.lastConfig or $resp.gate.open & resp.gate.reason != p.lastGate

func metricKind(kind: string): string =
  case kind
  of "controller.report": "report"
  of "controller.work": "work"
  of "conductor.hello": "hello"
  of "conductor.call": "call"
  of "conductor.lease": "lease"
  of "conductor.reply": "reply"
  of "ping", "resync": kind
  else: "other"

proc emit(h: var Hub; routingId: string; f: StreamFrame) =
  ## every frame the core sends goes through here, so that it is counted
  count(mFramesOut, metricKind(f.kind))
  h.outq[].push(0, routingId, encodeFrame(f))                    # the I/O thread sends it (and counts a refusal of the socket)

proc sendNumbered(h: var Hub; p: var Peer; kind, payload: string; re = 0'u64) =
  let sent = p.outbox.push(kind, payload, epochTime())
  h.emit(p.routingId, frame("core", kind, payload, id = sent.id, re = re))

proc resendAll(h: var Hub; p: var Peer) =
  let now = epochTime()
  var ids: seq[uint64]
  for s in p.outbox.unacked:
    h.emit(p.routingId, frame("core", s.kind, s.payload, id = s.id))
    count(mResent)
    ids.add s.id
  p.outbox.sentAgain(ids, now)

proc deliver(h: var Hub; p: var Peer; resp: PollResponse; re = 0'u64) =
  ## one answer, as a pushed frame; the credit goes down by the steps it carries
  p.lastConfig = encodeConfig(resp.config)
  p.lastGate = $resp.gate.open & resp.gate.reason
  discard p.credit.take(startCount(resp))
  h.sendNumbered(p, "controller.work", encodeWork(resp), re)

proc profileOfNs(h: var Hub; ns: string): string =
  if ns.len == 0: h.defaultProfile else: profileOfNamespace(h.c, ns)

proc requeueUnacked(h: var Hub; p: Peer) =
  ## A controller that goes away (replaced by a new one, or silent) may leave steps that were handed to it and never acknowledged: nobody has made
  ## their Pods. They go back to the queue now, instead of waiting for the liveness timeout to find that no Pod ever came.
  for s in p.outbox.unacked:
    if s.kind != "controller.work": continue
    let w = try: decodeWork(s.payload) except CatchableError: continue
    for cmd in w.commands:
      if cmd.body.kind != CommandBodyKind.start: continue
      let st = cmd.body.start.step
      discard h.c.execute(%*[["UPDATE steps SET state = ?, controller_id = NULL, version = version + 1 WHERE run_id = ? AND ordinal = ? AND attempt = ? " &
        "AND state = ? AND controller_id = ?", protoName(ssPending), st.run_id, int(st.seq), int(st.attempt), protoName(ssStarting), p.session]])
      count(mRequeuedSteps)

proc dropPeer(h: var Hub; session: string; reason: string) =
  if session in h.peers:
    h.requeueUnacked(h.peers[session])
    h.peers.del session
    count(mDroppedPeers, reason)

proc pushTo(h: var Hub; p: var Peer)

proc onReport(h: var Hub; routingId: string; f: StreamFrame) =
  var req: PollRequest
  try: req = decodeReport(f.payload)
  except CatchableError: return
  let known = f.session in h.peers
  var p = if known: h.peers[f.session] else: Peer(session: f.session, outbox: initOutbox())
  let moved = known and p.routingId != routingId          # the same controller on a new connection
  p.routingId = routingId
  p.lastSeen = epochTime()
  p.outbox.ack(f.ack)
  if moved: h.resendAll(p)
  let resp = handlePoll(h.c, h.defaultProfile, h.master, req, claim = false)    # the state is taken in; steps are pushed below and on kicks
  if resp.unauthorized or resp.issued_credential.len > 0:
    # not registered: a controller that does not prove itself, or that is just being given its credential, has no credit and gets no pushes;
    # it reports again with the credential
    h.emit(routingId, frame("core", "controller.work", encodeWork(resp), id = 0, re = f.id))
    h.peers.del f.session
    return
  p.namespace = req.namespace
  # an organisation has one controller: a newer session replaces the older ones (a controller that was replaced leaves its connection to time out)
  var older: seq[string]
  for session, other in h.peers:
    if session != f.session and other.namespace == req.namespace: older.add session
  for session in older: h.dropPeer(session, "replaced")
  if req.credential.len > 0: p.credential = req.credential
  p.profileId = h.profileOfNs(req.namespace)
  let creditBefore = p.credit.available
  p.credit.set(int(req.free_pod_slots))
  if worth(resp, p): h.deliver(p, resp, re = f.id)
  else: h.emit(routingId, frame("core", "ping", re = f.id))     # heard, nothing to tell
  # Steps go out when a report changes what can go: the first report of a controller, an end (a place is free, so a waiting step may go), or
  # credit where there was none. A quiet report hands out nothing and asks the database nothing about the queue.
  if not known or req.transitions.len > 0 or (creditBefore <= 0 and req.free_pod_slots > 0):
    h.pushTo(p)
  p.lastPush = epochTime()
  if h.peers.len < maxPeers or known: h.peers[f.session] = p

proc pushTo(h: var Hub; p: var Peer) =
  ## look at what there is for this controller now, without its asking
  if p.credit.available <= 0: return
  let t0 = epochTime()
  let req = PollRequest(header: Header(protocol: 1), session_id: p.session, namespace: p.namespace, credential: p.credential,
                        free_pod_slots: uint32(p.credit.available), inventory_complete: false, kept_complete: false)
  let resp = handlePoll(h.c, h.defaultProfile, h.master, req, push = true)
  p.lastPush = epochTime()
  if not (resp.unauthorized or resp.issued_credential.len > 0) and worth(resp, p):      # an identity matter is sorted out by the controller's own report
    count(mPushedSteps, n = startCount(resp))
    h.deliver(p, resp)
  observe(hPush, epochTime() - t0)


# ------------------------------------------------------------------ conductors

proc condEmit(h: var Hub; c: var Cond; kind, payload: string; re = 0'u64; numbered = false) =
  if numbered:
    let sent = c.outbox.push(kind, payload, epochTime())
    h.emit(c.routingId, frame("core", kind, payload, id = sent.id, re = re))
  else:
    h.emit(c.routingId, frame("core", kind, payload, re = re))

proc attemptOfToken(token: string): int =
  ## the attempt a lease token is for (`<attempt>.<mac>`, core/runlease.nim)
  try: parseInt(token.split('.')[0]) except ValueError: 0

proc giveBackLeases(h: var Hub; c: Cond; unackedOnly: bool) =
  ## A conductor that is gone (replaced, silent) leaves runs that were leased to it. Those whose lease frame it never acknowledged were never started
  ## by anybody and go back at once; the others are given back too once the conductor itself is dropped, instead of waiting for the lease to run out.
  if unackedOnly:
    for s in c.outbox.unacked:
      if s.kind != "conductor.lease": continue
      let g = try: decodeLeaseGranted(s.payload) except CatchableError: continue
      discard h.c.execute(%*[["UPDATE runs SET lease_until = 0 WHERE id = ? AND lease_attempt = ? AND lease_owner = ?", g.run_id, attemptOfToken(g.lease_token), c.id]])
  else:
    discard h.c.execute(%*[["UPDATE runs SET lease_until = 0 WHERE lease_owner = ? AND state = ? AND lease_until != 0", c.id, protoName(rsRunning)]])

proc dropCond(h: var Hub; session, reason: string) =
  if session in h.conds:
    # a replaced conductor is alive somewhere else and says what it still holds in its hello; a silent one is gone, and all it held is given back
    h.giveBackLeases(h.conds[session], unackedOnly = reason == "replaced")
    h.conds.del session
    count(mDroppedPeers, reason)

proc pushLeases(h: var Hub; c: var Cond) =
  ## give the conductor runs of its organisation within its free places (RUN-004): the core's push, the conductor never asks
  if c.credit.available <= 0: return
  let t0 = epochTime()
  c.lastPush = t0
  for g in h.c.leaseForConductor(c.profileId, h.master, c.id, c.versions, c.credit.available):
    discard c.credit.take(1)
    h.condEmit(c, "conductor.lease", encodeLeaseGranted(g), numbered = true)
    count(mPushedRuns)
  observe(hPush, epochTime() - t0)

proc onHello(h: var Hub; routingId: string; f: StreamFrame) =
  var hello: ConductorHello
  try: hello = decodeHello(f.payload)
  except CatchableError: return
  let wrong = hello.conductor_id.len == 0 or hello.namespace.len == 0 or
              not constantTimeEqual(hello.credential, conductorCredential(h.master, hello.namespace, hello.conductor_id))
  if wrong:
    h.emit(routingId, frame("core", "conductor.welcome", "unauthorized", re = f.id))
    h.conds.del f.session
    return
  let known = f.session in h.conds
  var c = if known: h.conds[f.session] else: Cond(session: f.session, outbox: initOutbox())
  let moved = known and c.routingId != routingId
  c.routingId = routingId
  c.lastSeen = epochTime()
  c.id = hello.conductor_id
  c.namespace = hello.namespace
  c.versions = hello.api_versions.mapIt(int(it))
  c.outbox.ack(f.ack)
  if not known:
    # the same conductor on a newer connection replaces the older one: what it held is given back, the new one reports what it still has
    var older: seq[string]
    for session, other in h.conds:
      if session != f.session and other.id == c.id: older.add session
    for session in older: h.dropCond(session, "replaced")
    # runs the core thinks this conductor holds and that it does not hold any more (it restarted) are given back at once
    var held = ""
    for r in hello.held_runs: held.add "'" & r.replace("'", "") & "',"
    discard h.c.execute(%*[["UPDATE runs SET lease_until = 0 WHERE lease_owner = ? AND state = ? AND lease_until != 0 AND id NOT IN (" &
      held & "'')", c.id, protoName(rsRunning)]])
  if moved: 
    for s in c.outbox.unacked:
      h.emit(c.routingId, frame("core", s.kind, s.payload, id = s.id))
      count(mResent)
  c.profileId = h.profileOfNs(c.namespace)
  c.credit.set(int(hello.free_places))
  discard registryTouch("conductor", c.id, epochTime(), @[("runs", $hello.held_runs.len)])
  h.emit(routingId, frame("core", "conductor.welcome", "", re = f.id))
  h.pushLeases(c)
  h.conds[f.session] = c

proc failureReply(code, detail: string): ExecutorResponse =
  ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(kind: ExecutorResponseBodyKind.failure,
                                                                            failure: Failure(code: code, detail: detail)))

proc runOwnedBy(h: var Hub; c: Cond; runId: string): string =
  ## "" if the run is of the conductor's organisation and leased to this conductor; else the failure code to answer with. A conductor cannot name
  ## the run of another organisation (SEC-007, docs/conductors.md section 7).
  let r = h.c.query(%*[["SELECT profile_id, lease_owner FROM runs WHERE id = ?", runId]])["results"][0]{"values"}
  if r == nil or r.len == 0 or r[0][0].getStr != c.profileId: return "forbidden"
  if r[0][1].getStr != c.id: return "lease_lost"
  ""

proc onCall(h: var Hub; routingId: string; f: StreamFrame) =
  if f.session notin h.conds:
    h.emit(routingId, frame("core", "resync"))
    return
  var c = h.conds[f.session]
  c.routingId = routingId
  c.lastSeen = epochTime()
  c.outbox.ack(f.ack)
  let t0 = epochTime()
  var req: ExecutorRequest
  try: req = decodeExecRequest(f.payload)
  except CatchableError: return
  let runId = case req.body.kind
    of ExecutorRequestBodyKind.call: req.body.call.run_id
    of ExecutorRequestBodyKind.finish: req.body.finish.run_id
    else: ""
  var resp: ExecutorResponse
  let refused = if runId.len == 0: "script_error" else: h.runOwnedBy(c, runId)
  if refused.len > 0: resp = failureReply(refused, "this conductor does not hold the run")
  else:
    resp = try:
      case req.body.kind
      of ExecutorRequestBodyKind.call: handleCall(h.c, h.co, req.body.call, h.master)
      else: handleFinish(h.c, req.body.finish, h.master)
    except CatchableError as e:
      stderr.writeLine "core: conductor call: " & e.msg
      failureReply("internal", e.msg)
  h.condEmit(c, "conductor.reply", encodeExecResponse(resp), re = f.id)
  h.conds[f.session] = c
  observe(hReport, epochTime() - t0)

proc handleFrame(h: var Hub; routingId: string; f: StreamFrame) =
  count(mFramesIn, metricKind(f.kind))
  case f.kind
  of "controller.report":
    let t0 = epochTime()
    h.onReport(routingId, f)
    observe(hReport, epochTime() - t0)
  of "conductor.hello": h.onHello(routingId, f)
  of "conductor.call": h.onCall(routingId, f)
  of "ping":
    if f.session in h.peers:
      h.peers[f.session].routingId = routingId
      h.peers[f.session].lastSeen = epochTime()
      h.peers[f.session].outbox.ack(f.ack)
    elif f.session in h.conds:
      h.conds[f.session].routingId = routingId
      h.conds[f.session].lastSeen = epochTime()
      h.conds[f.session].outbox.ack(f.ack)
    else:
      h.emit(routingId, frame("core", "resync"))
  else:
    h.emit(routingId, frame("core", "resync"))

proc pendingProfiles(h: var Hub): seq[string] =
  ## the profiles that have a step waiting to go: one query for all of them, so that an idle shard costs the database nothing per controller
  let r = h.c.query(%*[["SELECT DISTINCT profile_id FROM steps WHERE state = 'PENDING' AND not_before <= ?", getTime().toUnix()]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for row in vals: result.add row[0].getStr

proc leasableProfiles(h: var Hub): seq[string] =
  ## the profiles with a run that nobody holds: one query for all conductors
  let r = h.c.query(%*[["SELECT DISTINCT profile_id FROM runs WHERE state = ? AND (lease_until = 0 OR lease_until < ?)", protoName(rsRunning), getTime().toUnix()]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for row in vals: result.add row[0].getStr

proc housekeeping(h: var Hub) =
  ## once a second: what is not acknowledged goes again, a silent controller is dropped, and the controllers of the organisations that have a
  ## step waiting are looked at (the safety net under the kicks)
  let now = epochTime()
  let waiting = if h.peers.len > 0: h.pendingProfiles() else: @[]
  var gone: seq[string]
  for session, p in h.peers.mpairs:
    if now - p.lastSeen > silentAfterSeconds:
      gone.add session
      continue
    for s in p.outbox.due(now, resendAfterSeconds):
      h.emit(p.routingId, frame("core", s.kind, s.payload, id = s.id))
      count(mResent)
      p.outbox.sentAgain(@[s.id], now)
    if p.profileId in waiting and now - p.lastPush >= safetyPassSeconds:
      h.pushTo(p)
  for session in gone: h.dropPeer(session, "silent")
  # conductors: the same upkeep, and a look at the runs of the organisations that have one ready
  let ready = if h.conds.len > 0: h.leasableProfiles() else: @[]
  var goneConds: seq[string]
  for session, c in h.conds.mpairs:
    if now - c.lastSeen > silentAfterSeconds:
      goneConds.add session
      continue
    for s in c.outbox.due(now, resendAfterSeconds):
      h.emit(c.routingId, frame("core", s.kind, s.payload, id = s.id))
      count(mResent)
      c.outbox.sentAgain(@[s.id], now)
    if c.profileId in ready and now - c.lastPush >= safetyPassSeconds:
      h.pushLeases(c)
  for session in goneConds: h.dropCond(session, "silent")

proc onKick(h: var Hub; profileId: string; at: float; all: bool) =
  ## work was made for an organisation (or a limit changed for everyone): its controller, if this worker has it, is looked at now
  let t0 = epochTime()
  var seen = false
  for session, p in h.peers.mpairs:
    if all or p.profileId == profileId:
      if not seen:
        seen = true
        if at > 0: observe(hKickWait, t0 - at)
      h.pushTo(p)
  for session, c in h.conds.mpairs:
    if all or c.profileId == profileId:
      if not seen and at > 0:
        seen = true
        observe(hKickWait, t0 - at)
      h.pushLeases(c)

const
  msgOut = 0       # to the I/O thread: a = routing id, b = the encoded frame
  msgFrame = 1     # to a worker: a = routing id, b = the time the frame was read (8 bytes) and the encoded frame
  msgKick = 2      # to a worker: a = profile id, b = the time of the kick (8 bytes)
  msgKickAll = 3   # to a worker: every controller is looked at

type
  Pool = object
    inq: ptr UncheckedArray[ShmQueue]
    outq: ptr ShmQueue
    n: int
  WorkerArgs = tuple[co: Core, idx: int, inq, outq: ptr ShmQueue]

func packTime(t: float): string =
  result = newString(sizeof(float))
  copyMem(addr result[0], unsafeAddr t, sizeof(float))

func unpackTime(s: string): float =
  if s.len >= sizeof(float): copyMem(addr result, unsafeAddr s[0], sizeof(float))

proc runWorker(a: WorkerArgs) {.thread.} =
  {.cast(gcsafe).}:
    var h = Hub(co: a.co, c: newRq(a.co.rqliteUrl), defaultProfile: a.co.profileId, peers: initTable[string, Peer](), conds: initTable[string, Cond](),
                outq: a.outq, idx: a.idx)
    let (_, secretKey) = loadKeypair(a.co.certs, "core")
    h.master = secretKey
    var lastTick = epochTime()
    var kind: int
    var x, y: string
    while not stopServers.load:
      if a.inq[].pop(200, kind, x, y):
        let t0 = epochTime()
        try:
          case kind
          of msgFrame:
            observe(hFrameWait, t0 - unpackTime(y))
            let f = decodeFrame(y[sizeof(float) .. ^1])
            if f.isSome: h.handleFrame(x, f.get)
          of msgKick: h.onKick(x, unpackTime(y), false)
          of msgKickAll: h.onKick("", 0.0, true)
          else: discard
        except CatchableError as e: stderr.writeLine "core: stream: " & e.msg
        count(mBusyMicros, n = int((epochTime() - t0) * 1e6))
      let now = epochTime()
      if now - lastTick >= 1.0:
        lastTick = now
        try: h.housekeeping()
        except CatchableError as e: stderr.writeLine "core: stream: " & e.msg
        count(mBusyMicros, n = int((epochTime() - now) * 1e6))
        var unacked = 0
        for _, p in h.peers: unacked += p.outbox.unacked.len
        for _, c in h.conds: unacked += c.outbox.unacked.len
        setGauge(gConductors, h.conds.len.float, h.idx)
        setGauge(gPeers, h.peers.len.float, h.idx)
        setGauge(gUnacked, unacked.float, h.idx)
        setGauge(gQueued, a.inq[].len.float, h.idx)

proc serveStream*(co: Core; port: int; workers = 0) {.thread.} =
  ## the I/O thread of the push channel and its pool; `workers` 0: CINIM_STREAM_WORKERS, else the cores of the Pod
  {.cast(gcsafe).}:
    let n = if workers > 0: workers else: workerCount(getEnv("CINIM_STREAM_WORKERS"))
    let (_, secretKey) = loadKeypair(co.certs, "core")
    let conn = listenStream(port, secretKey)
    let inq = cast[ptr UncheckedArray[ShmQueue]](allocShared0(n * sizeof(ShmQueue)))
    let outq = cast[ptr ShmQueue](allocShared0(sizeof(ShmQueue)))
    for i in 0 ..< n: initShmQueue(inq[i])
    initShmQueue(outq[])
    setGauge(gWorkers, n.float)
    var threads = newSeq[Thread[WorkerArgs]](n)
    for i in 0 ..< n: createThread(threads[i], runWorker, (co, i, addr inq[i], outq))
    template toAll(k: int; a, b: string) =
      for i in 0 ..< n: inq[i].push(k, a, b)
    var kind: int
    var x, y: string
    while not stopServers.load:
      # what the workers have to say first; then kicks, so that work just made goes out before the next report is read
      var sent = 0
      while sent < 256 and outq[].pop(0, kind, x, y):
        if not conn.sendRawTo(x, y): count(mSendFailures)
        inc sent
      for k in takeKicksTimed(): toAll(msgKick, k.id, packTime(k.at))
      if kickedAll(): toAll(msgKickAll, "", "")
      # a short wait: the workers' frames are sent within it. Under load frames follow each other without waiting.
      var got = conn.receiveRaw(if sent > 0: 0 else: 2)
      var taken = 0
      while got.isSome:
        let f = decodeFrame(got.get.bytes)
        if f.isSome:
          let target = int(uint(hash(if f.get.key.len > 0: f.get.key else: f.get.session)) mod uint(n))
          inq[target].push(msgFrame, got.get.routingId, packTime(epochTime()) & got.get.bytes)
        inc taken
        if taken >= 64: break
        got = conn.receiveRaw(0)
    for i in 0 ..< n: joinThread(threads[i])
    conn.close()
    for i in 0 ..< n: destroy(inq[i])
    destroy(outq[])
    deallocShared(inq)
    deallocShared(outq)
