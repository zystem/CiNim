## Recording the shim's state in rqlite (D-29). The state arrives by two paths - ZeroMQ (LogBatch.status, StepReport) and
## the Pod log (read by the job-controller through the Kubernetes API) - as the *same* JSON (common/shimstate.nim), numbered
## by event. This is the one place where either path is applied, so the sources reconcile by construction:
##   - a state replaces what is stored only if its event number is higher (repeats and old news change nothing);
##   - an event that cannot follow the stored one is not applied and is reported (it means a bug or a forged line);
##   - a state about another attempt, or for a step core does not know, changes nothing.
## Alongside the state, steps.state moves starting -> running on the first event past `started`; the final states stay with
## the verdict path (applyTransition / the completion handshake), which compares itself against what is recorded here.
import std/[json, options, times]
import ../common/[rqlite, shimstate, states]

type
  Judgement* = enum
    jApply              ## newer and consistent: store it
    jStale              ## same or lower event number: already known
    jInconsistent       ## newer, but the event cannot follow the stored one
    jWrongAttempt       ## about a different attempt (or run / step) than the one asked about
    jBadState           ## not a state at all

  RecordResult* = object
    judgement*: Judgement
    state*: Option[ShimState]
    movedToRunning*: bool

func judge*(prev: Option[ShimState]; incoming: ShimState; run: string; seq, attempt: int): Judgement =
  ## Pure: what to do with `incoming`, given what is stored (`prev`).
  if incoming.run != run or incoming.seq != seq or incoming.attempt != attempt: return jWrongAttempt
  if prev.isNone: return jApply
  if not newer(prev.get, incoming): return jStale
  if not reachable(prev.get.event, incoming.event): return jInconsistent
  jApply

proc recordShimState*(c: var RqClient; runId: string; seq, attempt: int; stateJson, source: string): RecordResult =
  ## `source`: "zmq" | "pod_log" (kept in steps.shim_source so the API can say where the picture came from).
  var incoming: Option[ShimState]
  try: incoming = fromJson(parseJson(stateJson))
  except CatchableError: discard
  if incoming.isNone: return RecordResult(judgement: jBadState)
  let q = c.query(%*[["SELECT attempt, shim_json FROM steps WHERE run_id = ? AND ordinal = ?", runId, seq]])
  let vals = q["results"][0]{"values"}
  if vals == nil or vals.len == 0 or vals[0][0].getInt != attempt:
    return RecordResult(judgement: jWrongAttempt, state: incoming)       # unknown step, or the step has moved on
  var prev: Option[ShimState]
  let stored = vals[0][1].getStr
  if stored.len > 0:
    try: prev = fromJson(parseJson(stored))
    except CatchableError: discard
  let j = judge(prev, incoming.get, runId, seq, attempt)
  result = RecordResult(judgement: j, state: incoming)
  if j != jApply: return
  let s = incoming.get
  let now = getTime().toUnix()
  # compare-and-swap on the event number: two paths racing cannot move the stored state backwards
  let r = c.execute(%*[
    ["UPDATE steps SET shim_n = ?, shim_phase = ?, shim_json = ?, shim_seen_at = ?, shim_source = ?, version = version + 1 " &
     "WHERE run_id = ? AND ordinal = ? AND attempt = ? AND shim_n < ?",
     s.n, $s.phase, stateJson, now, source, runId, seq, attempt, s.n],
    ["UPDATE steps SET state = ?, started_at = COALESCE(started_at, ?), version = version + 1 " &
     "WHERE run_id = ? AND ordinal = ? AND attempt = ? AND state = ? AND shim_n = ? AND ? <> ?",
     protoName(ssRunning), $now, runId, seq, attempt, protoName(ssStarting), s.n, $s.phase, $spStarting]], transaction = true)
  result.movedToRunning = s.phase != spStarting and r["results"].len > 1 and r["results"][1]{"rows_affected"}.getInt > 0
