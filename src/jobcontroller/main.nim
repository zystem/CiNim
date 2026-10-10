## Job-controller (RUN-002, RUN-013, D-29): the outbound-only client of core, on the push channel (docs/conductors.md section 12). This file is the glue between
## the wire (PollRequest/PollResponse, Protobuf) and the controller's own parts: `logic.nim` decides (verdicts, adoption after a
## restart, retention of finished Pods, orphan sweep, pulling an undelivered spool out of a Pod), `backend.nim` is the seam to
## Kubernetes (the only implementation that talks to the API server is `k8s.nim`, on the official C client, A.6), and
## `ctrlstate.nim` is the controller's sqlite memory. Pod status is polled, not watched. SEC-010 per-job projected tokens are
## deferred: the shim gets the shared CURVE "client" identity through a Secret. The shim binary reaches the Pod through a ConfigMap
## mount (A.6). The step namespace must be dedicated to this controller (docs/settings.md).
import std/[os, json, strutils, times, sequtils, tables]
import crunchy
import protobuf_serialization
import protobuf_serialization/files/type_generator
import std/options
import common/[zmqcurve, spoolwire, stream, streamstate]
import backend, ctrlstate, logic, k8s, podverdict, shardsettings, reportcadence, conductors

import_proto3 "../../build/nimproto/all.proto"

let
  ns = getEnv("CINIM_NAMESPACE", "cinim")
  certs = getEnv("CINIM_CERTS", getCurrentDir() / "tests" / "certs")
  shimBinPath = getEnv("CINIM_SHIM_BIN", "build/cicd-shim")
  # the controller's own memory (sqlite): which Pods it made and whether their end was reported - what a restarted
  # controller adopts (D-29). Keep it on a volume that survives a restart of the controller.
  stateDir = getEnv("CINIM_STATE_DIR", getCurrentDir() / "state")
  # load_kube_config() (kubernetes-client/c) always dials whatever "current-context" says in the file, with
  # no per-call override - it silently follows the shared ~/.kube/config if this is left empty, which drifts
  # under other unrelated work in this environment. CINIM_KUBECONFIG pins a specific file/context so this
  # service does not depend on the ambient current-context.
  kubeconfig = getEnv("CINIM_KUBECONFIG", "")
  # IAM-003: the one-time token with which this controller enrols at core (a Secret that core made with the namespace); the credential
  # that core gives in exchange is kept next to the state and sent in every poll
  bootstrapFile = getEnv("CINIM_BOOTSTRAP_FILE", "")
  # the push channel (docs/conductors.md section 12): the controller keeps a connection to the core, which pushes work to it at once
  streamAddr = getEnv("CINIM_CORE_STREAM_ADDR", "")
const pollIntervalMs = 1000

var logIngestAddr = ""      ## where *this* process reaches the core's LogIngest, to hand over the blocks it pulled out of a Pod's spool (the exec fallback, D-29); the core says in every answer to a poll (D-49)

# ---- the push channel: a controller's end
type
  Push = object
    conn: ZConnection
    inbox: Inbox                     ## the numbered frames of the core applied so far
    backlog: seq[PollResponse]       ## work pushed since the last report, applied with the next answer
    session: string                  ## our session id
    key: string                      ## our namespace: the core spreads frames over its workers by it, so every frame of ours carries it
    reportNo: uint64
    lastGate: GateState              ## the gate as the core last said it (a bare "heard you" answer does not repeat it)
    wake: bool                       ## the core asked for our state again (`resync`)
    plan: ConductorPlan              ## the conductors the core last asked for; taken from every frame as it comes, so that an answer that arrived late and was merged into another is not lost

proc connectPush(): ZConnection =
  connectStream(streamAddr, loadPublicKey(certs, "core"), loadKeypair(certs, "client"))

proc decodeWork(payload: string): PollResponse =
  Protobuf.decode(cast[seq[byte]](payload), PollResponse)

proc absorb(p: var Push; f: StreamFrame): Option[PollResponse] =
  ## the work in a frame, if it is to be applied now: the next numbered frame, or one that is not numbered (an answer about identity)
  if f.kind == "resync":
    p.wake = true
    p.inbox = initInbox()      # the core does not know the session (a restarted core): what it sends next is numbered from 1 again
    return none(PollResponse)
  if f.kind != "controller.work": return none(PollResponse)
  if f.id != 0 and p.inbox.accept(f.id) != acApply: return none(PollResponse)
  let w = (try: decodeWork(f.payload) except CatchableError: return none(PollResponse))
  if w.conductors.present: p.plan = w.conductors
  if not (w.unauthorized or w.issued_credential.len > 0): p.lastGate = w.gate
  some(w)

proc exchange(p: var Push; sessionId: string; req: PollRequest): PollResponse =
  ## send our state and wait for the core's answer to it; whatever the core pushed meanwhile is applied with it
  inc p.reportNo
  let bytes = Protobuf.encode(req)
  var payload = newString(bytes.len)
  if bytes.len > 0: copyMem(addr payload[0], unsafeAddr bytes[0], bytes.len)
  var report = frame(sessionId, "controller.report", payload, id = p.reportNo, ack = p.inbox.ackValue, key = req.namespace)
  p.key = req.namespace
  p.wake = false
  if not p.conn.sendFrame(report): raise newException(IOError, "the report could not be queued")
  let deadline = epochTime() + 8.0
  while epochTime() < deadline:
    let got = p.conn.receive(500)
    if got.isNone: continue
    let f = got.get
    let w = p.absorb(f)
    if f.kind == "resync":
      # the core forgot this session: the numbering of its frames starts again (absorb reset ours), so the report goes again with the acknowledgement that is true now
      report = frame(sessionId, "controller.report", payload, id = p.reportNo, ack = p.inbox.ackValue, key = req.namespace)
      discard p.conn.sendFrame(report)
      continue
    if f.re == p.reportNo:
      var r = if w.isSome: w.get else: PollResponse(header: Header(protocol: 1), poll_after_ms: pollIntervalMs, gate: p.lastGate)
      if w.isSome and (w.get.unauthorized or w.get.issued_credential.len > 0): return r      # the answer about identity stands alone
      for b in p.backlog:
        r.commands = b.commands & r.commands
        r.release_storage = b.release_storage & r.release_storage
        if not r.config.present and b.config.present: r.config = b.config
      p.backlog.setLen 0
      return r
    elif w.isSome: p.backlog.add w.get
  raise newException(IOError, "no answer from the core within 8 s")

proc quiet(p: var Push): PollResponse =
  ## a round with no report: only what the core pushed meanwhile, in the shape of an answer
  result = PollResponse(header: Header(protocol: 1), poll_after_ms: pollIntervalMs, gate: p.lastGate)
  for b in p.backlog:
    result.commands = b.commands & result.commands
    result.release_storage = b.release_storage & result.release_storage
    if not result.config.present and b.config.present: result.config = b.config
  p.backlog.setLen 0

proc waitPushed(p: var Push; ms: int): bool =
  ## wait for the next round; true as soon as the core pushed work (or asked for our state), so that the round starts at once
  let deadline = epochTime() + ms.float / 1000.0
  while true:
    let left = int((deadline - epochTime()) * 1000)
    if left <= 0: return false
    let got = p.conn.receive(min(left, 200))
    if got.isSome:
      let w = p.absorb(got.get)
      if w.isSome:
        p.backlog.add w.get
        discard p.conn.sendFrame(frame(p.session, "ping", ack = p.inbox.ackValue, key = p.key))     # acknowledged at once, so that it is not sent again
        return true
      if p.wake: return true

proc deliverToCore(runId: string; seq, attempt: int; frames: seq[Frame]): uint64 =
  ## Blocks pulled out of a Pod's spool go to core's LogIngest exactly as the shim would have sent them (same sequence numbers:
  ## core takes each one once, so a shim that is only half dead and sends them too does no harm). Returns the highest sequence
  ## core acknowledged, 0 if none.
  echo "jobcontroller: handing ", frames.len, " spooled block(s) of ", runId, "/", seq, " attempt ", attempt, " to core"
  if logIngestAddr.len == 0:
    stderr.writeLine "jobcontroller: the core gave no LogIngest address: the blocks are not delivered"
    return 0
  try:
    let conn = connectReq(logIngestAddr, loadPublicKey(certs, "core"), loadKeypair(certs, "client"),
                          recvTimeoutMs = 30000, sendTimeoutMs = 10000)
    defer: (try: conn.close() except CatchableError: discard)
    var i = 0
    while i < frames.len:
      var batch = LogBatch(step: StepRef(run_id: runId, seq: uint32(seq), attempt: uint32(attempt)))
      var bytes = 0
      while i < frames.len and batch.chunks.len < 32 and (batch.chunks.len == 0 or bytes + frames[i].data.len <= 900_000):
        let f = frames[i]
        batch.chunks.add LogChunk(seq: f.seq, data: cast[seq[byte]](f.data), crc32c: crc32c(f.data), encoding: f.encoding,
                                  first_ln: f.firstLn, lines: f.lines)
        bytes += f.data.len
        inc i
      let enc = Protobuf.encode(batch)
      var msg = newString(enc.len)
      if enc.len > 0: copyMem(addr msg[0], unsafeAddr enc[0], enc.len)
      conn.send(msg)
      let (avail, _, body) = waitForReceive(conn.socket)
      if not avail:
        stderr.writeLine "jobcontroller: core did not answer the spooled blocks"
        return
      let ack = Protobuf.decode(cast[seq[byte]](body), LogAck)
      result = max(result, ack.acked_seq)
      if ack.failure.code != "" and ack.failure.code != "rejected":      # core could not take it: what was acked stays acked
        stderr.writeLine "jobcontroller: core answered " & ack.failure.code & " to the spooled blocks (acked up to " & $ack.acked_seq & ")"
        return
  except CatchableError as e:
    stderr.writeLine "jobcontroller: handing a Pod's spooled log to core failed: " & e.msg

func toProto(t: Transition): PodTransition =
  PodTransition(step: StepRef(run_id: t.runId, seq: uint32(t.seq), attempt: uint32(t.attempt)), pod_name: t.podName,
    state: (case t.kind
            of tkSucceeded: STEP_STATE_SUCCEEDED
            of tkFailed: STEP_STATE_FAILED
            of tkLost: STEP_STATE_LOST),
    exit_code: int32(t.exitCode), termination_reason: t.reason, shim_state_json: t.shimJson,
    pod_reason: t.podReason, pod_message: t.podMessage, pod_diag: t.podDiag)

func toProto(p: PodSeen): PodInfo =
  PodInfo(step: StepRef(run_id: p.runId, seq: uint32(p.seq), attempt: uint32(p.attempt)), pod_name: p.podName, phase: p.phase,
          command_started: p.started, node: p.node, shim_state_json: p.shimJson,
          pod_reason: p.podReason, pod_message: p.podMessage)

proc credentialPath(): string = stateDir / "credential"

proc readTrimmed(path: string): string =
  try: (if path.len > 0 and fileExists(path): readFile(path).strip else: "")
  except IOError: ""

proc saveCredential(value: string) =
  ## written before it is used and moved into place, so that a restart in between finds either all of it or nothing
  createDir(stateDir)
  let tmp = credentialPath() & ".tmp"
  writeFile(tmp, value)
  setFilePermissions(tmp, {fpUserRead, fpUserWrite})
  moveFile(tmp, credentialPath())

proc keptPods(st: CtrlState; cfg: Config; limit: int): seq[KeptPod] =
  ## the Pods kept because core could not read them, for the alert (newest first, at most `limit`; kept_total is the whole number)
  for p in st.unread():
    if result.len >= limit: break
    result.add KeptPod(step: StepRef(run_id: p.runId, seq: uint32(p.seq), attempt: uint32(p.attempt)), pod_name: p.name,
                       reason: (if p.endReason.len > 0: p.endReason else: "unknown"), reported_at: p.reportedAt,
                       keep_until: p.reportedAt + cfg.retentionUnread.int64, pod_reason: p.podReason, pod_message: p.podMessage)

proc main() =
  setStdIoUnbuffered()           # a supervisor that kills the process must still find its log complete
  let k = connectK8s(ns, kubeconfig)
  # the shim of a step reaches the core with the controller's transport keys, which it gets as a Secret of the namespace; whether the steps stream their logs is the core's to say
  # (the addresses in ControllerConfig), so the Secret is made whenever the keys are there
  k.ensureShimAssets(shimBinPath, certs, withCerts = fileExists(certs / "curve" / "client.key"))
  let be = backendOf(k)
  var cfg = defaultConfig()
  let st = openState(stateDir / "controller.sqlite")
  let adopted = st.active()
  echo "jobcontroller: state in ", stateDir, ", adopted ", adopted.len, " step Pod(s) from the previous run"
  let sessionId = "jc-" & $epochTime()
  if streamAddr.len == 0:
    stderr.writeLine "jobcontroller: CINIM_CORE_STREAM_ADDR is not set: the controller has no way to reach the core (docs/conductors.md section 12)"
    quit 2
  var push = Push(conn: connectPush(), inbox: initInbox(), session: sessionId)
  var cadence = Cadence()
  var credential = readTrimmed(credentialPath())
  var handBack: seq[PodTransition]       # steps assigned to us while the launch gate was closed: no Pod exists, they go back
  var ackSeq = 0'u64
  var lastSweep = 0.0
  var lastConductors = 0.0
  var lastQuota = 0.0
  var quota: tuple[used, hard: uint64]       # the storage quota of the namespace as last read (every 30 s): the core keeps the volumes of failed runs shorter when it is nearly full
  var conductorTried: Table[int, float]
  var released: seq[string]               # run volumes deleted since the last answered poll: core is told, and stops asking (STO-006)
  var seenPhase: Table[string, string]     # pod name -> phase as of the last round (only a Running Pod has a spool worth pulling)
  echo "jobcontroller: push channel to ", streamAddr, ", session=", sessionId
  while true:
    let now = epochTime()
    if be.readStorageQuota != nil and now - lastQuota >= 30.0:
      lastQuota = now
      quota = be.readStorageQuota()
    let round = pollRound(be, st, cfg, now)
    for p in round.inventory: seenPhase[p.podName] = p.phase
    let req = PollRequest(header: Header(protocol: 1), session_id: sessionId, ack_command_seq: ackSeq, namespace: ns,
      credential: credential, bootstrap_token: (if credential.len == 0: readTrimmed(bootstrapFile) else: ""),
      transitions: round.transitions.map(toProto) & handBack, free_pod_slots: 20,
      inventory: round.inventory.map(toProto), inventory_complete: true,    # every Pod this controller tracks is listed
      kept: keptPods(st, cfg, 100), kept_total: uint32(st.unread().len), kept_complete: true,
      storage_released: released, storage_used_bytes: quota.used, storage_hard_bytes: quota.hard)
    # A report is a snapshot the core takes in with some database work, so it goes out when something changed, when the core asks, and as a
    # heartbeat; the work itself is pushed to us and needs no report to ask for it (reportcadence.nim)
    let sig = podSignature(round.inventory.mapIt((it.podName, it.phase, it.podReason)))
    let due = reportDue(cadence, now, Changes(transitions: round.transitions.len > 0, handedBack: handBack.len > 0,
                                              released: released.len > 0, asked: push.wake), sig)
    var resp: PollResponse
    if due:
      try:
        resp = push.exchange(sessionId, req)
        cadence.sent(now, sig)
      except CatchableError as e:
        # core unreachable: nothing is lost - the ends stay unreported in our state and go out with the next report
        stderr.writeLine "jobcontroller: core does not answer (" & e.msg & "), retrying"
        sleep 2000       # the channel reconnects by itself
        continue
    else:
      resp = push.quiet()
    if resp.issued_credential.len > 0:
      # enrolled: keep the credential, and from the next poll on it is the proof (the poll got nothing else, so nothing is lost)
      saveCredential(resp.issued_credential)
      credential = resp.issued_credential
      echo "jobcontroller: enrolled at core for ", ns
      sleep int(max(resp.poll_after_ms, 100'u32))
      continue
    if resp.unauthorized:
      # core does not accept the credential (rotated, or the state was lost): drop it and enrol again with the bootstrap token
      stderr.writeLine "jobcontroller: core does not accept this controller's identity for " & ns &
        (if credential.len > 0: "; dropping the credential, enrolling again" else: "; no valid bootstrap token (CINIM_BOOTSTRAP_FILE) yet")
      if credential.len > 0:
        credential = ""
        try: removeFile(credentialPath()) except OSError: discard
      sleep int(max(resp.poll_after_ms, 1000'u32))
      continue
    if resp.config.present:
      # the settings of the shard, in every answer: what the next Pod and claim are made by (a step is never started before the first answer)
      let c = resp.config
      let s = shardSettings(c.build_enabled, c.build_seccomp, c.build_caps, c.build_memory_limit, c.build_ephemeral_limit,
                            c.run_storage_enabled, c.run_storage_size, c.run_storage_class, c.run_storage_access)
      applyShardSettings(s)
      cfg.runVolumes = s.volume.enabled
      cfg.collectorAddr = c.collector_addr
      cfg.stepReportAddr = c.step_report_addr
      cfg.artifactAddr = c.artifact_addr
      logIngestAddr = if c.log_ingest_addr.len > 0: c.log_ingest_addr else: c.collector_addr
      cfg.logSpoolBytes = int(c.log_spool_bytes)
      cfg.logHoldTimeout = int(c.log_hold_timeout_seconds)
      cfg.retentionRead = int(c.pod_retention_read_seconds)
      cfg.retentionUnread = int(c.pod_retention_unread_seconds)
    let conductorPlan = push.plan
    if conductorPlan.present and epochTime() - lastConductors >= 5.0:
      # the conductors: the first N are made, an ended one is removed; one that runs is never stopped here (the core drains it)
      lastConductors = epochTime()
      let spec = ConductorSpec(image: conductorPlan.image, runsPerConductor: int(conductorPlan.runs_per_conductor),
                               drainSeconds: int(conductorPlan.drain_seconds), streamAddr: streamAddr, namespace: ns,
                               curveSecret: "cinim-controller-curve")      # the Secret the core made with the namespace (core/orgprovision.nim: curveSecretName)
      try:
        let r = reconcile(be, spec, int(conductorPlan.desired), conductorPlan.credentials.mapIt((it.id, it.credential)), epochTime(), conductorTried)
        if r.created.len > 0 or r.deleted.len > 0:
          echo "jobcontroller: conductors: made ", r.created.join(","), "; removed ", r.deleted.join(",")
      except CatchableError as e:
        stderr.writeLine "jobcontroller: conductors: " & e.msg
    if due:        # what the report carried has been taken in
      afterPoll(st, round.transitions, int64(now))
      released.setLen(0)
      handBack.setLen(0)
    if resp.commands.len > 0:
      stderr.writeLine "jobcontroller: poll got " & $resp.commands.len & " command(s): " & $resp.commands.mapIt($it.body.kind)
    if resp.release_storage.len > 0:
      released = releaseRunVolumes(be, resp.release_storage)       # idempotent: a run that never had a volume counts as released
      if released.len > 0: echo "jobcontroller: released the volume of ", released.len, " finished run(s)"
    for cmd in resp.commands:
      case cmd.body.kind
      of CommandBodyKind.start:
        let s = cmd.body.start
        if not resp.gate.open:
          # RUN-015 (a): no new Pod while the launch gate is closed, even for a step already assigned to us. Nothing
          # exists yet, so starting -> pending is legal (stepGuard): hand the step back and let core queue it.
          handBack.add PodTransition(step: s.step, state: STEP_STATE_PENDING, termination_reason: resp.gate.reason)
          stderr.writeLine "jobcontroller: launch gate closed (" & resp.gate.reason & "), step " & s.step.run_id & "/" &
            $s.step.seq & " returned to the queue"
        else:
          let made = startPod(be, st, cfg, StartRequest(runId: s.step.run_id, seq: int(s.step.seq), attempt: int(s.step.attempt),
            image: s.image, command: s.command, logMaxBytes: s.log_max_bytes, optsJson: s.opts_json,
            logSpoolBytes: s.log_spool_bytes, logHoldTimeout: int(s.log_hold_timeout_seconds), profile: s.profile,
            secretNames: s.secret_names, stepToken: s.step_token,
            env: s.env.mapIt((it.key, it.value))), int64(epochTime()))
          case made.kind
          of ckQuota:
            # the namespace's quota is used up (or the API server asks to slow down): not the step's fault and it passes - back to the queue,
            # with what the API server said, and core lets it wait a little before it is assigned again
            handBack.add PodTransition(step: s.step, state: STEP_STATE_PENDING, termination_reason: "quota_exceeded",
                                       pod_reason: made.reason, pod_message: made.message[0 ..< min(made.message.len, 1000)])
            stderr.writeLine "jobcontroller: no Pod for " & s.step.run_id & "/" & $s.step.seq & ": " & made.message & "; the step waits in the queue"
          of ckRejected:
            # refused for good (admission, Pod Security, an invalid spec): the platform's setup is at fault; the step ends as an infrastructure error
            # with the reason, instead of three attempts at the same refusal
            handBack.add PodTransition(step: s.step, state: STEP_STATE_LOST, exit_code: -1, termination_reason: "pod_rejected",
                                       pod_reason: made.reason, pod_message: made.message[0 ..< min(made.message.len, 1000)])
          else: discard
      of CommandBodyKind.cancel:
        let c = cmd.body.cancel
        let pn = podName(c.step.run_id, int(c.step.seq), int(c.step.attempt))
        # core gave up on this Pod (start_timeout, a lost step) and will not hear its end: what the cluster says about it, and the events that are
        # gone in an hour, are sent before the Pod goes (`diag_only`: stored with the step, decides nothing)
        let seen = be.readPod(pn)
        if seen != nil and seen.kind == JObject and seen{"kind"}.getStr != "Status":
          let ps = podStatusOf(seen)
          let w = pendingWhy(seen)
          handBack.add PodTransition(step: c.step, state: STEP_STATE_LOST, exit_code: -1, termination_reason: "diag_only",
            pod_reason: (if w.reason.len > 0: w.reason else: ps.reason), pod_message: (if w.reason.len > 0: w.message else: ps.message),
            pod_diag: podDiag(seen, (if be.readEvents != nil: be.readEvents(pn) else: @[])))
        let rescued = cancelPod(be, st, c.step.run_id, int(c.step.seq), int(c.step.attempt), int(c.grace_seconds),
                                (if seenPhase.getOrDefault(pn) == "Running": Deliver(deliverToCore) else: nil))
        seenPhase.del pn
        if rescued > 0: echo "jobcontroller: pulled ", rescued, " undelivered log block(s) out of the Pod before removing it"
      else: discard
      if cmd.seq > ackSeq: ackSeq = cmd.seq
    if epochTime() - lastSweep >= 10.0:
      lastSweep = epochTime()
      let sw = sweep(be, st, cfg, int64(epochTime()))
      if sw.expired.len > 0: echo "jobcontroller: removed finished Pod(s) after their retention: ", sw.expired.join(", ")
      if sw.orphans.len > 0: echo "jobcontroller: removed orphan Pod(s) (not in this controller's state): ", sw.orphans.join(", ")
    let pause = if resp.poll_after_ms > 0: int(resp.poll_after_ms) else: pollIntervalMs
    discard push.waitPushed(pause)        # work pushed by the core ends the wait

main()
