## LogIngest/StepReport client of the shim (RUN-007, RUN-010, D-27). The step's output is cut into compressed
## jsonline blocks (logspool.nim) queued as files on the Pod's ephemeral storage; a sender thread drains them to core
## over ZeroMQ+CURVE, oldest first, and deletes a block only after core acknowledged it (core acknowledges after vlagent
## accepted it, DAT-001). The step's process is never blocked by delivery, only by a *full* spool (then the shim stops
## reading its pipe - the backpressure of RUN-007 - and nothing is lost).
##
## SEC-010 (job token) is deferred: the shared CURVE "client" identity is used, as for job-controller/executor-service.
import std/[os, times, atomics, strutils, json]
import ../common/zmqcurve
import protobuf_serialization
import protobuf_serialization/files/type_generator
import crunchy
import logspool, shimlog, secretmask

import_proto3 "../../build/nimproto/all.proto"

type
  LogCfg* = object
    collectorAddr*, coreAddr*, certs*, spoolDir*: string
    step*: StepRef
    spoolCap*: int64          ## log_spool_bytes: queued, undelivered compressed bytes at which the shim stops reading
    holdSeconds*: int         ## log_hold_timeout: how long the finished step waits for the log to be delivered
    secrets*: seq[string]
    maskVariants*: bool       ## also mask base64 / URL-encoded / JSON-escaped forms (secretmask.nim)
    maskMinLen*: int
    logMaxBytes*: int64       ## 0 = unlimited (profile setting log_max_bytes)

  SenderArgs = tuple[collectorAddr, certs, spoolDir, runId: string, stepSeq, attempt: uint32]

  LogPipeline* = object
    cfg: LogCfg
    builder: Builder
    waiting: seq[LogBlock]    ## cut, but the spool is full: held in memory (a few blocks at most, reading stops meanwhile)
    sender: Thread[SenderArgs]
    lastCut: float
    spoolBroken: bool         ## the spool directory cannot be used (created or written): blocks are dropped and counted

var
  finished, stopSender: Atomic[bool]
  delivered, dropped: Atomic[int]

func podName(runId: string; seq, attempt: uint32): string =
  ## must equal jobcontroller's podName() - it is the VictoriaLogs `job` label and log_streams.index_name
  "ci-" & runId.replace("_", "-") & "-" & $seq & "-" & $attempt

# ------------------------------------------------------------------ sender thread

proc chunkOf(q: Queued): LogChunk =
  LogChunk(seq: q.blk.seq, data: cast[seq[byte]](q.blk.data), crc32c: crc32c(q.blk.data),
           encoding: q.blk.encoding, first_ln: q.blk.firstLn, lines: q.blk.lines)

const heartbeatSeconds = 5.0

proc currentStatus(): ShimStatus =
  ## The shim's state exactly as it is written to the Pod log (same JSON, same event number): the reader reconciles the
  ## ZeroMQ picture with the Pod-log one by `n` (D-29).
  result = ShimStatus(state_json: $toJson(currentState(), int64(epochTime() * 1000)), spool_bytes: uint64(max(0'i64, spoolBytes.load)))
  for (name, value) in currentMetrics(): result.metrics.add ShimMetric(name: name, value: value)

proc sendLoop(a: SenderArgs) {.thread.} =
  {.cast(gcsafe).}:
    var conn: ZConnection
    var connected = false
    var backoff = 300
    var lastWarn = 0.0
    var failing = false
    proc warn(msg: string) =
      if epochTime() - lastWarn > 30:
        lastWarn = epochTime()
        stderr.writeLine "cicd-shim: log delivery: " & msg
    let step = StepRef(run_id: a.runId, seq: a.stepSeq, attempt: a.attempt)
    var lastSentN = -1
    var lastHeartbeat = 0.0
    while not stopSender.load:
      let queued = peek(a.spoolDir)
      # a batch with no chunks is the heartbeat: sent when the shim's state changed and at least every few seconds, so core
      # always knows the shim is alive and what it is doing - even when the build is silent and the spool is empty
      let due = currentState().n != lastSentN or epochTime() - lastHeartbeat >= heartbeatSeconds
      if queued.len == 0 and not due:
        if finished.load: break
        sleep 50
        continue
      if queued.len == 0 and finished.load: break
      try:
        if not connected:
          conn = connectReq(a.collectorAddr, loadPublicKey(a.certs, "core"), loadKeypair(a.certs, "client"),
                            recvTimeoutMs = 6000, sendTimeoutMs = 5000)    # a resend after a timeout is harmless (core takes each block once)
          connected = true
        let sentN = currentState().n
        var batch = LogBatch(step: step, status: currentStatus())
        for q in queued: batch.chunks.add chunkOf(q)
        let bytes = Protobuf.encode(batch)
        var msg = newString(bytes.len)
        if bytes.len > 0: copyMem(addr msg[0], unsafeAddr bytes[0], bytes.len)
        conn.send(msg)
        let (avail, _, body) = waitForReceive(conn.socket)     # REQ_RELAXED+CORRELATE: a resend after a timeout is fine
        if not avail:
          warn "no answer from core within the timeout, retrying"
          failing = true
        else:
          let ack = Protobuf.decode(cast[seq[byte]](body), LogAck)
          # acked_seq: every block up to and including it is durable (or refused for good) - drop those from the spool
          # even when the rest of the batch has to be retried, so nothing is sent twice
          var freed = 0
          for q in queued:
            if q.blk.seq <= ack.acked_seq:
              q.remove()
              inc freed
          discard delivered.fetchAdd(freed)
          case ack.failure.code
          of "":
            lastSentN = sentN
            lastHeartbeat = epochTime()
            backoff = 300
            if failing:
              failing = false
              stderr.writeLine "cicd-shim: log delivery recovered"
          of "rejected":    # vlagent refuses this data for good: dropping it is the only way to move on
            discard dropped.fetchAdd(1)
            stderr.writeLine "cicd-shim: log delivery: vlagent rejected a block, it was dropped"
          else:
            warn "core says " & ack.failure.code & ", retrying"
            failing = true
      except CatchableError as e:
        warn "failed: " & e.msg
        failing = true
        if connected:
          try: conn.close() except CatchableError: discard
          connected = false
      if failing:
        sleep backoff
        backoff = min(backoff * 2, 5000)
    if connected:
      try: conn.close() except CatchableError: discard

# ------------------------------------------------------------------ pipeline API used by shim.nim

proc newLogPipeline*(cfg: LogCfg): LogPipeline =
  try: initSpool(cfg.spoolDir)
  except CatchableError as e:
    # A log problem must not kill the build: carry on without a spool, count what is lost and say so
    result.spoolBroken = true
    stderr.writeLine "cicd-shim: log spool unusable (" & e.msg & "): the step runs, its log is not stored"
  finished.store(false)
  stopSender.store(false)
  delivered.store(0)
  dropped.store(0)
  result.cfg = cfg
  result.builder = newBuilder(podName(cfg.step.run_id, cfg.step.seq, cfg.step.attempt), cfg.step.run_id,
                              int64(epochTime() * 1000), cfg.secrets, variants = cfg.maskVariants,
                              minLen = (if cfg.maskMinLen > 0: cfg.maskMinLen else: defaultMinLen), maxBytes = cfg.logMaxBytes)
  result.lastCut = epochTime()
  createThread(result.sender, sendLoop, (cfg.collectorAddr, cfg.certs, cfg.spoolDir, cfg.step.run_id,
                                          cfg.step.seq, cfg.step.attempt))

proc refreshCounters(lp: LogPipeline) =
  ## the delivery counters ride along with the next Pod-log line and with every heartbeat
  setCounters(int(lp.builder.linesWritten), delivered.load, dropped.load, lp.builder.truncated)

proc pump*(lp: var LogPipeline) =
  ## Move cut blocks into the spool while it has room. A spool that cannot be written (disk full beyond the sizeLimit, a read-only
  ## volume) degrades the log, never the step: the block is dropped and counted, and the first time it is said on stderr.
  while lp.waiting.len > 0 and (lp.spoolBroken or fits(lp.cfg.spoolCap, lp.waiting[0])):
    if not lp.spoolBroken:
      try:
        add(lp.cfg.spoolDir, lp.waiting[0])
      except CatchableError as e:
        stderr.writeLine "cicd-shim: log spool write failed (" & e.msg & "): the step runs, its log is no longer stored"
        lp.spoolBroken = true
    if lp.spoolBroken: discard dropped.fetchAdd(1)
    lp.waiting.delete(0)

proc canAccept*(lp: var LogPipeline): bool =
  ## False while the spool is full: the caller must not read more output (that is the backpressure).
  lp.pump()
  lp.waiting.len == 0

proc write*(lp: var LogPipeline; data: string) =
  lp.waiting.add lp.builder.feed(data, int64(epochTime() * 1000))
  if lp.waiting.len > 0: lp.lastCut = epochTime()
  lp.pump()
  lp.refreshCounters()

proc addSecrets*(lp: var LogPipeline; values: openArray[string]) =
  ## values the build registered while running ($CICD_MASK)
  lp.builder.addSecrets values

proc tick*(lp: var LogPipeline) =
  ## Called at least every ~0.5 s: a quiet step still shows its lines within about a second.
  if epochTime() - lp.lastCut >= 1.0:
    lp.waiting.add lp.builder.flush(int64(epochTime() * 1000))
    lp.lastCut = epochTime()
  lp.pump()
  lp.refreshCounters()

proc finish*(lp: var LogPipeline; limitSeconds = 0): bool =
  ## The step's process has exited: flush the last line and wait up to log_hold_timeout for everything to be delivered.
  ## False = the log did not make it (the shim then exits with logs_undelivered and the step is retried, D-27).
  lp.waiting.add lp.builder.flush(int64(epochTime() * 1000), final = true)
  let hold = if limitSeconds > 0: min(limitSeconds, lp.cfg.holdSeconds) else: lp.cfg.holdSeconds   # a Pod being deleted has little time
  let deadline = epochTime() + hold.float
  var ok = false
  while epochTime() < deadline:
    lp.pump()
    if lp.waiting.len == 0 and isEmpty(lp.cfg.spoolDir):
      ok = true
      break
    sleep 50
  if ok: finished.store(true) else: stopSender.store(true)
  lp.refreshCounters()
  joinThread(lp.sender)
  ok

proc stats*(): tuple[delivered, dropped: int] = (delivered.load, dropped.load)

proc sendStepReport*(coreAddr, certs: string; step: StepRef; exitCode: int; reason: string): bool =
  ## One try at the completion handshake (D-29): the result goes to core and core answers whether the shim may exit.
  ## True = core has the result (or the attempt is superseded and nobody wants it): exit. False = no answer / "retry later":
  ## the caller asks again until its patience runs out, then falls back on the termination message and the Pod's status.
  try:
    let conn = connectReq(coreAddr, loadPublicKey(certs, "core"), loadKeypair(certs, "client"),
                          recvTimeoutMs = 5000, sendTimeoutMs = 5000)
    defer: (try: conn.close() except CatchableError: discard)
    let req = StepReport(step: step, exit_code: int32(exitCode), reason: reason,
                         state_json: $toJson(currentState(), int64(epochTime() * 1000)))
    let bytes = Protobuf.encode(req)
    var msg = newString(bytes.len)
    if bytes.len > 0: copyMem(addr msg[0], unsafeAddr bytes[0], bytes.len)
    conn.send(msg)
    let (avail, _, body) = waitForReceive(conn.socket)
    if not avail: return false
    let ack = Protobuf.decode(cast[seq[byte]](body), StepReportAck)
    ack.may_exit
  except CatchableError as e:
    stderr.writeLine "cicd-shim: StepReport not delivered: " & e.msg
    false

type FetchedSecrets* = object
  ok*: bool
  retry*: bool                 ## no answer (or core is not ready): worth asking again; false = core refused for good
  values*: seq[(string, string)]
  code*, detail*: string

proc fetchStepSecrets*(coreAddr, certs: string; step: StepRef; token: string): FetchedSecrets =
  ## One try at asking core for the values of this step's secrets (6.7), over the same authenticated channel as the report. The credential is
  ## the step's own (bound to the run, step and attempt); core answers with what the step's options asked for.
  try:
    let conn = connectReq(coreAddr, loadPublicKey(certs, "core"), loadKeypair(certs, "client"),
                          recvTimeoutMs = 5000, sendTimeoutMs = 5000)
    defer: (try: conn.close() except CatchableError: discard)
    let req = StepReport(step: step, request: "secrets", job_token: token)
    let bytes = Protobuf.encode(req)
    var msg = newString(bytes.len)
    if bytes.len > 0: copyMem(addr msg[0], unsafeAddr bytes[0], bytes.len)
    conn.send(msg)
    let (avail, _, body) = waitForReceive(conn.socket)
    if not avail: return FetchedSecrets(retry: true, code: "no_answer", detail: "core did not answer")
    let ack = Protobuf.decode(cast[seq[byte]](body), StepReportAck)
    if ack.accepted:
      result.ok = true
      for s in ack.secrets: result.values.add (s.name, s.value)
    else:
      result.code = ack.failure.code
      result.detail = ack.failure.detail
      result.retry = ack.failure.code == "secrets_unavailable"      # core is up but not ready yet; every other refusal is final
  except CatchableError as e:
    result = FetchedSecrets(retry: true, code: "no_answer", detail: e.msg)

type ArtifactAnswer* = object
  ok*, retry*: bool
  answer*: JsonNode
  code*, detail*: string

proc askArtifacts*(coreAddr, certs: string; step: StepRef; token, requestJson: string): ArtifactAnswer =
  ## One try at asking core for URLs to put or get the artifacts of this step (DAT-003), over the same authenticated channel and with the step's own
  ## credential as for its secrets. `requestJson` is {"op": "put" | "done" | "get", ...}; core answers with what the step's options declared, nothing more.
  try:
    let conn = connectReq(coreAddr, loadPublicKey(certs, "core"), loadKeypair(certs, "client"),
                          recvTimeoutMs = 20000, sendTimeoutMs = 5000)
    defer: (try: conn.close() except CatchableError: discard)
    let req = StepReport(step: step, request: "artifacts", job_token: token, request_json: requestJson)
    let bytes = Protobuf.encode(req)
    var msg = newString(bytes.len)
    if bytes.len > 0: copyMem(addr msg[0], unsafeAddr bytes[0], bytes.len)
    conn.send(msg)
    let (avail, _, body) = waitForReceive(conn.socket)
    if not avail: return ArtifactAnswer(retry: true, code: "no_answer", detail: "core did not answer")
    let ack = Protobuf.decode(cast[seq[byte]](body), StepReportAck)
    if ack.accepted:
      result.ok = true
      result.answer = parseJson(ack.answer_json)
    else:
      result.code = ack.failure.code
      result.detail = ack.failure.detail
      result.retry = ack.failure.code in ["store_unavailable"]
  except CatchableError as e:
    result = ArtifactAnswer(retry: true, code: "no_answer", detail: e.msg)
