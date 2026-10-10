## Core scheduler (RUN-002, RUN-008, RUN-015, D-24 – D-30): the ControllerAttach and ExecutorChannel ZeroMQ+CURVE REP servers and
## the run logic the REST API calls into. One shard, one execution profile. Runs go CREATED -> RUNNING directly (no compile/queue
## split yet: there is no preflight, PIP-016, and only one executor). The launch gate (RUN-015, A.10) is real: handlePoll
## assigns steps only while loggate.currentGate() is open. Step results arrive from the shim (StepReport, finalizeFromShim) or,
## as the fallback, from the Pod's status through the job-controller (applyTransition); both pass the same fenced, idempotent
## path. The watchdog (watchdogPass) enforces liveness_timeout, unwantedPods tells the controller which Pods to remove, and
## renderCoreMetrics / componentsJson serve /metrics and /api/v1/components.

import std/[json, os, strutils, times, atomics, httpclient, uri, sequtils, tables]
import protobuf_serialization
import protobuf_serialization/files/type_generator
import common/[zmqcurve, rqlite, states, shimstate, memstats, ctrlauth, luaapi, conductorplan]
import logwindow, keptpods, stepsecrets, runparams, objectstore, runstorage, ctrlconfig
import std/options
import schema, logcircuit, loggate, retrypolicy, shimrecord, liveness, components, stepmetrics, orgrules, admission, workkick, runlease, journalchain, journaldb, hubmetrics

import_proto3 "../../build/nimproto/all.proto"

type
  Core* = object
    rqliteUrl*: string
    profileId*: string
    namespace*: string
    certs*: string
    victoriaLogsUrl*: string   ## DAT-001/log gateway stand-in (core/api.nim's log-window read)
    orgPrefix*, orgShard*: string   ## SHD-001: the names of the namespaces of the organisations
    buildOn*: bool             ## the shard has a build profile (A.13): a job may ask for `profile = "build"`
    deployOn*: bool            ## the shard has a deploy profile (D-48): a job may ask for `profile = "deploy"`

var stopServers*: Atomic[bool]
var waitReasonSet: Atomic[bool]   ## some steps currently carry wait_reason = logs_unavailable (so clearing it is a write only on the open edge)

const
  maxFailMessage* = 2000
  maxStepTable* = 64 * 1024        ## the table of step numbers of a run: 200 places at most, a few KB
  maxAdmissionCandidates = 2000   ## the pending steps of one organisation looked at in one poll: 200 steps a run, at most pod_limit active runs

proc loadSettings*(c: var RqClient; profileId: string): ProfileSettings =
  ## the execution profile's settings (set through the API/UI, D-27, D-29); defaults when the row is missing
  result = defaultSettings()
  let r = c.query(%*[["SELECT infra_retries, log_max_bytes, liveness_timeout, log_spool_bytes, log_hold_timeout, pod_limit, job_pod_limit_percent, runs_per_conductor, conductor_min " &
    "FROM execution_profiles WHERE id = ?", profileId]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0:
    result.infraRetries = vals[0][0].getInt(3)
    result.logMaxBytes = vals[0][1].getBiggestInt(defaultLogMaxBytes)
    result.livenessTimeout = vals[0][2].getInt(defaultLivenessTimeout)
    result.logSpoolBytes = vals[0][3].getBiggestInt(defaultLogSpoolBytes)
    result.logHoldTimeout = vals[0][4].getInt(defaultLogHoldTimeout)
    result.podLimit = vals[0][5].getInt(admission.defaultPodLimit)
    result.jobPodLimitPercent = vals[0][6].getInt(admission.defaultJobPodLimitPercent)
    result.runsPerConductor = vals[0][7].getInt(defaultRunsPerConductor)
    result.conductorMin = vals[0][8].getInt(defaultConductorMin)

proc loadPolicy*(c: var RqClient; profileId: string): RetryPolicy =
  result = defaultPolicy()
  result.infraRetries = loadSettings(c, profileId).infraRetries

# ------------------------------------------------------------------ run creation and lookup (REST API)

proc createRun*(co: Core; projectId, script: string; tenantId = "t1"; profileId = ""; params: seq[(string, string)] = @[]; triggerId = ""): string =
  ## `tenantId` is the organisation's id and `profileId` its execution profile (SHD-007); without them the run belongs to the
  ## shard's default tenant and profile (single-tenant setups and tests).
  var c = newRq(co.rqliteUrl)
  result = newId()
  let now = $getTime().toUnix()
  discard c.execute(%*[["INSERT INTO runs (id, tenant_id, project_id, state, version, created_at, updated_at, profile_id, params, trigger_id, api_version) " &
    "VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)", result, tenantId, projectId, protoName(rsRunning), now, now,
    (if profileId.len > 0: profileId else: co.profileId), (if params.len > 0: toJson(params) else: ""),
    (if triggerId.len > 0: %triggerId else: newJNull()), currentApiVersion]])
  # the script itself has nowhere else to live yet (no pipeline_bundles/blob storage, spec 8.2): stash it
  # on the run's own journal as a seq-0 "script" marker the executor service's lease query reads back.
  discard c.execute(%*[["INSERT INTO run_journal (run_id, seq, kind, fingerprint, payload, result, created_at) " &
    "VALUES (?, -1, 'script', '', ?, '', ?)", result, script, now]])
  kickProfile(if profileId.len > 0: profileId else: co.profileId)     # after the script: a conductor of the organisation takes it at once

proc getRun*(co: Core; runId: string): JsonNode =
  var c = newRq(co.rqliteUrl)
  let r = c.query(%*[["SELECT r.id, r.project_id, r.state, r.created_at, r.updated_at, COALESCE(o.slug, ''), r.params, COALESCE(r.trigger_id, ''), r.fail_code, r.fail_message " &
    "FROM runs r LEFT JOIN organizations o ON o.id = r.tenant_id WHERE r.id = ?", runId]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0: return nil
  let row = vals[0]
  result = %*{"id": row[0].getStr, "organization": row[5].getStr, "project_id": row[1].getStr, "state": row[2].getStr,
              "created_at": row[3].getStr, "updated_at": row[4].getStr}
  if row[7].getStr.len > 0: result["trigger_id"] = %row[7].getStr
  if row[8].getStr.len > 0 or row[9].getStr.len > 0: result["failure"] = %*{"code": row[8].getStr, "message": row[9].getStr}
  if row[6].getStr.len > 0:
    result["params"] = (try: parseJson(row[6].getStr) except JsonParsingError: newJObject())
  # RUN-015: a queued step that waits for the log circuit says so (API shows the reason)
  let w = c.query(%*[["SELECT wait_reason FROM steps WHERE run_id = ? AND wait_reason IS NOT NULL LIMIT 1", runId]])
  let wv = w["results"][0]{"values"}
  if wv != nil and wv.len > 0: result["wait_reason"] = %wv[0][0].getStr
  # the steps with their attempt and the reason the last attempt ended the way it did (lost_never_started was retried,
  # outcome_unknown was not, logs_undelivered = result known but the log is incomplete, ...): visible, not buried in a log
  let st = c.query(%*[["SELECT ordinal, attempt, state, exit_code, termination, pod_reason, pod_message, pod_diag FROM steps WHERE run_id = ? ORDER BY ordinal", runId]])
  var steps = newJArray()
  let sv = st["results"][0]{"values"}
  if sv != nil:
    for r in sv:
      steps.add %*{"seq": r[0].getInt, "attempt": r[1].getInt, "state": r[2].getStr,
                   "exit_code": (if r[3].kind == JNull: newJNull() else: %r[3].getInt), "termination": r[4].getStr,
                   "pod_reason": r[5].getStr, "pod_message": r[6].getStr,
                   "pod_diag": (if r[7].getStr.len > 0: (try: parseJson(r[7].getStr) except CatchableError: newJNull()) else: newJNull())}
  result["steps"] = steps

# ------------------------------------------------------------------ retry settings (D-27)

proc getProfileSettings*(co: Core; profileId = ""): JsonNode =
  ## What the UI shows and edits; of the profile given (an organisation's) or the shard's default one.
  var c = newRq(co.rqliteUrl)
  let p = loadSettings(c, if profileId.len > 0: profileId else: co.profileId)
  %*{"infra_retries": p.infraRetries, "log_max_bytes": p.logMaxBytes, "liveness_timeout": p.livenessTimeout,
     "log_spool_bytes": p.logSpoolBytes, "log_hold_timeout": p.logHoldTimeout,
     "pod_limit": p.podLimit, "job_pod_limit_percent": p.jobPodLimitPercent,
     "runs_per_conductor": p.runsPerConductor, "conductor_min": p.conductorMin}

proc setProfileSettings*(co: Core; s: ProfileSettings; profileId = "") =
  var c = newRq(co.rqliteUrl)
  discard c.execute(%*[["UPDATE execution_profiles SET infra_retries = ?, log_max_bytes = ?, liveness_timeout = ?, " &
    "log_spool_bytes = ?, log_hold_timeout = ?, pod_limit = ?, job_pod_limit_percent = ?, runs_per_conductor = ?, conductor_min = ? WHERE id = ?",
    s.infraRetries, s.logMaxBytes, s.livenessTimeout, s.logSpoolBytes, s.logHoldTimeout, s.podLimit, s.jobPodLimitPercent, s.runsPerConductor, s.conductorMin,
    (if profileId.len > 0: profileId else: co.profileId)]])
  kickProfile(if profileId.len > 0: profileId else: co.profileId)    # a raised limit may let waiting steps go

# ------------------------------------------------------------------ log window read (DAT-001)
# A bare stand-in for the log gateway, served by the REST API in core/api.nim: one GET, no from/around/search
# parameters, no SSE/download. It queries VictoriaLogs directly (one node, no vmauth indirection).

proc getStepLog*(co: Core; runId: string; seq: int; fromLine = 0; limit = maxWindow): JsonNode =
  ## The window of a step's log: `limit` lines (at most 500) from line number `fromLine`, in the order of the build's output (logwindow.nim).
  ## nil if no log stream has been opened for this step yet (api.nim 404s on that). An opened stream with no lines readable yet (VictoriaLogs
  ## makes a record readable about 1-2 s after the collector's ack, A.7) is an empty `lines`, not a 404. `next` is the line to ask for next;
  ## `lines_total` is what the shim says the step wrote (-1: nothing yet), `lines_stored` what the store has, and `complete` says that the step has
  ## ended and all of it is stored, so a reader that finds `complete` false after the end of a step asks again.
  var c = newRq(co.rqliteUrl)
  let r = c.query(%*[["SELECT id, job_id, state, shim_json FROM steps WHERE run_id = ? AND ordinal = ?", runId, seq]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0: return nil
  let indexName = schema.streamIndexName(c, vals[0][1].getStr, vals[0][0].getStr)
  if indexName.len == 0: return nil
  let state = vals[0][2].getStr
  let total = linesReported(vals[0][3].getStr)
  let first = max(0, fromLine)
  let n = min(max(1, limit), maxWindow)
  var lines: seq[string]
  var stored = 0
  try:
    var http = newHttpClient(timeout = 5000)
    defer: http.close()
    let stream = "job:" & indexName & " AND run:" & runId
    let q = stream & " AND ln:>=" & $first & " | sort by (ln) | limit " & $n
    lines = contiguousFrom(parseLogRecords(http.getContent(co.victoriaLogsUrl & "/select/logsql/query?query=" & encodeUrl(q) & "&limit=" & $n)), first)
    let cnt = http.getContent(co.victoriaLogsUrl & "/select/logsql/query?query=" & encodeUrl(stream & " | stats count() n"))
    stored = parseJson(cnt.splitLines[0]){"n"}.getStr.parseInt
  except CatchableError:
    discard   # VictoriaLogs unreachable/empty result: an empty window, not a platform-level error
  %*{"run_id": runId, "step_seq": seq, "from": first, "lines": lines, "next": first + lines.len, "step_state": state,
     "lines_total": total, "lines_stored": stored, "complete": logComplete(state, total, stored)}

# ------------------------------------------------------------------ components and metrics (D-29)

proc componentsJson*(): JsonNode =
  ## GET /api/v1/components: every component core knows of, with its state and how long ago it was last heard from
  let now = epochTime()
  result = newJArray()
  for c in registrySnapshot():
    var info = newJObject()
    for (k, v) in c.info: info[k] = %v
    result.add %*{"kind": c.kind, "id": c.id, "state": (case c.state
                        of csUp: "up"
                        of csDown: "down"
                        else: "unknown"),
                  "last_seen_seconds_ago": max(0.0, now - c.lastSeen), "since": c.since, "info": info}

proc renderCoreMetrics*(co: Core): string =
  ## GET /metrics, Prometheus text (docs/metrics.md): only core is scraped - Pods are short-lived (the shim reports to core),
  ## so what an operator alerts on is here: component liveness, steps by state, the launch gate, core's own memory.
  let now = epochTime()
  result = registryMetrics(now) & memstats.renderMetrics("core") & stepmetrics.render() & hubmetrics.renderHubMetrics()
  let g = currentGate()
  result.add "# HELP cinim_unread_pods Finished step Pods kept because their result or log could not be read (an alert in the API).\n# TYPE cinim_unread_pods gauge\n"
  for (ns, n) in keptCounts(): result.add "cinim_unread_pods{namespace=\"" & ns & "\"} " & $n & "\n"
  result.add "# HELP cinim_launch_gate_open 1 when new steps may start (RUN-015).\n# TYPE cinim_launch_gate_open gauge\n" &
             "cinim_launch_gate_open " & (if g.isOpen: "1" else: "0") & "\n"
  try:
    var c = newRq(co.rqliteUrl)
    let r = c.query(%*[["SELECT state, count(*) FROM steps GROUP BY state"], ["SELECT state, count(*) FROM runs GROUP BY state"]])
    for (idx, name) in [(0, "cinim_steps"), (1, "cinim_runs")]:
      result.add "# TYPE " & name & " gauge\n"
      let vals = r["results"][idx]{"values"}
      if vals != nil:
        for row in vals: result.add name & "{state=\"" & row[0].getStr.toLowerAscii & "\"} " & $row[1].getInt & "\n"
  except CatchableError:
    discard                       # rqlite unreachable: the component metric already says so

# ------------------------------------------------------------------ ControllerAttach (job-controller <-> core)

const
  terminatedGrace = 30         ## seconds the end of a step whose shim was stopped from outside waits for the job controller's reading of the Pod
  quotaPause = 15          ## seconds a step that met a used-up quota waits before it is assigned again

proc applyTransition*(c: var RqClient; policy: RetryPolicy; t: PodTransition) =
  let attempt = int(t.step.attempt)
  let now = getTime().toUnix()
  # Fencing (the zombie/ghost problem of Jenkins and TeamCity agents): a report about an attempt that is no longer
  # the step's current one - the step was already requeued, or finished - changes nothing.
  let cur = c.query(%*[["SELECT attempt, state FROM steps WHERE run_id = ? AND ordinal = ?", t.step.run_id, int(t.step.seq)]])
  let cv = cur["results"][0]{"values"}
  if cv == nil or cv.len == 0 or cv[0][0].getInt != attempt: return
  if cv[0][1].getStr in [protoName(ssSucceeded), protoName(ssFailed), protoName(ssLost)]:
    # Already final, usually because the shim reported the result before the Pod's end was seen: the result stands, but what Kubernetes
    # said about the Pod arrives only now (the events go in an hour) and is kept for the investigation, once.
    if t.pod_diag.len > 0:
      discard c.execute(%*[["UPDATE steps SET pod_reason = coalesce(nullif(?, ''), pod_reason), pod_message = coalesce(nullif(?, ''), pod_message), " &
        "pod_diag = ? WHERE run_id = ? AND ordinal = ? AND attempt = ? AND pod_diag = ''",
        t.pod_reason, t.pod_message, t.pod_diag, t.step.run_id, int(t.step.seq), attempt]])
    return
  if t.termination_reason == "diag_only": return      # only the diagnosis of a Pod that core had already given up on; nothing to decide
  # What the Pod's log said about the shim, applied by the same function as the ZeroMQ path - the pictures reconcile by event number
  if t.shim_state_json.len > 0:
    let rec = recordShimState(c, t.step.run_id, int(t.step.seq), attempt, t.shim_state_json, "pod_log")
    if rec.judgement == jInconsistent:
      stderr.writeLine "core: inconsistent shim state for " & t.step.run_id & "/" & $t.step.seq & " (pod log): " & t.shim_state_json
  if t.state == STEP_STATE_PENDING:
    # starting -> pending (stepGuard: no Pod exists yet): the controller saw the gate closed before creating the Pod
    # (RUN-015 a), so the step goes back to the queue and waits with the reason, ready to be claimed again.
    # The reason it goes back is the controller's: the gate (the default) or a used-up quota, with what the API server said. A quota is not
    # asked again at once: the step waits a few seconds before it can be assigned.
    let waitReason = if t.termination_reason.len > 0: t.termination_reason else: reasonUnavailable
    let pause = if waitReason == "quota_exceeded": quotaPause else: 0
    discard c.execute(%*[["UPDATE steps SET state = ?, controller_id = NULL, wait_reason = ?, not_before = max(not_before, ?), " &
      "pod_reason = coalesce(nullif(?, ''), pod_reason), pod_message = coalesce(nullif(?, ''), pod_message), version = version + 1 " &
      "WHERE run_id = ? AND ordinal = ? AND attempt = ? AND state = ?",
      protoName(ssPending), waitReason, now + pause, t.pod_reason, t.pod_message, t.step.run_id, int(t.step.seq), attempt, protoName(ssStarting)]])
    return
  # "never started" is the controller's reading of the Pod; the shim having talked to core is proof of the opposite (it ran,
  # so its command may have): any recorded shim state, or an opened log stream, wins - the single cross-check, no further
  # heuristics (D-29).
  var reason = t.termination_reason
  if reason == "lost_never_started":
    let ev = c.query(%*[["SELECT (SELECT shim_n FROM steps WHERE run_id = ? AND ordinal = ? AND attempt = ?), " &
      "(SELECT count(*) FROM log_streams WHERE attempt = ? AND step_id = (SELECT id FROM steps WHERE run_id = ? AND ordinal = ?))",
      t.step.run_id, int(t.step.seq), attempt, attempt, t.step.run_id, int(t.step.seq)]])
    let row = ev["results"][0]{"values"}[0]
    if row[0].getInt > 0 or row[1].getInt > 0: reason = "outcome_unknown"
  # What Kubernetes said. A report without it (the shim's or the watchdog's) keeps what the inventory of the waiting Pod had already stored
  # (ImagePullBackOff, Unschedulable...): so the stored value is read once and replaced only by a non-empty one.
  let prev = c.query(%*[["SELECT pod_reason, pod_message, pod_diag FROM steps WHERE run_id = ? AND ordinal = ? AND attempt = ?", t.step.run_id, int(t.step.seq), attempt]])
  let pv = prev["results"][0]{"values"}
  let podReason = if t.pod_reason.len > 0 or pv == nil or pv.len == 0: t.pod_reason else: pv[0][0].getStr
  let podMessage = if t.pod_message.len > 0 or pv == nil or pv.len == 0: t.pod_message else: pv[0][1].getStr
  let podDiag = if t.pod_diag.len > 0 or pv == nil or pv.len == 0: t.pod_diag else: pv[0][2].getStr
  case decide(reason, attempt, policy)
  of dRequeue:
    # next attempt: same step row, attempt + 1, after a pause; the lost attempt's log stream is marked, not deleted
    discard c.execute(%*[
      ["UPDATE steps SET state = ?, attempt = attempt + 1, controller_id = NULL, wait_reason = NULL, exit_code = NULL, " &
       "shim_n = 0, shim_phase = '', shim_json = '', shim_seen_at = 0, shim_source = '', " &
       "termination = ?, pod_reason = ?, pod_message = ?, pod_diag = ?, not_before = ?, version = version + 1 WHERE run_id = ? AND ordinal = ? AND attempt = ?",
       protoName(ssPending), reason, podReason, podMessage, podDiag, now + backoffSeconds(attempt, policy), t.step.run_id, int(t.step.seq), attempt],
      ["UPDATE log_streams SET state = 'abandoned', closed_at = ? WHERE attempt = ? AND state = 'open' AND " &
       "step_id = (SELECT id FROM steps WHERE run_id = ? AND ordinal = ?)", $now, attempt, t.step.run_id, int(t.step.seq)]],
      transaction = true)
    echo "core: step ", t.step.run_id, "/", t.step.seq, " attempt ", attempt, " lost (", reason, "), requeued as attempt ", attempt + 1
  of dFailInfra:
    # out of retries, or the command started and its fate is unknown (not restarted, D-28): the platform, not the
    # step, failed - the reason stays on the step
    discard c.execute(%*[
      ["UPDATE steps SET state = ?, termination = ?, pod_reason = ?, pod_message = ?, pod_diag = ?, finished_at = ?, version = version + 1 " &
       "WHERE run_id = ? AND ordinal = ? AND attempt = ?",
       protoName(ssLost), reason, podReason, podMessage, podDiag, $now, t.step.run_id, int(t.step.seq), attempt],
      ["UPDATE runs SET state = ?, updated_at = ?, version = version + 1 WHERE id = ? AND state = ?",
       protoName(rsInfrastructureError), $now, t.step.run_id, protoName(rsRunning)]], transaction = true)
    echo "core: step ", t.step.run_id, "/", t.step.seq, " attempt ", attempt, " lost (", reason, "), not retried: run -> infrastructure_error"
  of dFinish:
    # Cross-check against the shim's own account (D-29): the Pod's verdict and the shim's last state must tell the same
    # story. A difference is reported, not resolved here - the Pod's exit code stays the result (it is what ran).
    let sj = c.query(%*[["SELECT shim_json FROM steps WHERE run_id = ? AND ordinal = ? AND attempt = ?", t.step.run_id, int(t.step.seq), attempt]])
    let sv = sj["results"][0]{"values"}
    if sv != nil and sv.len > 0 and sv[0][0].getStr.len > 0:
      let shim = try: fromJson(parseJson(sv[0][0].getStr)) except CatchableError: none(ShimState)
      if shim.isSome and shim.get.phase == spDone:
        let podSays = if t.exit_code == 0: ssSucceeded else: ssFailed
        let shimSays = stepStateOf(shim.get)
        if shimSays != podSays and not (shimSays == ssTimedOut and podSays == ssFailed):
          stderr.writeLine "core: step " & t.step.run_id & "/" & $t.step.seq & " attempt " & $attempt & ": the Pod says " &
            protoName(podSays) & ", the shim's last state says " & protoName(shimSays) & " (" & shim.get.reason & ")"
    # the step's own result: write it into run_journal, close out the step
    let res = $t.exit_code & "\n"
    # payload must equal exactly what the executor's host call sent (bootstrap.lua Job:sh:
    # self.__key .. "\t" .. self.__image .. "\t" .. profile .. "\t" .. opts .. "\t" .. cmd, handleCall's req.payload) or replay sees it
    # as a different call than the one in the journal and fails script_nondeterminism - steps.command
    # alone is missing the job key and image, so join jobs for the key.
    let pl = c.query(%*[["SELECT j.key || char(9) || s.image || char(9) || s.profile || char(9) || s.opts || char(9) || s.command, COALESCE(s.journal_seq, s.ordinal) " &
      "FROM steps s JOIN jobs j ON j.id = s.job_id WHERE s.run_id = ? AND s.ordinal = ?", t.step.run_id, int(t.step.seq)]])
    let plv = pl["results"][0]{"values"}
    if plv != nil and plv.len > 0:
      try:
        # the step is closed out and its result goes into the journal, chained, in one transaction; if the record is already there
        # (a retried poll) nothing is done again
        discard c.appendRow(t.step.run_id, plv[0][1].getInt, "job_sh", plv[0][0].getStr, res, alongside = %*[
          ["UPDATE steps SET state = ?, exit_code = ?, termination = ?, pod_reason = ?, pod_message = ?, pod_diag = ?, finished_at = ? WHERE run_id = ? AND ordinal = ? AND attempt = ?",
           protoName(if t.exit_code == 0: ssSucceeded else: ssFailed), t.exit_code, reason, podReason, podMessage, podDiag, $now,
           t.step.run_id, int(t.step.seq), attempt]])
      except RqError as e:
        stderr.writeLine "core: could not record the result of step " & t.step.run_id & "/" & $t.step.seq & ": " & e.msg

proc probeAndAge*(c: var RqClient; coreStartedAt: int64) =
  ## once per watchdog pass: rqlite and the log circuit are probed by core itself, and silence ages every component
  let now = epochTime()
  var dbUp = true
  try: discard c.query(%*[["SELECT 1"]])
  except CatchableError: dbUp = false
  discard registrySet("rqlite", "state-store", (if dbUp: csUp else: csDown), now)
  let g = currentGate()
  discard registrySet("logcircuit", "launch-gate", (if g.isOpen: csUp else: csDown), now, @[("reason", g.reason)])
  for ch in registryAge(now):
    echo "core: component ", ch.kind, "/", ch.id, " is now ", $ch.to

proc finalizeFromShim*(c: var RqClient; profileId, runId: string; seq, attempt: int; stateJson: string; s: ShimState) =
  ## The shim's final state (StepReport) as the same kind of event the Pod's status would have produced; applyTransition decides
  ## what it means. A shim cut off from outside ("terminated") has an unknown outcome; every other reason carries the
  ## command's own result.
  let exitCode =
    case s.reason
    of "ok", "failed", "logs_undelivered", "artifacts_undelivered": s.cmdExit.get(s.exitCode.get(1))     # the command's own result
    else: max(1, s.exitCode.get(1))             # timeout, env_rejected, secret_in_output, shim_error: the shim's verdict, never 0
  if s.reason == "terminated":
    # The shim was stopped from outside (SIGTERM). Who stopped it decides whose fault it is, and the shim cannot know: a node drain or a
    # preemption is the cluster's doing (outcome unknown, not restarted), an eviction for the Pod's own ephemeral-storage limit is the
    # step's. The Pod says which, and the job controller reports it within a second or two; so the step waits for that report, and the
    # watchdog ends it as `outcome_unknown` if none comes in `terminatedGrace` seconds (the controller is down).
    return
  let reason = s.reason
  let state = if exitCode == 0: STEP_STATE_SUCCEEDED else: STEP_STATE_FAILED
  applyTransition(c, loadPolicy(c, profileOfRun(c, runId, profileId)), PodTransition(
    step: StepRef(run_id: runId, seq: uint32(seq), attempt: uint32(attempt)), state: state, exit_code: int32(exitCode),
    termination_reason: reason, shim_state_json: stateJson))
  kickProfile(profileOfRun(c, runId, profileId))      # a step ended: its run may be ready for a conductor again

proc watchdogPass*(c: var RqClient; profileId: string; coreStartedAt: int64) =
  ## Core's own look at every step in flight (D-29): a Pod that never came up, or a shim that went quiet, for longer than
  ## the profile's liveness_timeout. The step is finalized here (a start_timeout is not repeated, a silent shim's step has an
  ## unknown outcome and is not restarted); the Pod itself is removed by the CancelStep that the next controller poll
  ## brings back, because the step is no longer wanted.
  let now = getTime().toUnix()
  # the profile of a step is that of its run's organisation (SHD-007): its liveness_timeout and retry policy
  let r = c.query(%*[["SELECT s.run_id, s.ordinal, s.attempt, s.state, s.claimed_at, s.shim_n, s.shim_seen_at, COALESCE(r.profile_id, ''), s.shim_phase, s.shim_json " &
    "FROM steps s LEFT JOIN runs r ON r.id = s.run_id WHERE s.state IN (?, ?)", protoName(ssStarting), protoName(ssRunning)]])
  let rows = r["results"][0]{"values"}
  if rows == nil: return
  for row in rows:
    let rowProfile = if row[7].getStr.len > 0: row[7].getStr else: profileId
    let settings = loadSettings(c, rowProfile)
    let policy = loadPolicy(c, rowProfile)
    let st = if row[3].getStr == protoName(ssRunning): ssRunning else: ssStarting
    # The shim's heartbeats (a log batch every 5 s) are not written to rqlite (RUN-002): the database holds the time of its last *event*, which for a command
    # that runs a long time is the start. The heartbeats are in the component registry, in memory, and count as signs of life too (RUN-016, RUN-017).
    let heartbeat = int64(registryLastSeen("shim", row[0].getStr & "/" & $row[1].getInt & "/" & $row[2].getInt))
    let verdict = liveness.judge(StepLiveness(state: st, claimedAt: row[4].getBiggestInt, shimN: row[5].getInt,
                                              shimSeenAt: max(row[6].getBiggestInt, heartbeat)), now, coreStartedAt, settings.livenessTimeout)
    var stoppedFromOutside = false
    if verdict == lOk and row[8].getStr == "done" and now - row[6].getBiggestInt >= terminatedGrace:
      let sh = try: fromJson(parseJson(row[9].getStr)) except CatchableError: none(ShimState)
      stoppedFromOutside = sh.isSome and sh.get.reason == "terminated"
    if verdict == lOk and not stoppedFromOutside: continue
    let reason = if verdict == lStartTimeout: "start_timeout" else: "outcome_unknown"
    echo "core: step ", row[0].getStr, "/", row[1].getInt, " attempt ", row[2].getInt, ": ", reason,
         " (no sign of life for over ", settings.livenessTimeout, " s)"
    applyTransition(c, policy, PodTransition(step: StepRef(run_id: row[0].getStr, seq: uint32(row[1].getInt), attempt: uint32(row[2].getInt)),
                                             state: STEP_STATE_LOST, exit_code: -1, termination_reason: reason))

proc unwantedPods(c: var RqClient; inventory: seq[PodInfo]): seq[StepRef] =
  ## Pods the controller has that no step wants any more: the step moved on to a later attempt, or finished (a short while
  ## ago - a Pod that is just exiting by itself is left alone), or core has no such step at all (an orphan).
  if inventory.len == 0: return
  var runs: seq[string]
  for p in inventory:
    if p.step.run_id notin runs: runs.add p.step.run_id
  var marks = ""
  for i in 0 ..< runs.len: marks.add(if i == 0: "?" else: ",?")
  var stmt = newJArray()
  stmt.add %("SELECT run_id, ordinal, attempt, state, COALESCE(CAST(finished_at AS INTEGER), 0) FROM steps WHERE run_id IN (" & marks & ")")
  for r in runs: stmt.add %r
  let q = c.query(%*[stmt])
  let rows = q["results"][0]{"values"}
  let now = getTime().toUnix()
  for p in inventory:
    var found = false
    var wanted = true
    if rows != nil:
      for row in rows:
        if row[0].getStr != p.step.run_id or row[1].getInt != int(p.step.seq): continue
        found = true
        let attempt = row[2].getInt
        let state = row[3].getStr
        if attempt > int(p.step.attempt): wanted = false
        elif attempt == int(p.step.attempt) and state == protoName(ssLost): wanted = false     # core gave up on it: no grace needed
        elif attempt == int(p.step.attempt) and state notin [protoName(ssStarting), protoName(ssRunning), protoName(ssPending)] and
             now - row[4].getBiggestInt > 30: wanted = false     # finished by itself: its shim is exiting, leave it a little time
    if not found or not wanted: result.add p.step

var releaseAskedAt {.threadvar.}: Table[string, float]     ## when the runs whose volume may go were last looked for, per profile (STO-006)
var refusedLoggedAt {.threadvar.}: Table[string, float]    ## a controller that keeps being refused is said once a minute, not every poll

proc controllerConfigOf*(s: ShardSettings): ControllerConfig =
  ## the settings of the shard as the wire carries them to a controller
  ControllerConfig(present: true, build_enabled: s.buildEnabled, build_seccomp: s.buildSeccomp, build_caps: s.buildCaps,
                   build_memory_limit: s.buildMemoryLimit, build_ephemeral_limit: s.buildEphemeralLimit,
                   run_storage_enabled: s.runStorageEnabled, run_storage_size: s.runStorageSize,
                   run_storage_class: s.runStorageClass, run_storage_access: s.runStorageAccess,
                   collector_addr: s.collectorAddr, step_report_addr: s.stepReportAddr, artifact_addr: s.artifactAddr, log_ingest_addr: s.logIngestAddr,
                   log_spool_bytes: uint64(s.logSpoolBytes), log_hold_timeout_seconds: uint32(s.logHoldTimeout),
                   pod_retention_read_seconds: uint32(max(s.podRetentionRead, 0)), pod_retention_unread_seconds: uint32(max(s.podRetentionUnread, 0)))

var conductorImage*: string = getEnv("CINIM_CONDUCTOR_IMAGE")      ## the conductor image of the shard; empty: the controllers are told nothing about conductors
const conductorDrainSeconds* = 30

proc runCounts*(c: var RqClient; profileId: string): tuple[active, waiting: int] =
  ## the organisation's runs that are not over: those that were led before (they hold a place of pod_limit) and those that have not been led yet
  let r = c.query(%*[["SELECT COUNT(CASE WHEN lease_attempt > 0 THEN 1 END), COUNT(*) FROM runs WHERE profile_id = ? AND state = ?", profileId, protoName(rsRunning)]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0:
    result.active = vals[0][0].getInt
    result.waiting = max(vals[0][1].getInt - result.active, 0)

proc wantedConductors*(c: var RqClient; profileId: string; s: ProfileSettings): int =
  let n = c.runCounts(profileId)
  desiredConductors(n.active, n.waiting, s.runsPerConductor, s.conductorMin, s.podLimit)

var planCacheSeconds* = 3.0       ## how long the plan of an organisation's conductors is kept: it counts runs, and the number changes slowly
var planCache {.threadvar.}: Table[string, tuple[at: float, plan: ConductorPlan]]

proc conductorPlanOf*(c: var RqClient; profileId, master, namespace: string; s: ProfileSettings): ConductorPlan =
  ## what the controller of the organisation is to keep (docs/conductors.md section 5); nothing without an image, or for the shard's default profile
  if conductorImage.len == 0 or namespace.len == 0: return
  let cached = planCache.getOrDefault(profileId)
  if planCacheSeconds > 0 and cached.at > 0 and epochTime() - cached.at < planCacheSeconds and cached.plan.image == conductorImage and
     cached.plan.runs_per_conductor == uint32(s.runsPerConductor):
    return cached.plan
  result = ConductorPlan(present: true, desired: uint32(c.wantedConductors(profileId, s)), image: conductorImage,
                         runs_per_conductor: uint32(s.runsPerConductor), drain_seconds: uint32(conductorDrainSeconds))
  for n in 1 .. int(result.desired):
    result.credentials.add ConductorCredential(id: conductorId(n), credential: conductorCredential(master, namespace, conductorId(n)))
  planCache[profileId] = (epochTime(), result)

proc handlePoll*(c: var RqClient; defaultProfile, master: string; req: PollRequest; push = false; claim = true): PollResponse =
  ## `push`: the push channel (core/streamhub.nim) asks on behalf of a controller that has said nothing new - what there is to hand out now; it is
  ## not the controller's heartbeat and tells nothing about its Pods. `claim = false`: take in the controller's state and answer, but hand out no
  ## steps - on the push channel steps go out when there is work for the organisation (a kick) or a free place, not at every report.
  # Who is asking (IAM-003, T-46): a namespace that has a controller identity is served only against its credential, or against the
  # bootstrap token once, in which case the credential is handed out and nothing else happens in this poll. A namespace without
  # an identity (a single-tenant setup) is trusted as before.
  let decision = decide(c.credentialRow(req.namespace), master, req.namespace, req.credential, req.bootstrap_token, getTime().toUnix())
  case decision.verdict
  of vRefused:
    let now = epochTime()
    if now - refusedLoggedAt.getOrDefault(req.namespace, 0.0) > 60:
      refusedLoggedAt[req.namespace] = now
      stderr.writeLine "core: a controller for the namespace " & req.namespace & " (session " & req.session_id & ") did not prove its identity: refused"
    return PollResponse(header: Header(protocol: 1), unauthorized: true, poll_after_ms: 5000)
  of vIssue:
    let row = c.credentialRow(req.namespace)
    echo "core: the controller of ", req.namespace, " enrolled with its bootstrap token"
    return PollResponse(header: Header(protocol: 1), issued_credential: controllerCredential(master, req.namespace, row.generation), poll_after_ms: 200)
  of vOk:
    if decision.confirm: c.confirmCredential(req.namespace)
  of vLegacy: discard
  # every poll is the controller's heartbeat (D-29)
  if not push: discard registryTouch("controller", req.session_id, epochTime(), @[("pods", $req.inventory.len)])
  # the Pods this controller keeps because it could not read them (the result unknown, the log undelivered): an alert for each, until it removes them
  if req.kept_complete and req.namespace.len > 0 and not push:
    var items: seq[KeptItem]
    for k in req.kept:
      items.add KeptItem(pod: k.pod_name, runId: k.step.run_id, reason: k.reason, seq: int(k.step.seq), attempt: int(k.step.attempt),
                         reportedAt: k.reported_at, keepUntil: k.keep_until, podReason: k.pod_reason, podMessage: k.pod_message)
    recordKept(req.namespace, getTime().toUnix(), int(req.kept_total), items)
  # The controller serves one organisation and says so by its namespace (SHD-007): it gets the steps of the profile of that namespace
  # and of no other. A controller that names none (single-tenant setups) gets the shard's default profile. Until the controllers have
  # identities of their own (SEC-010) the namespace is taken on the controller's word.
  let profileId = if req.namespace.len == 0: defaultProfile else: profileOfNamespace(c, req.namespace)
  # 1. Apply reported Pod transitions (results, losses to retry, steps handed back because the gate closed).
  for t in req.transitions: applyTransition(c, loadPolicy(c, profileOfRun(c, t.step.run_id, defaultProfile)), t)
  if req.transitions.len > 0 and profileId.len > 0: kickProfile(profileId)      # steps ended: their runs may be ready for a conductor again
  # 2. Launch gate (RUN-015): while it is closed nothing is assigned; queued steps stay queued and say why.
  #    Run creation, cancellation and everything else is untouched, and running steps are never interrupted.
  let gate = currentGate()
  # The Pod log's picture of each shim (read by the controller every few seconds) - recorded, never trusted over a later event
  for pod in req.inventory:
    if pod.pod_reason.len > 0 or pod.pod_message.len > 0:
      # a Pod that has not started and says why (ImagePullBackOff, Unschedulable...): kept on the step, so that a start_timeout has its cause
      discard c.execute(%*[["UPDATE steps SET pod_reason = ?, pod_message = ? WHERE run_id = ? AND ordinal = ? AND attempt = ? AND state IN (?, ?) " &
        "AND (pod_reason != ? OR pod_message != ?)", pod.pod_reason, pod.pod_message, pod.step.run_id, int(pod.step.seq), int(pod.step.attempt),
        protoName(ssStarting), protoName(ssRunning), pod.pod_reason, pod.pod_message]])
    if pod.shim_state_json.len > 0:
      discard recordShimState(c, pod.step.run_id, int(pod.step.seq), int(pod.step.attempt), pod.shim_state_json, "pod_log")
  let settings = loadSettings(c, if profileId.len > 0: profileId else: defaultProfile)
  var commands: seq[Command]
  var seq = 1'u64
  # Pods nobody wants any more are removed (superseded attempts, finished steps, orphans of an earlier core or controller)
  for step in unwantedPods(c, req.inventory.toSeq):
    commands.add Command(seq: seq, body: CommandBody(kind: CommandBodyKind.cancel, cancel: CancelStep(step: step, grace_seconds: 5)))
    inc seq
  if gate.isOpen:
    if waitReasonSet.exchange(false):   # the gate (re)opened: queued steps no longer wait for the log circuit
      discard c.execute(%*[["UPDATE steps SET wait_reason = NULL WHERE wait_reason = ?", reasonUnavailable]])
  else:
    # idempotent and cheap, and it also labels steps that were queued after the gate had already closed
    discard c.execute(%*[["UPDATE steps SET wait_reason = ? WHERE state = ? AND wait_reason IS NULL",
      reasonUnavailable, protoName(ssPending)]])
    waitReasonSet.store(true)
  # 3. Hand out pending steps whose pause (not_before, after a lost attempt) is over, within the limits of the organisation (RUN-004):
  #    at most free_pod_slots now, at most pod_limit in flight, at most job_pod_limit_percent of that for one run; the run with the
  #    fewest steps in flight first (core/admission.nim). No profile for the namespace: no steps.
  var toClaim: seq[string]
  if claim and gate.isOpen and profileId.len > 0 and req.free_pod_slots > 0:
    let now = getTime().toUnix()
    var pending: seq[Candidate]
    let pr = c.query(%*[["SELECT id, run_id, priority, CAST(queued_at AS INTEGER) FROM steps WHERE state = ? AND profile_id = ? AND not_before <= ? " &
      "ORDER BY priority DESC, queued_at LIMIT ?", protoName(ssPending), profileId, now, maxAdmissionCandidates]])
    let pv = pr["results"][0]{"values"}
    if pv != nil:
      for row in pv:
        pending.add Candidate(id: row[0].getStr, runId: row[1].getStr, priority: row[2].getInt, queuedAt: row[3].getBiggestInt)
    if pending.len > 0:
      var inFlight = initTable[string, int]()
      var total = 0
      let fr = c.query(%*[["SELECT run_id, COUNT(*) FROM steps WHERE profile_id = ? AND state IN (?, ?) GROUP BY run_id",
        profileId, protoName(ssStarting), protoName(ssRunning)]])
      let fv = fr["results"][0]{"values"}
      if fv != nil:
        for row in fv:
          inFlight[row[0].getStr] = row[1].getInt
          total += row[1].getInt
      toClaim = admit(pending, inFlight, total, settings.podLimit, jobPodLimit(settings.podLimit, settings.jobPodLimitPercent), int(req.free_pod_slots))
  for stepId in toClaim:
    let r = c.execute(%*[["UPDATE steps SET state = ?, controller_id = ?, claimed_at = ?, version = version + 1, " &
      "pod_reason = CASE WHEN wait_reason = 'quota_exceeded' THEN '' ELSE pod_reason END, " &
      "pod_message = CASE WHEN wait_reason = 'quota_exceeded' THEN '' ELSE pod_message END, " &
      "wait_reason = CASE WHEN wait_reason = 'quota_exceeded' THEN NULL ELSE wait_reason END " &
      "WHERE id = ? AND state = ? RETURNING run_id, ordinal, image, command, attempt, opts, profile",
      protoName(ssStarting), req.session_id, getTime().toUnix(), stepId, protoName(ssPending)]])
    let vals = r["results"][0]{"values"}
    if vals == nil or vals.len == 0: continue    # another poll took it first
    let row = vals[0]
    commands.add Command(seq: seq, body: CommandBody(kind: CommandBodyKind.start, start: StartStep(
      step: StepRef(run_id: row[0].getStr, seq: uint32(row[1].getInt), attempt: uint32(row[4].getInt)),
      image: row[2].getStr, command: @["sh", "-c", row[3].getStr], opts_json: row[5].getStr, log_max_bytes: uint64(settings.logMaxBytes),
      log_spool_bytes: uint64(settings.logSpoolBytes), log_hold_timeout_seconds: uint32(settings.logHoldTimeout),
      profile: row[6].getStr, secret_names: secretNamesOf(row[5].getStr), env: runParams(c, row[0].getStr).mapIt(EnvEntry(key: it[0], value: it[1])),
      step_token: (if secretNamesOf(row[5].getStr).len > 0 or hasArtifacts(row[5].getStr): stepToken(master, row[0].getStr, row[1].getInt, row[4].getInt) else: ""))))
    inc seq
  # STO-006: the controller deleted these volumes; and the runs whose volume may go now (it is told again until it says it is done)
  markReleased(c, req.storage_released)
  var release: seq[string]
  if epochTime() - releaseAskedAt.getOrDefault(profileId, 0.0) >= 10.0 or req.storage_released.len > 0:   # a few seconds' delay in deleting a volume costs nothing
    releaseAskedAt[profileId] = epochTime()
    release = releasableRuns(c, profileId, getTime().toUnix(), retentionFromEnv())
  PollResponse(header: Header(protocol: 1), commands: commands, release_storage: release, config: controllerConfigOf(shardSettingsFromEnv()),
               gate: GateState(open: gate.isOpen, reason: gate.reason), poll_after_ms: 1000,
               conductors: (if push or profileId.len == 0: ConductorPlan() else: conductorPlanOf(c, profileId, master, req.namespace, settings)))

# The payloads of the push channel (core/streamhub.nim). Encoding is done here, in the module that generates the message types: protobuf_serialization
# finds the support for the enum fields of a message only where the types were generated.
proc wireString(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)
proc encodeReport*(req: PollRequest): string = wireString(Protobuf.encode(req))
proc decodeReport*(payload: string): PollRequest = Protobuf.decode(cast[seq[byte]](payload), PollRequest)
proc encodeWork*(resp: PollResponse): string = wireString(Protobuf.encode(resp))
proc decodeWork*(payload: string): PollResponse = Protobuf.decode(cast[seq[byte]](payload), PollResponse)
proc encodeConfig*(c: ControllerConfig): string = wireString(Protobuf.encode(c))
proc encodePlan*(p: ConductorPlan): string = wireString(Protobuf.encode(p))
# the conductor's kinds (docs/conductors.md section 12): a hello, a lease pushed, a host call or a finish, and the answer to it
proc encodeHello*(h: ConductorHello): string = wireString(Protobuf.encode(h))
proc decodeHello*(payload: string): ConductorHello = Protobuf.decode(cast[seq[byte]](payload), ConductorHello)
proc encodeLeaseGranted*(g: LeaseGranted): string = wireString(Protobuf.encode(g))
proc decodeLeaseGranted*(payload: string): LeaseGranted = Protobuf.decode(cast[seq[byte]](payload), LeaseGranted)
proc encodeExecRequest*(r: ExecutorRequest): string = wireString(Protobuf.encode(r))
proc decodeExecRequest*(payload: string): ExecutorRequest = Protobuf.decode(cast[seq[byte]](payload), ExecutorRequest)
proc encodeExecResponse*(r: ExecutorResponse): string = wireString(Protobuf.encode(r))
proc decodeExecResponse*(payload: string): ExecutorResponse = Protobuf.decode(cast[seq[byte]](payload), ExecutorResponse)

# ------------------------------------------------------------------ ExecutorChannel (executor <-> core)

proc loadScript(c: var RqClient; runId: string): string =
  let r = c.query(%*[["SELECT payload FROM run_journal WHERE run_id = ? AND seq = -1", runId]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: vals[0][0].getStr else: ""

proc journalEntries(rows: seq[Row]): seq[JournalEntry] =
  for r in rows:
    result.add JournalEntry(seq: uint64(r.seq), kind: r.kind, payload: cast[seq[byte]](r.payload), result: cast[seq[byte]](r.result),
                            hash: cast[seq[byte]](r.hash))

proc leaseStateOf(c: var RqClient; runId: string): LeaseState =
  let r = c.query(%*[["SELECT lease_attempt, lease_until FROM runs WHERE id = ?", runId]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: LeaseState(attempt: vals[0][0].getInt, until: vals[0][1].getBiggestInt) else: LeaseState()

proc takeRunLease*(c: var RqClient; master, runId, owner: string; versions: seq[int] = @[]): string =
  ## Lease a RUNNING run that is free (never leased, given back, or run out): a new attempt, and its token. "" if the run is not free, not RUNNING,
  ## or another executor took it in the meantime (the update is made only against the attempt that was read).
  let now = getTime().toUnix()
  let st = leaseStateOf(c, runId)
  if not canTake(st, now): return ""
  let r = c.execute(%*[["UPDATE runs SET lease_attempt = lease_attempt + 1, lease_until = ?, lease_owner = ? " &
    "WHERE id = ? AND lease_attempt = ? AND (lease_until = 0 OR lease_until < ?) AND state = ? " &
    (if versions.len > 0: "AND api_version IN (" & sqlVersionList(versions) & ") " else: "") & "RETURNING lease_attempt",
    now + leaseTtlSeconds, owner, runId, st.attempt, now, protoName(rsRunning)]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0: "" else: leaseToken(master, runId, vals[0][0].getInt)

proc leaseCandidates*(c: var RqClient; only = ""; versions: seq[int] = @[]; profileId = ""; started = -1; limit = 5): seq[string] =
  ## RUNNING runs that nobody holds and that have no step still PENDING/STARTING/RUNNING: presumed suspended, ready to (re)lease
  ## (`only`: just that run, if it is one - for the tests; `profileId`: the runs of one organisation's profile; `started` 1: only runs that were led
  ## before, 0: only runs never led)
  let r = c.query(%*[["SELECT id FROM runs WHERE state = ? AND (lease_until = 0 OR lease_until < ?) AND (? = '' OR id = ?) AND (? = '' OR profile_id = ?) " &
    (if started == 1: "AND lease_attempt > 0 " elif started == 0: "AND lease_attempt = 0 " else: "") &
    (if versions.len > 0: "AND api_version IN (" & sqlVersionList(versions) & ") " else: "") & "AND id NOT IN " &
    "(SELECT run_id FROM steps WHERE state IN (?, ?, ?)) ORDER BY created_at LIMIT ?",
    protoName(rsRunning), getTime().toUnix(), only, only, profileId, profileId, protoName(ssPending), protoName(ssStarting), protoName(ssRunning), limit]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for row in vals: result.add row[0].getStr

proc activeRuns*(c: var RqClient; profileId: string): int =
  ## the runs of an organisation that have been led and are not over: they hold a place of `pod_limit` (docs/conductors.md section 4), whether a
  ## conductor has them this moment or they wait for a step
  let r = c.query(%*[["SELECT COUNT(*) FROM runs WHERE profile_id = ? AND state = ? AND lease_attempt > 0", profileId, protoName(rsRunning)]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: vals[0][0].getInt else: 0

proc grantLease*(c: var RqClient; master, candidate, owner: string; versions: seq[int]): Option[LeaseGranted] =
  ## Lease one run to `owner` and build what it needs to lead it: the token, the script, the checked journal, the parameters, the version of the API.
  ## None if the run is not free any more (another holder was faster), or if its journal is corrupt (the run then ends, T-03).
  let token = takeRunLease(c, master, candidate, owner, versions)
  if token.len == 0: return none(LeaseGranted)
  # the journal is checked before the run goes to an executor (T-03): the core wrote it, the core vouches for it
  let v = c.verifyJournal(candidate)
  if v.check.verdict == cvBroken:
    stderr.writeLine "core: the journal of run " & candidate & " is corrupt: " & v.check.why & "; the run ends"
    discard c.execute(%*[["UPDATE runs SET state = ?, updated_at = ?, version = version + 1, fail_code = 'journal_corrupt', fail_message = ?, lease_until = 0 " &
      "WHERE id = ? AND state = ?", protoName(rsInfrastructureError), $getTime().toUnix(), v.check.why, candidate, protoName(rsRunning)]])
    return none(LeaseGranted)
  let vr = c.query(%*[["SELECT api_version, step_table FROM runs WHERE id = ?", candidate]])["results"][0]{"values"}
  some LeaseGranted(lease_token: token, ttl_seconds: uint32(leaseTtlSeconds), run_id: candidate,
                    api_version: uint32(if vr != nil and vr.len > 0: vr[0][0].getInt(1) else: 1),
                    step_table: (if vr != nil and vr.len > 0: vr[0][1].getStr else: ""),
                    script: loadScript(c, candidate), journal: journalEntries(v.rows),
                    params: runParams(c, candidate).mapIt(ParamsEntry(key: it[0], value: it[1])))

proc leaseForConductor*(c: var RqClient; profileId, master, owner: string; versions: seq[int]; places: int): seq[LeaseGranted] =
  ## What the core pushes to a conductor of an organisation that has `places` free: first the runs that were led before and whose wait is over (they
  ## already hold a place of the organisation), then new runs while the organisation has fewer active runs than its `pod_limit` (RUN-004). Only the
  ## organisation's own runs, only of the host API versions the conductor can run.
  if places <= 0: return
  # one look at what is free: the runs that were led before come first. When nothing is free (the usual case) that is the only query.
  let r = c.query(%*[["SELECT id, lease_attempt FROM runs WHERE state = ? AND (lease_until = 0 OR lease_until < ?) AND profile_id = ? " &
    (if versions.len > 0: "AND api_version IN (" & sqlVersionList(versions) & ") " else: "") & "AND id NOT IN " &
    "(SELECT run_id FROM steps WHERE state IN (?, ?, ?)) ORDER BY (lease_attempt > 0) DESC, created_at LIMIT ?",
    protoName(rsRunning), getTime().toUnix(), profileId, protoName(ssPending), protoName(ssStarting), protoName(ssRunning), places]])
  var led, fresh: seq[string]
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for row in vals:
      if row[1].getInt > 0: led.add row[0].getStr else: fresh.add row[0].getStr
  for candidate in led:
    let g = grantLease(c, master, candidate, owner, versions)
    if g.isSome: result.add g.get
  if fresh.len == 0: return
  let room = loadSettings(c, profileId).podLimit - activeRuns(c, profileId)
  var made = 0
  for candidate in fresh:
    if result.len >= places or made >= room: break
    let g = grantLease(c, master, candidate, owner, versions)
    if g.isSome:
      result.add g.get
      inc made

proc handleLease*(c: var RqClient; profileId, master: string; req: LeaseRequest): ExecutorResponse =
  discard registryTouch("executor", "executor-service", epochTime())
  let owner = if req.executor_id.len > 0: req.executor_id else: "executor"
  # the versions of the host API this executor can run (PIP-001); one from before them knows version 1 only
  let versions = if req.api_versions.len > 0: req.api_versions.mapIt(int(it)) else: @[1]
  for candidate in (if req.run_id.len > 0: @[req.run_id] else: leaseCandidates(c, versions = versions)):
    let g = grantLease(c, master, candidate, owner, versions)
    if g.isSome:
      return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(kind: ExecutorResponseBodyKind.lease, lease: g.get))
  ExecutorResponse(header: Header(protocol: 1),
    body: ExecutorResponseBody(kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "no_run_available")))

proc leaseLost(detail: string): ExecutorResponse =
  ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
    kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "lease_lost", detail: detail)))

proc checkCaller(c: var RqClient; master, runId, token: string): tuple[ok: bool, attempt: int, why: string] =
  ## Does the caller hold the run's lease? If so the lease is renewed (written to the database only when half of it is gone).
  let now = getTime().toUnix()
  let st = leaseStateOf(c, runId)
  case checkLease(master, runId, token, st, now)
  of lvOk:
    if renewDue(st, now):
      discard c.execute(%*[["UPDATE runs SET lease_until = ? WHERE id = ? AND lease_attempt = ? AND lease_until != 0",
        now + leaseTtlSeconds, runId, st.attempt]])
    (true, st.attempt, "")
  of lvForged: (false, 0, "the lease token is not this run's")
  of lvStale: (false, 0, "another executor has taken the run since")
  of lvReleased: (false, 0, "the lease of the run was given back")

proc giveBackLease(c: var RqClient; runId: string; attempt: int) =
  ## the executor suspends or ends the run: the next one may take it at once
  discard c.execute(%*[["UPDATE runs SET lease_until = 0 WHERE id = ? AND lease_attempt = ?", runId, attempt]])

proc handleCall*(c: var RqClient; co: Core; req: HostCall; master: string): ExecutorResponse =
  ## Every host call becomes a step and the run suspends: the step's result (from a job-controller's
  ## PodTransition) lands in run_journal asynchronously, and the executor re-leases the run to continue.
  ## Only the executor that holds the run's lease may call (RUN-008); the suspension gives the lease back.
  let caller = checkCaller(c, master, req.run_id, req.lease_token)
  if not caller.ok: return leaseLost(caller.why)
  if req.kind == "params":
    # the complete launch parameters of the run, from the script's declarations (PIP-012): kept with the run and given to its steps as environment variables
    let json = cast[string](req.payload)
    let why = checkEffective(json)
    if why.len > 0:
      return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
        kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: why)))
    c.storeEffectiveParams(req.run_id, json)
    # a call that answers at once has no step to write its journal entry later: core writes it (the replay of a restarted executor finds it there)
    discard c.appendRow(req.run_id, int(req.seq), "params", json, "")
    return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
      kind: ExecutorResponseBodyKind.result, result: HostResult(seq: req.seq, suspended: false)))
  if req.kind == "table":
    # the table of step numbers (docs/parallel.md section 3.4), made by the executor before the run's first call: kept once, the first one stays
    if req.payload.len > maxStepTable:
      return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
        kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: "the table of step numbers is too large")))
    discard c.execute(%*[["UPDATE runs SET step_table = ? WHERE id = ? AND step_table = ''", cast[string](req.payload), req.run_id]])
    return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
      kind: ExecutorResponseBodyKind.result, result: HostResult(seq: req.seq, suspended: false)))
  if req.kind != "job_sh":
    return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
      kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: "unknown host call " & req.kind)))
  let parts = cast[string](req.payload).split('\t', 4)   # key, image, profile ("" = ordinary), options JSON ("" = none), command (bootstrap.lua)
  let jobKey = parts[0]
  let image = if parts.len > 1: parts[1] else: ""
  let profile = if parts.len > 2: parts[2] else: ""
  let opts = if parts.len > 3: parts[3] else: ""
  let cmd = if parts.len > 4: parts[4] else: ""
  let now = $getTime().toUnix()
  let profileId = profileOfRun(c, req.run_id, co.profileId)    # the profile of the run's organisation (SHD-007)
  if profile in ["build", "deploy"]:
    # the build profile (D-42): a build Pod in the organisation's own namespace, made by its controller; the shard must allow it
    # and the run must belong to an organisation (the namespace that carries the admission policy)
    let fail = proc (detail: string): ExecutorResponse =
      ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
        kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: detail)))
    if profile == "build" and not co.buildOn: return fail("profile \"build\" is not enabled on this shard (CINIM_BUILD)")
    if profile == "deploy" and not co.deployOn: return fail("profile \"deploy\" is not enabled on this shard (CINIM_DEPLOY)")
    let o = c.query(%*[["SELECT o.id FROM runs r JOIN organizations o ON o.id = r.tenant_id WHERE r.id = ?", req.run_id]])
    let ov = o["results"][0]{"values"}
    if ov == nil or ov.len == 0: return fail("profile \"" & profile & "\" needs a run that belongs to an organisation")
  if hasArtifacts(opts) and not c.loadConfig().found:
    return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
      kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error",
        detail: "the step declares artifacts, and this shard has no object store (PUT /api/v1/storage)")))
  let wantedSecrets = secretNamesOf(opts)
  if wantedSecrets.len > 0:
    # the step asks for secrets of the organisation (6.7): they must exist now, and the run must belong to an organisation
    let fail = proc (detail: string): ExecutorResponse =
      ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
        kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: detail)))
    if wantedSecrets.len > maxSecretsPerStep: return fail("a step may ask for at most " & $maxSecretsPerStep & " secrets")
    let o = c.query(%*[["SELECT tenant_id FROM runs r WHERE r.id = ? AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = r.tenant_id)", req.run_id]])
    let ov = o["results"][0]{"values"}
    if ov == nil or ov.len == 0: return fail("secrets need a run that belongs to an organisation")
    let missing = missingSecrets(c.secretVersions(ov[0][0].getStr), wantedSecrets)
    if missing.len > 0: return fail("the organisation has no secret " & missing.join(", ") & " (PUT /api/v1/organizations/{slug}/secrets/{NAME})")
  try:
    discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, ?, ?, ?)",
      schema.newId(), req.run_id, jobKey, protoName(ssRunning), profileId]])
  except RqError:
    discard   # already exists (a later step of the same job): fine, jobs.key is unique per (run_id, key, attempt)
  let jr = c.query(%*[["SELECT id FROM jobs WHERE run_id = ? AND key = ?", req.run_id, jobKey]])
  let jobId = jr["results"][0]{"values"}[0][0].getStr
  # OR IGNORE: the same call twice (two executors met the same run during a rollout, or one asked again after a lost answer) is one step, not a crash of the core
  # the number of the step is the one the executor gave it from its table (an executor from before the tables sends none: the number is then the place); the place in the
  # journal, where the step's result is written, is `seq`
  let number = if req.numbered: int(req.step_no) else: int(req.seq)
  discard c.execute(%*[["INSERT OR IGNORE INTO steps (id, run_id, job_id, ordinal, journal_seq, type, state, profile_id, image, command, opts, profile, queued_at) " &
    "VALUES (?, ?, ?, ?, ?, 'sh', ?, ?, ?, ?, ?, ?, ?)",
    schema.newId(), req.run_id, jobId, number, int(req.seq), protoName(ssPending), profileId, image, cmd, opts, profile, now]])
  kickProfile(profileId)       # the push channel hands it to the organisation's controller at once
  giveBackLease(c, req.run_id, caller.attempt)       # the executor suspends the run: it can be leased again as soon as the step is done
  ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
    kind: ExecutorResponseBodyKind.result, result: HostResult(seq: req.seq, suspended: true)))

proc handleFinish*(c: var RqClient; req: FinishRun; master: string): ExecutorResponse =
  let caller = checkCaller(c, master, req.run_id, req.lease_token)
  if not caller.ok: return leaseLost(caller.why)
  let now = $getTime().toUnix()
  # why a run did not succeed is kept with it (the API shows it as `failure`): the script's error, the parameter that was refused, the limit
  discard c.execute(%*[["UPDATE runs SET state = ?, updated_at = ?, version = version + 1, fail_code = ?, fail_message = ? WHERE id = ?",
    protoName(case req.state
              of RUN_STATE_SUCCEEDED: rsSucceeded
              of RUN_STATE_FAILED: rsFailed
              else: rsInfrastructureError), now,
    (if req.state == RUN_STATE_SUCCEEDED: "" else: req.code[0 ..< min(req.code.len, 64)]),
    (if req.state == RUN_STATE_SUCCEEDED: "" else: req.message[0 ..< min(req.message.len, maxFailMessage)]), req.run_id]])
  giveBackLease(c, req.run_id, caller.attempt)
  ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(kind: ExecutorResponseBodyKind.result,
    result: HostResult(suspended: false)))

proc serveExecutorChannel*(co: Core; port: int) {.thread.} =
  {.cast(gcsafe).}:
    var c = newRq(co.rqliteUrl)
    let (_, secretKey) = loadKeypair(co.certs, "core")
    let conn = listenRep(port, secretKey)
    while not stopServers.load:
      let body = conn.receive()
      if body.len == 0: continue
      let req = Protobuf.decode(cast[seq[byte]](body), ExecutorRequest)
      # an error in one request is answered as an error of that request; it must not end the core (a REP socket also needs its answer to go on)
      let resp = try:
        case req.body.kind
        of ExecutorRequestBodyKind.lease: handleLease(c, co.profileId, secretKey, req.body.lease)
        of ExecutorRequestBodyKind.call: handleCall(c, co, req.body.call, secretKey)
        of ExecutorRequestBodyKind.finish: handleFinish(c, req.body.finish, secretKey)
        of ExecutorRequestBodyKind.finish_run_id, ExecutorRequestBodyKind.notSet:
          ExecutorResponse(header: Header(protocol: 1),
            body: ExecutorResponseBody(kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error")))
      except CatchableError as e:
        stderr.writeLine "core: executor channel: " & e.msg
        ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
          kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "internal", detail: e.msg)))
      let outb = Protobuf.encode(resp)
      var s = newString(outb.len)
      if outb.len > 0: copyMem(addr s[0], unsafeAddr outb[0], outb.len)
      conn.send(s)
    conn.close()
