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
import logspool, shimlog, secretmask, artifacts, directclient

import_proto3 "../../build/nimproto/all.proto"

type
  LogCfg* = object
    collectorAddr*, coreAddr*, certs*, spoolDir*: string
    statusAddr*: string       ## D-75: where the state, the heartbeat and the metrics go, on a channel of their own; empty (an older controller): they ride on the log batches
    step*: StepRef
    spoolCap*: int64          ## log_spool_bytes: queued, undelivered compressed bytes at which the shim stops reading
    holdSeconds*: int         ## log_hold_timeout: how long the finished step waits for the log to be delivered
    secrets*: seq[string]
    maskVariants*: bool       ## also mask base64 / URL-encoded / JSON-escaped forms (secretmask.nim)
    maskMinLen*: int
    logMaxBytes*: int64       ## 0 = unlimited (profile setting log_max_bytes)

  SenderArgs = tuple[collectorAddr, certs, spoolDir, runId: string, stepSeq, attempt: uint32, statusApart: bool]
  StatusArgs = tuple[statusAddr, certs, runId: string, stepSeq, attempt: uint32]

  LogPipeline* = object
    cfg: LogCfg
    builder: Builder
    waiting: seq[LogBlock]    ## cut, but the spool is full: held in memory (a few blocks at most, reading stops meanwhile)
    sender: Thread[SenderArgs]
    statusSender: Thread[StatusArgs]
    statusStarted: bool
    lastCut: float
    spoolBroken: bool         ## the spool directory cannot be used (created or written): blocks are dropped and counted

var
  finished, stopSender, stopStatus: Atomic[bool]
  delivered, dropped: Atomic[int]

func podName(runId: string; seq, attempt: uint32): string =
  ## must equal jobcontroller's podName() - it is the VictoriaLogs `job` label and log_streams.index_name
  runId.replace("_", "-") & "-" & $seq & "-" & $attempt

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
      let due = not a.statusApart and (currentState().n != lastSentN or epochTime() - lastHeartbeat >= heartbeatSeconds)
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
        var batch = LogBatch(step: step)
        if not a.statusApart: batch.status = currentStatus()       # D-75: with the status channel the log carries only the log
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

proc statusLoop(a: StatusArgs) {.thread.} =
  ## D-75: the shim's state, heartbeat and metrics, to the core's status port, from a thread of their own: a core that is slow to record them delays these and never the log. Sent when the state
  ## changed and at least every few seconds; a failure is said once in half a minute and tried again, the step never waits for it.
  {.cast(gcsafe).}:
    var conn: ZConnection
    var connected = false
    var backoff = 300
    var lastWarn = 0.0
    var failing = false
    proc warn(msg: string) =
      if epochTime() - lastWarn > 30:
        lastWarn = epochTime()
        stderr.writeLine "cicd-shim: state delivery: " & msg
    let step = StepRef(run_id: a.runId, seq: a.stepSeq, attempt: a.attempt)
    var lastSentN = -1
    var lastHeartbeat = 0.0
    while not stopStatus.load:
      if currentState().n == lastSentN and epochTime() - lastHeartbeat < heartbeatSeconds:
        sleep 50
        continue
      try:
        if not connected:
          conn = connectReq(a.statusAddr, loadPublicKey(a.certs, "core"), loadKeypair(a.certs, "client"), recvTimeoutMs = 6000, sendTimeoutMs = 5000)
          connected = true
        let sentN = currentState().n
        let bytes = Protobuf.encode(StatusReport(step: step, status: currentStatus()))
        var msg = newString(bytes.len)
        if bytes.len > 0: copyMem(addr msg[0], unsafeAddr bytes[0], bytes.len)
        conn.send(msg)
        let (avail, _, body) = waitForReceive(conn.socket)
        if not avail:
          warn "no answer from core within the timeout, retrying"
          failing = true
        else:
          let ack = Protobuf.decode(cast[seq[byte]](body), StatusAck)
          case ack.failure.code
          of "", "rejected":          # recorded, or refused for good: sending the same again would not help
            lastSentN = sentN
            lastHeartbeat = epochTime()
            backoff = 300
            if failing:
              failing = false
              stderr.writeLine "cicd-shim: state delivery recovered"
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
  stopStatus.store(false)
  delivered.store(0)
  dropped.store(0)
  result.cfg = cfg
  result.builder = newBuilder(podName(cfg.step.run_id, cfg.step.seq, cfg.step.attempt), cfg.step.run_id,
                              int64(epochTime() * 1000), cfg.secrets, variants = cfg.maskVariants,
                              minLen = (if cfg.maskMinLen > 0: cfg.maskMinLen else: defaultMinLen), maxBytes = cfg.logMaxBytes)
  result.lastCut = epochTime()
  createThread(result.sender, sendLoop, (cfg.collectorAddr, cfg.certs, cfg.spoolDir, cfg.step.run_id,
                                          cfg.step.seq, cfg.step.attempt, cfg.statusAddr.len > 0))
  if cfg.statusAddr.len > 0:
    createThread(result.statusSender, statusLoop, (cfg.statusAddr, cfg.certs, cfg.step.run_id, cfg.step.seq, cfg.step.attempt))
    result.statusStarted = true

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
  if lp.statusStarted:
    stopStatus.store(true)
    joinThread(lp.statusSender)
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

# ------------------------------------------------------------------ the artifacts (DAT-003): the client of the core's ArtifactIngest, for the shim's own upload and for its drain mode

type
  ArtifactClient* = ref object
    target, certs: string
    conn: ZConnection
    open: bool
    direct: DirectClient
    directBase: string

  ArtifactReply* = object
    ok*, retry*: bool          ## not ok and retry: the core or the store did not answer now, the same request may work later
    viaDirect*: bool           ## the bytes went straight to the storage module (D-61)
    ack*: ArtifactAck
    code*, detail*: string

proc newArtifactClient*(artifactAddr, certs: string): ArtifactClient = ArtifactClient(target: artifactAddr, certs: certs)

proc close*(c: ArtifactClient) =
  if c.open:
    try: c.conn.close() except CatchableError: discard
    c.open = false
  if c.direct != nil:
    c.direct.close()
    c.direct = nil

proc directFor(c: ArtifactClient; base: string): DirectClient =
  if c.direct == nil or c.directBase != base:
    if c.direct != nil: c.direct.close()
    c.direct = newDirectClient(base)
    c.directBase = base
  c.direct

proc call*(c: ArtifactClient; req: ArtifactRequest; timeoutMs = 60000): ArtifactReply =
  ## One request to the core's ArtifactIngest (DAT-003) over the same kind of authenticated channel as the log, answered once. The connection is kept
  ## between requests and made again after an error. The credential in `req.job_token` is the step's own.
  try:
    if not c.open:
      c.conn = connectReq(c.target, loadPublicKey(c.certs, "core"), loadKeypair(c.certs, "client"), recvTimeoutMs = timeoutMs, sendTimeoutMs = 10000)
      c.open = true
    let bytes = Protobuf.encode(req)
    var msg = newString(bytes.len)
    if bytes.len > 0: copyMem(addr msg[0], unsafeAddr bytes[0], bytes.len)
    c.conn.send(msg)
    let (avail, _, body) = waitForReceive(c.conn.socket)
    if not avail:
      c.close()                    # a REQ socket that did not get its answer cannot send again: a new one
      return ArtifactReply(retry: true, code: "no_answer", detail: "core did not answer")
    result.ack = Protobuf.decode(cast[seq[byte]](body), ArtifactAck)
    result.ok = result.ack.accepted
    if not result.ok:
      result.code = result.ack.failure.code
      result.detail = result.ack.failure.detail
      result.retry = result.code == "store_unavailable"
  except CatchableError as e:
    c.close()
    result = ArtifactReply(retry: true, code: "no_answer", detail: e.msg)

proc ask*(c: ArtifactClient; step: StepRef; token: string; req: ArtifactRequest; patience: int): ArtifactReply =
  ## the request, again while the core or the store does not answer, for up to `patience` seconds
  var r = req
  r.header = Header(protocol: 1)
  r.step = step
  r.job_token = token
  let until = epochTime() + patience.float
  while true:
    result = c.call(r, timeoutMs = min(60000, max(1000, patience * 1000)))      # a short patience is not overshot by a long wait for one answer
    if result.ok or not result.retry or epochTime() >= until: return
    sleep 2000

proc abortUpload(c: ArtifactClient; step: StepRef; token, path, uploadId: string; cache: bool) =
  discard c.call(ArtifactRequest(header: Header(protocol: 1), step: step, job_token: token, op: "put_abort", cache: cache, path: path, upload_id: uploadId), 15000)

proc putDirect(c: ArtifactClient; step: StepRef; token, path, absPath: string; size: int64; patience: int; cache: bool; began: ArtifactAck): ArtifactReply =
  ## The parts go to the storage module with the grant, each with its digest; the core is told the digest of every part when the upload ends and completes it only if the module received
  ## the same. A module that does not answer is waited for as long as `patience` says, like a core that is away, and then the upload is dropped (`retry`: the drain delivers it later).
  let d = c.directFor(began.direct_url)
  var parts: seq[ArtifactPart]
  var off = 0'i64
  var n = 0
  while off < size:
    inc n
    let data = readBlock(absPath, off, partSize)
    let sha = blockSha256(data)
    let r = d.putPart(began.direct_path, began.grant, began.upload_id, n, data, sha, patience)
    if not r.ok:
      abortUpload(c, step, token, path, began.upload_id, cache)
      return ArtifactReply(retry: r.retry, code: (if r.retry: "store_unavailable" else: "direct_failed"), detail: r.detail)
    parts.add ArtifactPart(part: uint32(n), etag: r.etag, sha256: sha)
    off += partSize
  result = ask(c, step, token, ArtifactRequest(op: "put_end", cache: cache, path: path, upload_id: began.upload_id, parts: parts), patience)
  if not result.ok: abortUpload(c, step, token, path, began.upload_id, cache)
  result.viaDirect = result.ok

var lastPutDirect* {.threadvar.}: bool       ## whether the last file `putFile` delivered went to the storage module (the step's log says so); false for a file of no bytes

proc putFile*(c: ArtifactClient; step: StepRef; token, path, absPath: string; size: int64; sha256: string; patience: int; cache = false): ArtifactReply =
  ## One file into the store (D-61). The core starts the upload and gives a grant; the bytes go straight to the storage module and only their digests go through the core. There is no other
  ## way: a core that gives no grant (the shard has no port for shims on the module) refuses the upload, and a module that cannot be reached fails it. A file of no bytes is one request.
  ## `path` is the file's name as the artifact (relative to the workspace), `absPath` where it is now.
  lastPutDirect = false
  if size == 0:
    return ask(c, step, token, ArtifactRequest(op: "put_object", cache: cache, path: path, size: 0, sha256: sha256), patience)
  let began = ask(c, step, token, ArtifactRequest(op: "put_begin", cache: cache, path: path, size: uint64(size), sha256: sha256, direct: true), patience)
  if not began.ok: return began
  if began.ack.grant.len == 0 or began.ack.direct_url.len == 0:
    abortUpload(c, step, token, path, began.ack.upload_id, cache)
    return ArtifactReply(code: "direct_required", detail: "the core gave no grant for the storage module")
  result = putDirect(c, step, token, path, absPath, size, patience, cache, began.ack)
  lastPutDirect = result.ok

const directReadSize = 8 * 1024 * 1024   ## a block of a read from the storage module (the module streams it, so the size costs it nothing)

proc fetchTo*(c: ArtifactClient; step: StepRef; token, path: string; size: uint64; dest: string; patience: int; cache = false; directUrl = ""; grant = ""; directPath = ""): string =
  ## A stored file, block by block, into the file `dest`, from the storage module with the grant the core gave (D-61). "" or what went wrong. The caller checks the digest of the whole.
  var part = open(dest, fmWrite)
  defer: part.close()
  if size == 0: return ""                 # a file of no bytes is not in the store
  if grant.len == 0 or directUrl.len == 0: return path & ": the core gave no grant to read it from the storage module"
  let d = c.directFor(directUrl)
  var off = 0'u64
  while off < size:
    let r = d.getRange(directPath, grant, int64(off), int64(min(uint64(directReadSize), size - off)), patience)
    if not r.ok or r.data.len == 0: return path & ": " & (if r.ok: "an empty block" else: r.detail)
    discard part.writeBuffer(unsafeAddr r.data[0], r.data.len)
    off += uint64(r.data.len)
  ""

proc cacheFind*(c: ArtifactClient; step: StepRef; token, key: string; patience: int): tuple[ok, found: bool; key: string; size: uint64; sha256, detail, directUrl, grant, directPath: string] =
  ## DAT-004: the entry for `key` - the key itself or, failing that, what one of the step's restore keys names (the core chooses; it knows the step's declaration)
  let r = ask(c, step, token, ArtifactRequest(op: "cache_find", cache: true, path: key, direct: true), patience)
  if not r.ok: return (false, false, "", 0'u64, "", r.code & ": " & r.detail, "", "", "")
  if r.ack.files.len == 0: return (true, false, "", 0'u64, "", "", "", "", "")
  (true, true, r.ack.files[0].path, r.ack.files[0].size, r.ack.files[0].sha256, "", r.ack.direct_url, r.ack.files[0].grant, r.ack.files[0].direct_path)

proc cacheFetch*(c: ArtifactClient; step: StepRef; token, key: string; size: uint64; dest: string; patience: int; directUrl = ""; grant = ""; directPath = ""): string =
  ## the entry's bytes into the file `dest`, block by block; "" or what went wrong
  c.fetchTo(step, token, key, size, dest, patience, cache = true, directUrl = directUrl, grant = grant, directPath = directPath)

proc drainLogSpool*(collectorAddr, certs, spoolDir: string; step: StepRef; patience: int): tuple[ok: bool, detail: string] =
  ## The drain (docs/artifacts.md): what the log spool still holds is sent to LogIngest, exactly as the sender thread of a step would have, and the blocks the core
  ## acknowledges are removed. No heartbeat and no state of a shim: the step is over. `ok` false: the core did not take it all within `patience` seconds.
  let until = epochTime() + patience.float
  var conn: ZConnection
  var connected = false
  var backoff = 300
  var lastFailure = "the core did not answer"
  defer:
    if connected:
      try: conn.close() except CatchableError: discard
  while true:
    let queued = peek(spoolDir, maxBlocks = 32, maxBytes = 900_000)
    if queued.len == 0: return (true, "")
    if epochTime() >= until: return (false, lastFailure)
    try:
      if not connected:
        conn = connectReq(collectorAddr, loadPublicKey(certs, "core"), loadKeypair(certs, "client"), recvTimeoutMs = 6000, sendTimeoutMs = 5000)
        connected = true
      var batch = LogBatch(step: step)
      for q in queued: batch.chunks.add chunkOf(q)
      let bytes = Protobuf.encode(batch)
      var msg = newString(bytes.len)
      if bytes.len > 0: copyMem(addr msg[0], unsafeAddr bytes[0], bytes.len)
      conn.send(msg)
      let (avail, _, body) = waitForReceive(conn.socket)
      if not avail:
        lastFailure = "no answer from the core within the timeout"
      else:
        let ack = Protobuf.decode(cast[seq[byte]](body), LogAck)
        for q in queued:
          if q.blk.seq <= ack.acked_seq: q.remove()
        if ack.failure.code == "" or ack.failure.code == "rejected":      # rejected for good by the log store: dropping is the only way to move on
          backoff = 300
          continue
        lastFailure = "the core says " & ack.failure.code
    except CatchableError as e:
      lastFailure = e.msg
      if connected:
        try: conn.close() except CatchableError: discard
        connected = false
    sleep backoff
    backoff = min(backoff * 2, 5000)
