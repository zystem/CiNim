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
import std/[tables, options, times, os, atomics, sequtils]
import common/[stream, streamstate, rqlite, zmqcurve]
import scheduler, schema, workkick

const
  resendAfterSeconds = 5.0
  pushEverySeconds = 3.0       ## the safety net under the kicks: a pause that ended, a step the watchdog put back
  silentAfterSeconds = 60.0
  maxPeers = 5000

type
  Peer = object
    session, routingId, namespace, credential, profileId: string
    outbox: Outbox
    credit: Credit
    lastSeen, lastPush: float
    lastConfig, lastGate: string      ## what the controller was last told, so that an unchanged answer is not sent again

  Hub = object
    conn: ZConnection
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

proc sendNumbered(h: var Hub; p: var Peer; kind, payload: string; re = 0'u64) =
  let sent = p.outbox.push(kind, payload, epochTime())
  discard h.conn.sendTo(p.routingId, frame("core", kind, payload, id = sent.id, re = re))   # refused: stays unacknowledged, goes again

proc resendAll(h: var Hub; p: var Peer) =
  let now = epochTime()
  var ids: seq[uint64]
  for s in p.outbox.unacked:
    discard h.conn.sendTo(p.routingId, frame("core", s.kind, s.payload, id = s.id))
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
  let resp = handlePoll(h.c, h.defaultProfile, h.master, req)
  if resp.unauthorized or resp.issued_credential.len > 0:
    # not registered: a controller that does not prove itself, or that is just being given its credential, has no credit and gets no pushes;
    # it reports again with the credential
    discard h.conn.sendTo(routingId, frame("core", "controller.work", encodeWork(resp), id = 0, re = f.id))
    h.peers.del f.session
    return
  p.namespace = req.namespace
  if req.credential.len > 0: p.credential = req.credential
  p.profileId = h.profileOfNs(req.namespace)
  p.credit.set(int(req.free_pod_slots))
  if worth(resp, p): h.deliver(p, resp, re = f.id)
  else: discard h.conn.sendTo(routingId, frame("core", "ping", re = f.id))     # heard, nothing to tell
  p.lastPush = epochTime()
  if h.peers.len < maxPeers or known: h.peers[f.session] = p

proc pushTo(h: var Hub; p: var Peer) =
  ## look at what there is for this controller now, without its asking
  if p.credit.available <= 0: return
  let req = PollRequest(header: Header(protocol: 1), session_id: p.session, namespace: p.namespace, credential: p.credential,
                        free_pod_slots: uint32(p.credit.available), inventory_complete: false, kept_complete: false)
  let resp = handlePoll(h.c, h.defaultProfile, h.master, req, push = true)
  p.lastPush = epochTime()
  if resp.unauthorized or resp.issued_credential.len > 0: return          # the controller's own report sorts that out
  if worth(resp, p): h.deliver(p, resp)

proc handleFrame(h: var Hub; routingId: string; f: StreamFrame) =
  case f.kind
  of "controller.report":
    h.onReport(routingId, f)
  of "ping":
    if f.session in h.peers:
      h.peers[f.session].routingId = routingId
      h.peers[f.session].lastSeen = epochTime()
      h.peers[f.session].outbox.ack(f.ack)
    else:
      discard h.conn.sendTo(routingId, frame("core", "resync"))
  else:
    discard h.conn.sendTo(routingId, frame("core", "resync"))

proc housekeeping(h: var Hub; kicked: seq[string]; all: bool) =
  let now = epochTime()
  var gone: seq[string]
  for session, p in h.peers.mpairs:
    if now - p.lastSeen > silentAfterSeconds:
      gone.add session
      continue
    for s in p.outbox.due(now, resendAfterSeconds):
      discard h.conn.sendTo(p.routingId, frame("core", s.kind, s.payload, id = s.id))
      p.outbox.sentAgain(@[s.id], now)
    if all or p.profileId in kicked or now - p.lastPush >= pushEverySeconds:
      h.pushTo(p)
  for session in gone: h.peers.del session

proc serveStream*(co: Core; port: int) {.thread.} =
  ## the thread of the push channel
  {.cast(gcsafe).}:
    var h = Hub(c: newRq(co.rqliteUrl), defaultProfile: co.profileId, peers: initTable[string, Peer]())
    let (_, secretKey) = loadKeypair(co.certs, "core")
    h.master = secretKey
    h.conn = listenStream(port, secretKey)
    var lastTick = 0.0
    while not stopServers.load:
      let got = h.conn.receiveFrom(100)
      if got.isSome:
        try: h.handleFrame(got.get.routingId, got.get.frame)
        except CatchableError as e: stderr.writeLine "core: stream: " & e.msg
      let kicked = takeKicks()
      let all = kickedAll()
      if kicked.len > 0 or all or epochTime() - lastTick >= 1.0:
        lastTick = epochTime()
        try: h.housekeeping(kicked, all)
        except CatchableError as e: stderr.writeLine "core: stream: " & e.msg
    h.conn.close()

