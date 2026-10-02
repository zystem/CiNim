## Log collector (RUN-007, DAT-001, D-27): the LogIngest and StepReport ZeroMQ+CURVE REP servers. Lives inside the
## `core` process (spec 7.3: scheduler + log collector + log-circuit are one process).
##
## Since D-27 the collector is a transparent proxy. The shim (not core) turns output into VictoriaLogs jsonline
## records, masks secrets, numbers the lines (`ln`) and compresses them in independent gzip blocks; core checks the CRC32C
## of each block's compressed bytes, forwards the blocks to vlagent's /insert/jsonline with the matching
## `Content-Encoding` (vlagent reads independently compressed blocks glued into one body) and acknowledges the shim only
## after vlagent answered 2xx. It never decompresses or recompresses anything.
##
## Acknowledgement is by sequence number: `acked_seq` = every block up to and including it is durable (or was refused for
## good), so a partly forwarded batch is not re-sent. A refusal that retrying cannot fix (4xx except 408/429) is reported
## as `rejected` so the shim drops that block instead of retrying it forever.
##
## A late batch from an earlier attempt is accepted and stored under that attempt's own label (never mixed into the retry).
##
## StepReport lives here too: it closes the `log_streams` row with the line count this module saw. It is informational -
## it does not touch `steps.state` (job-controller's Pod polling stays the source of truth for step completion).
##
## SEC-010 (job_token) is deferred: accepted but not checked.
import std/[json, tables, strutils, httpclient, locks, atomics, times, options]
import protobuf_serialization
import protobuf_serialization/files/type_generator
import common/[zmqcurve, rqlite, shimstate]
import crunchy
import schema, shimrecord, components, stepmetrics, loggate
import scheduler   ## for stopServers*, the shared shutdown flag every core REP-server thread polls

import_proto3 "../../build/nimproto/all.proto"

const attemptRecheckSeconds = 5.0

type
  StreamKey = tuple[runId: string; seq, attempt: uint32]
  StreamState = object
    forwarded: uint64      ## highest block sequence already given to vlagent: a resend after a lost ack is not forwarded twice
    lines: uint64          ## highest `first_ln + lines` seen: idempotent under retries, becomes log_streams.line_count
    jobId, stepId: string  ## resolved once from (run_id, seq) via `steps`, cached for log_streams writes
    stale: bool            ## the step has moved on to a later attempt: this stream is a ghost (see freshness)
    checkedAt: float       ## when `stale` was last verified against `steps.attempt`

  Collector* = object
    rqliteUrl*: string
    vlagentUrl*: string    ## e.g. http://127.0.0.1:19429/insert/jsonline

  ForwardResult* = enum
    frOk, frRetry, frRejected

var
  streamsLock: Lock
  streams {.guard: streamsLock.}: Table[StreamKey, StreamState]
initLock(streamsLock)

func verifyChunk*(chunk: LogChunk): bool =
  ## true iff the chunk's declared crc32c matches its (compressed) bytes - checked without decompressing.
  crc32c(cast[string](chunk.data)) == chunk.crc32c

func classifyStatus*(code: int): ForwardResult =
  ## vlagent's answer: 2xx done; 408/429/5xx (and no answer at all) are worth retrying; other 4xx will never succeed.
  if code in 200 .. 299: frOk
  elif code == 408 or code == 429 or code >= 500: frRetry
  else: frRejected

proc forward(co: Collector; body, encoding: string): ForwardResult =
  var http = newHttpClient(timeout = 5000)
  defer: http.close()
  var headers = newHttpHeaders({"Content-Type": "application/stream+json"})
  if encoding.len > 0: headers["Content-Encoding"] = encoding
  try:
    classifyStatus(http.request(co.vlagentUrl, httpMethod = HttpPost, body = body, headers = headers).code.int)
  except CatchableError:
    frRetry

proc resolveStep(c: var RqClient; runId: string; seq: uint32): tuple[jobId, stepId: string, attempt: int] =
  let r = c.query(%*[["SELECT id, job_id, attempt FROM steps WHERE run_id = ? AND ordinal = ?", runId, int(seq)]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: (vals[0][1].getStr, vals[0][0].getStr, vals[0][2].getInt) else: ("", "", 0)

func podName(runId: string; seq, attempt: uint32): string =
  ## Must match src/jobcontroller/main.nim's podName() and the shim's - the VictoriaLogs `job` label
  ## (log_streams.index_name), so a reader can reconstruct the query from that row alone.
  "ci-" & runId.replace("_", "-") & "-" & $seq & "-" & $attempt

proc ack(step: StepRef; acked: uint64; code = ""): LogAck =
  LogAck(step: step, acked_seq: acked, failure: Failure(code: code))

proc freshness(c: var RqClient; key: StreamKey; open = false): StreamState =
  ## The stream's state, with `stale` re-verified at most every few seconds. A report for an attempt that is no longer the
  ## step's current one (it was lost and requeued) comes from a ghost - a shim that outlived its Pod's verdict - and must
  ## not touch the new attempt's stream or bookkeeping. Without a `steps` row (unknown step) nothing can be fenced.
  {.cast(gcsafe).}:
    withLock streamsLock:
      if key notin streams and open:
        streams[key] = StreamState()
      if key notin streams: return StreamState(stale: true)
      result = streams[key]
  let now = epochTime()
  if now - result.checkedAt >= attemptRecheckSeconds:
    let (jobId, stepId, current) = resolveStep(c, key.runId, key.seq)
    result.jobId = jobId
    result.stepId = stepId
    result.stale = stepId.len > 0 and current != int(key.attempt)
    result.checkedAt = now
    if open and stepId.len > 0 and not result.stale:
      c.openLogStream(jobId, stepId, int(key.attempt), podName(key.runId, key.seq, key.attempt))
    {.cast(gcsafe).}:
      withLock streamsLock:
        if key in streams:
          streams[key].jobId = jobId
          streams[key].stepId = stepId
          streams[key].stale = result.stale
          streams[key].checkedAt = now

proc handleBatch(c: var RqClient; co: Collector; req: LogBatch): LogAck =
  let key: StreamKey = (req.step.run_id, req.step.seq, req.step.attempt)
  # the shim's state rides on every batch (a batch without chunks is its heartbeat): recorded through the one function
  # that reconciles it with what the Pod log said (D-29)
  if req.status.state_json.len > 0:
    let rec = recordShimState(c, req.step.run_id, int(req.step.seq), int(req.step.attempt), req.status.state_json, "zmq")
    if rec.judgement == jInconsistent:
      stderr.writeLine "core: inconsistent shim state for " & req.step.run_id & "/" & $req.step.seq & " (zmq): " & req.status.state_json
    # the batch is the shim's heartbeat (D-29): a shim that stops sending them shows up as a component that went down
    if rec.state.isSome and rec.judgement in {jApply, jStale}:
      discard registryTouch("shim", req.step.run_id & "/" & $req.step.seq & "/" & $req.step.attempt, epochTime(),
                            @[("phase", $rec.state.get.phase), ("event", $rec.state.get.event)])
      var ms: seq[tuple[name: string, value: float]]
      for m in req.status.metrics: ms.add (m.name, m.value)
      if ms.len > 0: stepmetrics.update(req.step.run_id & "/" & $req.step.seq & "/" & $req.step.attempt, ms)
  if req.chunks.len == 0: return ack(req.step, 0)
  # A shim that outlived its Pod's verdict (a "ghost") is not fenced off here: its attempt number is part of the stream key
  # and of the VictoriaLogs `job` label, so whatever it still delivers lands in *its own* (earlier) attempt's log - the
  # restart is a new attempt with its own label and cannot be polluted. Late lines complete the old attempt's log, which is
  # what a reader of that attempt wants. Only the bookkeeping of a current attempt is fresh-checked (see handleStepReport).
  discard freshness(c, key, open = true)
  for chunk in req.chunks:
    if not verifyChunk(chunk): return ack(req.step, 0, "corrupt_chunk")   # shim re-reads the block from its spool and resends
  # Idempotent: vlagent already has every block up to `forwarded`. When an acknowledgement was lost (the shim's receive timed
  # out while core was still forwarding) the shim sends the same blocks again; they are acknowledged, not stored twice.
  var forwardedBefore = 0'u64
  {.cast(gcsafe).}:
    withLock streamsLock:
      if key in streams: forwardedBefore = streams[key].forwarded
  var chunks: seq[LogChunk]
  var acked = 0'u64
  for ch in req.chunks:
    if ch.seq <= forwardedBefore: acked = ch.seq else: chunks.add ch
  if chunks.len == 0: return ack(req.step, acked)
  var refused = false
  var i = 0
  while i < chunks.len:               # consecutive chunks with the same encoding go out as one request
    var j = i
    var body = ""
    while j < chunks.len and chunks[j].encoding == chunks[i].encoding:
      body.add cast[string](chunks[j].data)
      inc j
    case forward(co, body, chunks[i].encoding)
    of frRetry:
      noteProxyFailure()                                              # vlagent refused or did not answer: close the launch gate now
      return ack(req.step, acked, "logs_unavailable")                  # what was already forwarded stays acknowledged
    of frRejected:
      refused = true
    of frOk:
      discard
    acked = chunks[j - 1].seq
    {.cast(gcsafe).}:
      withLock streamsLock:
        streams[key].forwarded = max(streams[key].forwarded, acked)
        for k in i ..< j:
          streams[key].lines = max(streams[key].lines, chunks[k].first_ln + chunks[k].lines)
    i = j
  ack(req.step, acked, if refused: "rejected" else: "")

proc handleStepReport(c: var RqClient; req: StepReport; profileId: string): StepReportAck =
  ## The completion handshake (D-29): the shim reports its result and waits for this answer before it exits. The result is
  ## the shim's own account - recorded here, through the same path as a Pod's verdict (applyTransition, idempotent and fenced) -
  ## so the Pod's status is only the fallback for a shim that could not reach core. `may_exit` means "recorded (or no longer
  ## wanted): you can go"; without it the shim keeps asking.
  let key: StreamKey = (req.step.run_id, req.step.seq, req.step.attempt)
  let ok = StepReportAck(header: Header(protocol: 1), accepted: true, may_exit: true, disposition: "recorded")
  try:
    # Whether this is still the step's current attempt is asked of the step table, not of the in-memory stream table: a step
    # that printed nothing never opened a stream, and its result must be recorded all the same.
    let (jobId, stepId, current) = resolveStep(c, req.step.run_id, req.step.seq)
    if stepId.len == 0:
      return StepReportAck(header: Header(protocol: 1), accepted: false, may_exit: true, disposition: "superseded",
                           failure: Failure(code: "unknown_step"))
    if current != int(req.step.attempt):      # a ghost: its attempt was lost and the step moved on
      {.cast(gcsafe).}:
        withLock streamsLock: streams.del(key)
      return StepReportAck(header: Header(protocol: 1), accepted: false, may_exit: true, disposition: "superseded",
                           failure: Failure(code: "stale_attempt"))
    if req.state_json.len > 0:
      let rec = recordShimState(c, req.step.run_id, int(req.step.seq), int(req.step.attempt), req.state_json, "zmq")
      if rec.judgement == jInconsistent:
        stderr.writeLine "core: inconsistent shim state for " & req.step.run_id & "/" & $req.step.seq & " (step report): " & req.state_json
      let parsed = try: fromJson(parseJson(req.state_json)) except CatchableError: none(ShimState)
      if parsed.isSome and parsed.get.phase == spDone:
        finalizeFromShim(c, profileId, req.step.run_id, int(req.step.seq), int(req.step.attempt), req.state_json, parsed.get)
    var lines = 0
    {.cast(gcsafe).}:
      withLock streamsLock:
        if key in streams:
          lines = int(streams[key].lines)
          streams.del(key)
    c.closeLogStream(jobId, stepId, int(key.attempt), lines)
    registryRemove("shim", req.step.run_id & "/" & $req.step.seq & "/" & $req.step.attempt)     # finished: not a component to watch
    stepmetrics.finish(req.step.run_id & "/" & $req.step.seq & "/" & $req.step.attempt)
    ok
  except CatchableError as e:
    stderr.writeLine "core: step report for " & req.step.run_id & "/" & $req.step.seq & " not recorded: " & e.msg
    StepReportAck(header: Header(protocol: 1), accepted: false, may_exit: false, disposition: "retry_later",
                  failure: Failure(code: "retry_later"))

proc serveLogIngest*(co: Collector; certs: string; port: int) {.thread.} =
  {.cast(gcsafe).}:
    var c = newRq(co.rqliteUrl)
    let (_, secretKey) = loadKeypair(certs, "core")
    let conn = listenRep(port, secretKey)
    while not stopServers.load:
      let body = conn.receive()
      if body.len == 0: continue
      let resp = handleBatch(c, co, Protobuf.decode(cast[seq[byte]](body), LogBatch))
      let outb = Protobuf.encode(resp)
      var s = newString(outb.len)
      if outb.len > 0: copyMem(addr s[0], unsafeAddr outb[0], outb.len)
      conn.send(s)
    conn.close()

proc serveStepReport*(rqliteUrl, certs: string; port: int; profileId: string) {.thread.} =
  {.cast(gcsafe).}:
    var c = newRq(rqliteUrl)
    let (_, secretKey) = loadKeypair(certs, "core")
    let conn = listenRep(port, secretKey)
    while not stopServers.load:
      let body = conn.receive()
      if body.len == 0: continue
      let resp = handleStepReport(c, Protobuf.decode(cast[seq[byte]](body), StepReport), profileId)
      let outb = Protobuf.encode(resp)
      var s = newString(outb.len)
      if outb.len > 0: copyMem(addr s[0], unsafeAddr outb[0], outb.len)
      conn.send(s)
    conn.close()
