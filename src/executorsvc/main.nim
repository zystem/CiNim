## Pipeline executor (RUN-008, PIP-003/004): wraps src/executor/{sandbox,journal,replay} behind the
## ExecutorChannel client (D-24: ZeroMQ+CURVE). One run leased at a
## time (RUN-009 density is not implemented yet).
import std/[os, options, strutils, times, sequtils]
import protobuf_serialization
import protobuf_serialization/files/type_generator
import common/zmqcurve
import executor/[sandbox, journal, replay]

import_proto3 "../../build/nimproto/all.proto"

let
  coreAddr = getEnv("CINIM_CORE_ADDR", "tcp://127.0.0.1:19741")
  certs = getEnv("CINIM_CERTS", getCurrentDir() / "tests" / "certs")
  executorId = getEnv("CINIM_EXECUTOR_ID", "executor-1")

proc connectCore(): ZConnection =
  let serverPub = loadPublicKey(certs, "core")
  connectReq(coreAddr, serverPub, loadKeypair(certs, "client"), recvTimeoutMs = 30000, sendTimeoutMs = 10000)

proc rpc(s: ZConnection; req: ExecutorRequest): ExecutorResponse =
  let bytes = Protobuf.encode(req)
  var msg = newString(bytes.len)
  if bytes.len > 0: copyMem(addr msg[0], unsafeAddr bytes[0], bytes.len)
  s.send(msg)
  let (avail, _, body) = waitForReceive(s.socket)   # default timeout -2: use the RCVTIMEO set in connectCore
  if not avail: raise newException(IOError, "no reply from core within the receive timeout")
  Protobuf.decode(cast[seq[byte]](body), ExecutorResponse)

proc toJournal(entries: seq[JournalEntry]): Journal =
  # The core keeps the hash chain (T-03) and sends each record with its hash: they are taken as they come, and replay checks the chain
  # (`journal_corrupt` if a record was changed on the way or at rest). A record without a hash (a core from before the chain) is chained here.
  for e in entries:
    if e.hash.len > 0:
      result.entries.add Entry(seq: int(e.seq), kind: e.kind, payload: cast[string](e.payload), result: cast[string](e.result),
                               hash: cast[string](e.hash))
    else:
      discard result.append(e.kind, cast[string](e.payload), cast[string](e.result))

proc leaseAny(s: ZConnection): Option[tuple[runId, token, script: string, journal: Journal, params: seq[(string, string)]]] =
  let resp = s.rpc(ExecutorRequest(header: Header(protocol: 1),
    body: ExecutorRequestBody(kind: ExecutorRequestBodyKind.lease,
      lease: LeaseRequest(run_id: "", executor_id: executorId))))
  if resp.body.kind != ExecutorResponseBodyKind.lease: return none(tuple[runId, token, script: string, journal: Journal, params: seq[(string, string)]])
  let g = resp.body.lease
  some (g.run_id, g.lease_token, g.script, toJournal(g.journal), g.params.mapIt((it.key, it.value)))

proc runOnce(s: ZConnection; runId, token, script: string; j: Journal; params: seq[(string, string)]) =
  var sb = newSandbox()
  var jj = j
  var lostLease = ""          # RUN-008: another executor has the run now; this one stops and says nothing more about it
  let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
    let resp = s.rpc(ExecutorRequest(header: Header(protocol: 1),
      body: ExecutorRequestBody(kind: ExecutorRequestBodyKind.call,
        call: HostCall(run_id: runId, lease_token: token, seq: uint64(seq), kind: kind,
                        payload: cast[seq[byte]](payload)))))
    if resp.body.kind == ExecutorResponseBodyKind.failure and resp.body.failure.code == "lease_lost":
      lostLease = resp.body.failure.detail
      return none(string)       # as if suspended: the run goes no further here and nothing is written about it
    if resp.body.kind == ExecutorResponseBodyKind.failure:
      # core refuses this call for good: the run fails with its words, it is not suspended
      raise (ref HostRefusal)(code: resp.body.failure.code, msg: resp.body.failure.detail)
    if resp.body.kind != ExecutorResponseBodyKind.result: return none(string)
    let r = resp.body.result
    if r.suspended: return none(string)
    some(cast[string](r.result))
  let r = replay.execute(sb, jj, script, host, runId = runId, params = params)
  if lostLease.len > 0:
    echo "executor: run ", runId, ": the lease is lost (", lostLease, "); left to its new holder"
    return
  let finalState = case r.status
    of esDone: RUN_STATE_SUCCEEDED
    of esFailed: RUN_STATE_FAILED
    of esSuspended: RUN_STATE_UNSPECIFIED   # not terminal: no finish sent below
  if r.status != esSuspended:
    discard s.rpc(ExecutorRequest(header: Header(protocol: 1),
      body: ExecutorRequestBody(kind: ExecutorRequestBodyKind.finish,
        finish: FinishRun(run_id: runId, state: finalState, message: r.message, code: r.code, lease_token: token))))
    echo "executor: run ", runId, " finished ", r.code
  else:
    echo "executor: run ", runId, " suspended (", r.message, ")"

proc main() =
  setStdIoUnbuffered()
  var core = connectCore()
  echo "executor: connected as ", executorId
  while true:
    var leased: Option[tuple[runId, token, script: string, journal: Journal, params: seq[(string, string)]]]
    try:
      leased = leaseAny(core)
    except CatchableError as e:
      # core stopped or unreachable: wait and dial again - a restart of core must not end the executor (D-29)
      stderr.writeLine "executor: core does not answer (" & e.msg & "), retrying"
      try: core.close() except CatchableError: discard
      sleep 2000
      try: core = connectCore() except CatchableError: discard
      continue
    if leased.isNone:
      sleep 1000
      continue
    let (runId, token, script, j, params) = leased.get
    try:
      runOnce(core, runId, token, script, j, params)
    except CatchableError as e:
      stderr.writeLine "executor: run " & runId & " crashed: " & e.msg
      try: core.close() except CatchableError: discard       # a half-finished request/reply may be pending on this socket
      try: core = connectCore() except CatchableError: discard

main()
