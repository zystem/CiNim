## Job-controller (RUN-002, RUN-013, D-29): the outbound-only ControllerAttach client of core. This file is the glue between
## the wire (PollRequest/PollResponse, Protobuf) and the controller's own parts: `logic.nim` decides (verdicts, adoption after a
## restart, retention of finished Pods, orphan sweep, pulling an undelivered spool out of a Pod), `backend.nim` is the seam to
## Kubernetes (the only implementation that talks to the API server is `k8s.nim`, on the official C client, A.6), and
## `ctrlstate.nim` is the controller's sqlite memory. Pod status is polled, not watched. SEC-010 per-job projected tokens are
## deferred: the shim gets the shared CURVE "client" identity through a Secret. The shim binary reaches the Pod through a ConfigMap
## mount (A.6). The step namespace must be dedicated to this controller (docs/settings.md).
import std/[os, strutils, times, sequtils, tables]
import crunchy
import protobuf_serialization
import protobuf_serialization/files/type_generator
import common/[zmqcurve, spoolwire]
import backend, ctrlstate, logic, k8s

import_proto3 "../../build/nimproto/all.proto"

let
  ns = getEnv("CINIM_NAMESPACE", "cinim")
  coreAddr = getEnv("CINIM_CORE_ADDR", "tcp://127.0.0.1:19740")
  certs = getEnv("CINIM_CERTS", getCurrentDir() / "tests" / "certs")
  # Addresses the shim (running inside the step Pod, on the cluster network) uses to reach core's
  # LogIngest/StepReport - NOT necessarily the same host:port job-controller itself uses for
  # ControllerAttach above, since that can be a loopback port-forward during local dev/testing while
  # the Pod needs a cluster-reachable address.
  collectorAddr = getEnv("CINIM_COLLECTOR_ADDR", "")
  # where *this* process reaches core's LogIngest, to hand over the blocks it pulled out of a Pod's spool (the exec fallback,
  # D-29); defaults to the address the shims use
  logIngestAddr = getEnv("CINIM_LOGINGEST_ADDR", getEnv("CINIM_COLLECTOR_ADDR", ""))
  stepReportAddr = getEnv("CINIM_STEPREPORT_ADDR", "")
  shimBinPath = getEnv("CINIM_SHIM_BIN", "build/cicd-shim")
  # D-27: the step's log is spooled on the Pod's ephemeral storage until core has it. Both are per-profile
  # settings in the end (log_spool_bytes, log_hold_timeout); until execution profiles carry them, environment defaults.
  logSpoolBytes = parseInt(getEnv("CINIM_LOG_SPOOL_BYTES", $(10 * 1024 * 1024)))
  logHoldTimeout = parseInt(getEnv("CINIM_LOG_HOLD_TIMEOUT", "600"))
  # the controller's own memory (sqlite): which Pods it made and whether their end was reported - what a restarted
  # controller adopts (D-29). Keep it on a volume that survives a restart of the controller.
  stateDir = getEnv("CINIM_STATE_DIR", getCurrentDir() / "state")
  # how long a finished step Pod is kept after core has its result (to look at it with kubectl), by outcome
  retentionRead = parseInt(getEnv("CINIM_POD_RETENTION_READ", "0"))     # a Pod whose result and log are both read has nothing to show: removed at once
  retentionUnread = parseInt(getEnv("CINIM_POD_RETENTION_UNREAD", $(14 * 86400)))    # a Pod core could not read (log undelivered, end unknown): 14 days, and an alert
  # load_kube_config() (kubernetes-client/c) always dials whatever "current-context" says in the file, with
  # no per-call override - it silently follows the shared ~/.kube/config if this is left empty, which drifts
  # under other unrelated work in this environment. CINIM_KUBECONFIG pins a specific file/context so this
  # service does not depend on the ambient current-context.
  kubeconfig = getEnv("CINIM_KUBECONFIG", "")
  # IAM-003: the one-time token with which this controller enrols at core (a Secret that core made with the namespace); the credential
  # that core gives in exchange is kept next to the state and sent in every poll
  bootstrapFile = getEnv("CINIM_BOOTSTRAP_FILE", "")
const pollIntervalMs = 1000

proc connectCore(): ZConnection =
  let serverPub = loadPublicKey(certs, "core")
  connectReq(coreAddr, serverPub, loadKeypair(certs, "client"), recvTimeoutMs = 10000, sendTimeoutMs = 10000)

proc rpc(s: ZConnection; req: PollRequest): PollResponse =
  let bytes = Protobuf.encode(req)
  var msg = newString(bytes.len)
  if bytes.len > 0: copyMem(addr msg[0], unsafeAddr bytes[0], bytes.len)
  s.send(msg)
  let (avail, _, body) = waitForReceive(s.socket)   # default timeout -2: use the RCVTIMEO set in connectCore
  if not avail: raise newException(IOError, "no reply from core within the receive timeout")
  Protobuf.decode(cast[seq[byte]](body), PollResponse)


proc deliverToCore(runId: string; seq, attempt: int; frames: seq[Frame]): uint64 =
  ## Blocks pulled out of a Pod's spool go to core's LogIngest exactly as the shim would have sent them (same sequence numbers:
  ## core takes each one once, so a shim that is only half dead and sends them too does no harm). Returns the highest sequence
  ## core acknowledged, 0 if none.
  echo "jobcontroller: handing ", frames.len, " spooled block(s) of ", runId, "/", seq, " attempt ", attempt, " to core"
  if logIngestAddr.len == 0:
    stderr.writeLine "jobcontroller: no LogIngest address (CINIM_LOGINGEST_ADDR / CINIM_COLLECTOR_ADDR): the blocks are not delivered"
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
    exit_code: int32(t.exitCode), termination_reason: t.reason, shim_state_json: t.shimJson)

func toProto(p: PodSeen): PodInfo =
  PodInfo(step: StepRef(run_id: p.runId, seq: uint32(p.seq), attempt: uint32(p.attempt)), pod_name: p.podName, phase: p.phase,
          command_started: p.started, node: p.node, shim_state_json: p.shimJson)

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
                       keep_until: p.reportedAt + cfg.retentionUnread.int64)

proc main() =
  setStdIoUnbuffered()           # a supervisor that kills the process must still find its log complete
  let k = connectK8s(ns, kubeconfig)
  let withLogs = collectorAddr.len > 0 and stepReportAddr.len > 0
  k.ensureShimAssets(shimBinPath, certs, withCerts = withLogs)
  let be = backendOf(k)
  var cfg = defaultConfig()
  cfg.collectorAddr = collectorAddr
  cfg.stepReportAddr = stepReportAddr
  cfg.logSpoolBytes = logSpoolBytes
  cfg.logHoldTimeout = logHoldTimeout
  cfg.retentionRead = retentionRead
  cfg.retentionUnread = retentionUnread
  let st = openState(stateDir / "controller.sqlite")
  let adopted = st.active()
  echo "jobcontroller: state in ", stateDir, ", adopted ", adopted.len, " step Pod(s) from the previous run"
  let sessionId = "jc-" & $epochTime()
  var core = connectCore()
  var credential = readTrimmed(credentialPath())
  var handBack: seq[PodTransition]       # steps assigned to us while the launch gate was closed: no Pod exists, they go back
  var ackSeq = 0'u64
  var lastSweep = 0.0
  var seenPhase: Table[string, string]     # pod name -> phase as of the last round (only a Running Pod has a spool worth pulling)
  echo "jobcontroller: connected, session=", sessionId
  while true:
    let now = epochTime()
    let round = pollRound(be, st, cfg, now)
    for p in round.inventory: seenPhase[p.podName] = p.phase
    let req = PollRequest(header: Header(protocol: 1), session_id: sessionId, ack_command_seq: ackSeq, namespace: ns,
      credential: credential, bootstrap_token: (if credential.len == 0: readTrimmed(bootstrapFile) else: ""),
      transitions: round.transitions.map(toProto) & handBack, free_pod_slots: 20,
      inventory: round.inventory.map(toProto), inventory_complete: true,    # every Pod this controller tracks is listed
      kept: keptPods(st, cfg, 100), kept_total: uint32(st.unread().len), kept_complete: true)
    var resp: PollResponse
    try:
      resp = core.rpc(req)
    except CatchableError as e:
      # core unreachable: nothing is lost - the ends stay unreported in our state and go out with the next poll
      stderr.writeLine "jobcontroller: core does not answer (" & e.msg & "), retrying"
      try: core.close() except CatchableError: discard
      sleep 2000
      try: core = connectCore() except CatchableError: discard
      continue
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
    afterPoll(st, round.transitions, int64(now))
    handBack.setLen(0)
    if resp.commands.len > 0:
      stderr.writeLine "jobcontroller: poll got " & $resp.commands.len & " command(s): " & $resp.commands.mapIt($it.body.kind)
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
          discard startPod(be, st, cfg, StartRequest(runId: s.step.run_id, seq: int(s.step.seq), attempt: int(s.step.attempt),
            image: s.image, command: s.command, logMaxBytes: s.log_max_bytes, optsJson: s.opts_json,
            logSpoolBytes: s.log_spool_bytes, logHoldTimeout: int(s.log_hold_timeout_seconds), profile: s.profile), int64(epochTime()))
      of CommandBodyKind.cancel:
        let c = cmd.body.cancel
        let pn = podName(c.step.run_id, int(c.step.seq), int(c.step.attempt))
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
    sleep(if resp.poll_after_ms > 0: int(resp.poll_after_ms) else: pollIntervalMs)

main()
