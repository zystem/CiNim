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
import common/[zmqcurve, rqlite, states, shimstate, memstats, ctrlauth, luaapi, conductorplan, stepenv, scriptsource]
import ctrlpresence, logwindow, keptpods, stepsecrets, projectpolicy, runparams, objectstore, runstorage, ctrlconfig
import std/options
import approvals, audit, cachestore, drains, holds, joblocks, orgvars, schema, logcircuit, loggate, retrypolicy, shimrecord, liveness, components, stepmetrics, orgrules, admission, workkick, runlease, journalchain, journaldb, hubmetrics

import ../../build/nimproto/protos     # the types of the messages, made once by tools/proto/nim_flatten.sh (the macro import_proto3 took 7 s in every compile)
export protos

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
  let r = c.query(%*[["SELECT infra_retries, log_max_bytes, liveness_timeout, log_spool_bytes, log_hold_timeout, pod_limit, job_pod_limit_percent, runs_per_conductor, conductor_min, artifact_quota_bytes, artifact_retention_days, cache_quota_bytes, cache_retention_days, audit_variables " &
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
    result.artifactQuotaBytes = vals[0][9].getBiggestInt(0)
    result.artifactRetentionDays = vals[0][10].getInt(0)
    result.cacheQuotaBytes = vals[0][11].getBiggestInt(0)
    result.cacheRetentionDays = vals[0][12].getInt(0)
    result.auditVariables = vals[0][13].getStr("off")

proc loadPolicy*(c: var RqClient; profileId: string): RetryPolicy =
  result = defaultPolicy()
  result.infraRetries = loadSettings(c, profileId).infraRetries

# ------------------------------------------------------------------ run creation and lookup (REST API)

proc createRun*(co: Core; script: string; tenantId = "t1"; profileId = ""; params: seq[(string, string)] = @[]; triggerId = ""; groupId = ""; source = Source(); actor = ""; approval = ApprovalSpec()): string =
  ## `tenantId` is the organisation's id and `profileId` its execution profile (SHD-007); without them the run belongs to the
  ## shard's default tenant and profile (single-tenant setups and tests). `groupId` is the group the run belongs to (PRJ-001, D-54; "" = the organisation itself).
  ## `actor` is who started it (`actorOf`: `user:<name>`, `token:<id>`, `trigger:<id>` for a trigger that fired by itself; D-92 "only their own runs" asks for it).
  ## `approval` (D-93) makes the run wait, in the state WAITING, for that many approvals before it starts: it is ABORTED at once when fewer people than that could give them.
  ## `source` says where `script` was read from when it was read from a repository (D-63): the repository, the SHA of the commit, the path; the run keeps it (PIP-001) and the script sees it as `run.source`.
  var c = newRq(co.rqliteUrl)
  result = newId()
  let now = $getTime().toUnix()
  # D-82: the commit of the last run of this pipeline (this organisation, project, repository and script) that ended OK: what a pipeline compares the commit with to see what it changed
  var base = ""
  if source.repository.len > 0:
    let last = c.query(%*[["SELECT source_commit FROM runs WHERE tenant_id = ? AND group_id = ? AND source_repository = ? AND source_path = ? AND state = ? AND source_commit <> '' " &
      "ORDER BY created_at DESC, id DESC LIMIT 1", tenantId, groupId, source.repository, source.path, protoName(rsOk)]])["results"][0]{"values"}
    if last != nil and last.len > 0: base = last[0][0].getStr
  # D-86: a run on a protected ref of its project is trusted (its protected secrets, the profile deploy)
  let trusted = source.refName.len > 0 and c.isProtectedRef(groupId, source.refName)
  var initial = protoName(rsQueued)          # D-94: a new run is queued until a conductor leads it (the first lease makes it RUNNING)
  var deadline = 0'i64
  var failCode, failMessage = ""
  if approval.required > 0:
    initial = protoName(rsWaiting)
    deadline = getTime().toUnix() + approval.timeoutSeconds
    let where = c.query(%*[["SELECT COALESCE((SELECT slug FROM organizations WHERE id = ?), ''), COALESCE((SELECT path FROM groups WHERE id = ?), '')", tenantId, groupId]])["results"][0]{"values"}
    let could = c.approverNames(where[0][0].getStr, where[0][1].getStr, source.refName, actor, getTime().toUnix())
    if could.len < approval.required:
      initial = protoName(rsAborted)
      failCode = "no_approvers"
      failMessage = "the run needs " & $approval.required & " approval" & (if approval.required > 1: "s" else: "") & ", and " & (if could.len == 0: "nobody" else: "only " & $could.len) & " besides its author holds run.approve for this project"
  discard c.execute(%*[["INSERT INTO runs (id, tenant_id, group_id, state, version, created_at, updated_at, profile_id, params, trigger_id, api_version, source_repository, source_commit, source_path, source_base, source_ref, trusted, actor_id, approval_required, approval_deadline, fail_code, fail_message) " &
    "VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", result, tenantId, groupId, initial, now, now,
    (if profileId.len > 0: profileId else: co.profileId), (if params.len > 0: toJson(params) else: ""),
    (if triggerId.len > 0: %triggerId else: newJNull()), currentApiVersion, source.repository, source.commit, source.path, base, source.refName, (if trusted: 1 else: 0), actor, approval.required, deadline, failCode, failMessage]])
  # the script itself has nowhere else to live yet (no pipeline_bundles/blob storage, spec 8.2): stash it
  # on the run's own journal as a seq-0 "script" marker the executor service's lease query reads back.
  discard c.execute(%*[["INSERT INTO run_journal (run_id, seq, kind, fingerprint, payload, result, created_at) " &
    "VALUES (?, -1, 'script', '', ?, '', ?)", result, script, now]])
  kickProfile(if profileId.len > 0: profileId else: co.profileId)     # after the script: a conductor of the organisation takes it at once

var maxUnfinishedRuns* = (try: parseInt(getEnv("CINIM_MAX_UNFINISHED_RUNS", "65000")) except ValueError: 65000)
  ## the queue of an organisation is not in memory, it is rows in the database, so it may be long (a slow test environment, a night's work to get through), but a webhook that
  ## has gone mad must not fill the database: a run that is not in a final state counts, whether it is led, waits for a place or waits for a lock of a job

proc queueIsFull*(c: var RqClient; profileId: string): bool =
  ## the organisation (its profile) has `maxUnfinishedRuns` runs that have not ended: no new run is made until some end
  let r = c.query(%*[["SELECT count(*) FROM runs WHERE profile_id = ? AND state NOT IN ('OK', 'FAILED', 'ABORTED', 'SKIPPED', 'TIMED_OUT', 'INFRASTRUCTURE_ERROR')", profileId]])
  r["results"][0]{"values"}[0][0].getBiggestInt >= maxUnfinishedRuns

func stepKeyOf*(ordinal, retries: int): string =
  ## the key of a step's answer in the journal: `s<number>`, and `s<number>~<n>` after the step has been run again n times (docs/parallel.md section 11)
  if retries > 0: "s" & $ordinal & "~" & $retries else: "s" & $ordinal

type AbortOutcome* = enum
  coNotFound, coAborted, coAlreadyFinished

proc abortRun*(c: var RqClient; runId: string; now: int64): tuple[outcome: AbortOutcome, state: string] =
  ## RUN-006: the run ends as ABORTED, its steps that have not ended are ABORTED, its lease is given back. The Pods are removed by the controllers: a step that is CANCELED is
  ## not wanted, so the next poll of the controller that has its Pod says so at once (`unwantedPods`); the shim gets SIGTERM and the build is asked to stop. A report about such a
  ## step that comes later changes nothing (`applyTransition`). A run that has ended is left as it is.
  let r = c.query(%*[["SELECT state FROM runs WHERE id = ?", runId]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0: return (coNotFound, "")
  let was = vals[0][0].getStr
  var cur = rsCreated
  for s in states.RunState:
    if protoName(s) == was: cur = s
  if not canRun(cur, rsAborted): return (coAlreadyFinished, was)
  let res = c.execute(%*[
    ["UPDATE runs SET state = ?, updated_at = ?, version = version + 1, lease_until = 0 WHERE id = ? AND state = ?", protoName(rsAborted), $now, runId, was],
    ["UPDATE steps SET state = ?, finished_at = ?, version = version + 1 WHERE run_id = ? AND state IN (?, ?, ?) AND EXISTS (SELECT 1 FROM runs WHERE id = ? AND state = ?)",
     protoName(ssAborted), $now, runId, protoName(ssPending), protoName(ssStarting), protoName(ssRunning), runId, protoName(rsAborted)]], transaction = true)
  if res["results"][0]{"rows_affected"}.getInt == 0:
    # the run moved on between the read and the write (it ended): say what it is now
    let again = c.query(%*[["SELECT state FROM runs WHERE id = ?", runId]])["results"][0]{"values"}
    return (coAlreadyFinished, if again != nil and again.len > 0: again[0][0].getStr else: was)
  c.releaseRun(runId, now)                       # it holds no lock of a job and waits for none (core/joblocks.nim)
  kickProfile(profileOfRun(c, runId, ""))       # the controllers hear of it now, not at their next poll
  (coAborted, protoName(rsAborted))

type ApprovalOutcome* = enum
  aoNotFound, aoNotWaiting, aoOwnRun, aoAlreadyAnswered, aoGiven, aoApproved, aoRejected

proc answerApproval*(c: var RqClient; runId, user, decision, comment: string; now: int64): tuple[outcome: ApprovalOutcome, state: string, have, required: int] =
  ## D-93: a person's answer to a run that waits for approval. The run is read, the author is refused, the answer is written once for each person; with enough approvals the run is RUNNING
  ## (a conductor takes it at once), with one rejection it is ABORTED. Whether the caller holds `run.approve` is the API\'s to check.
  let r = c.query(%*[["SELECT state, approval_required, COALESCE(actor_id, '') FROM runs WHERE id = ?", runId]])["results"][0]{"values"}
  if r == nil or r.len == 0: return (aoNotFound, "", 0, 0)
  let was = r[0][0].getStr
  let need = r[0][1].getInt
  if was != protoName(rsWaiting) or need == 0: return (aoNotWaiting, was, 0, need)
  if r[0][2].getStr == "user:" & user: return (aoOwnRun, was, 0, need)
  let ins = c.execute(%*[["INSERT OR IGNORE INTO run_approvals (run_id, user_name, decision, comment, at) VALUES (?, ?, ?, ?, ?)", runId, user, decision, comment, now]])
  if ins["results"][0]{"rows_affected"}.getInt == 0: return (aoAlreadyAnswered, was, 0, need)
  if decision == "reject":
    discard c.execute(%*[["UPDATE runs SET state = ?, updated_at = ?, version = version + 1, lease_until = 0, fail_code = 'rejected', fail_message = ? WHERE id = ? AND state = ?",
                          protoName(rsAborted), $now, "rejected by " & user & (if comment.len > 0: ": " & comment else: ""), runId, protoName(rsWaiting)]])
    return (aoRejected, protoName(rsAborted), 0, need)
  let have = c.query(%*[["SELECT count(*) FROM run_approvals WHERE run_id = ? AND decision = 'approve'", runId]])["results"][0]{"values"}[0][0].getInt
  if have < need: return (aoGiven, was, have, need)
  let go = c.execute(%*[["UPDATE runs SET state = ?, updated_at = ?, version = version + 1, lease_until = 0 WHERE id = ? AND state = ?", protoName(rsQueued), $now, runId, protoName(rsWaiting)]])
  if go["results"][0]{"rows_affected"}.getInt > 0: kickProfile(profileOfRun(c, runId, ""))
  (aoApproved, protoName(rsQueued), have, need)

proc sweepApprovals*(c: var RqClient; now: int64): int =
  ## D-93, each beat of the core: a run whose time to be approved has passed is TIMED_OUT; one that has no person left who could give the approvals it still needs is ABORTED
  ## (the last of them was taken off, switched off, or their term ended). Returns how many ended.
  let rows = c.query(%*[["SELECT r.id, r.approval_required, r.approval_deadline, COALESCE(o.slug, ''), COALESCE(g.path, ''), r.source_ref, COALESCE(r.actor_id, '') " &
    "FROM runs r LEFT JOIN organizations o ON o.id = r.tenant_id LEFT JOIN groups g ON g.id = r.group_id WHERE r.state = ? AND r.approval_required > 0", protoName(rsWaiting)]])["results"][0]{"values"}
  if rows == nil: return
  for v in rows:
    let id = v[0].getStr
    if v[2].getBiggestInt > 0 and now >= v[2].getBiggestInt:
      let done = c.execute(%*[["UPDATE runs SET state = ?, updated_at = ?, version = version + 1, lease_until = 0, fail_code = 'approval_timeout', fail_message = 'nobody approved the run in time' WHERE id = ? AND state = ?",
                               protoName(rsTimedOut), $now, id, protoName(rsWaiting)]])
      if done["results"][0]{"rows_affected"}.getInt > 0: inc result
      continue
    let answered = c.query(%*[["SELECT user_name FROM run_approvals WHERE run_id = ?", id]])["results"][0]{"values"}
    var given: seq[string]
    if answered != nil:
      for a in answered: given.add a[0].getStr
    var could = 0
    for n in c.approverNames(v[3].getStr, v[4].getStr, v[5].getStr, v[6].getStr, now):
      if n notin given: inc could
    var haveYes = 0
    let hy = c.query(%*[["SELECT count(*) FROM run_approvals WHERE run_id = ? AND decision = 'approve'", id]])["results"][0]{"values"}
    if hy != nil and hy.len > 0: haveYes = hy[0][0].getInt
    if haveYes + could < v[1].getInt:
      let done = c.execute(%*[["UPDATE runs SET state = ?, updated_at = ?, version = version + 1, lease_until = 0, fail_code = 'no_approvers', fail_message = 'nobody is left who could approve the run' WHERE id = ? AND state = ?",
                               protoName(rsAborted), $now, id, protoName(rsWaiting)]])
      if done["results"][0]{"rows_affected"}.getInt > 0: inc result

type RetryOutcome* = enum
  roNotFound, roRetried, roNotRetryable, roNothingToRetry, roVolumeGone

proc retryPlan(c: var RqClient; runId: string): tuple[outcome: RetryOutcome, state: string, failed: JsonNode] =
  ## whether a run may be run again, and the steps that failed (ordinal, retries); `outcome` is roRetried when it may. The same checks answer the call and the page that asks whether to offer the button.
  let r = c.query(%*[["SELECT state, storage_released FROM runs WHERE id = ?", runId]])["results"][0]{"values"}
  if r == nil or r.len == 0: return (roNotFound, "", nil)
  let was = r[0][0].getStr
  if was notin [protoName(rsFailed), protoName(rsInfrastructureError), protoName(rsTimedOut)]: return (roNotRetryable, was, nil)
  if r[0][1].getInt != 0: return (roVolumeGone, was, nil)
  let failed = c.query(%*[["SELECT ordinal, retries FROM steps WHERE run_id = ? AND state IN (?, ?, ?) ORDER BY ordinal", runId,
                           protoName(ssFailed), protoName(ssLost), protoName(ssTimedOut)]])["results"][0]{"values"}
  if failed == nil or failed.len == 0: return (roNothingToRetry, was, nil)
  (roRetried, was, failed)

proc runActions*(c: var RqClient; runId, state: string): tuple[abort, retry: bool] =
  ## what the state of a run allows, apart from who asks: it can be stopped while it has not ended, and run again when it failed, its volume is there and a step failed.
  ## The API adds the rights of the caller (`actions` of GET /api/v1/runs/{id}); the calls themselves check again.
  var cur = rsCreated
  var known = false
  for s in states.RunState:
    if protoName(s) == state:
      cur = s
      known = true
  (known and canRun(cur, rsAborted), c.retryPlan(runId).outcome == roRetried)

proc retryRun*(c: var RqClient; runId: string; now: int64): tuple[outcome: RetryOutcome, state: string, steps: seq[int]] =
  ## Run again only what failed (PIP-015 failed-only, docs/parallel.md section 11): the same run, if its volume is still there. A run that ended FAILED, INFRASTRUCTURE_ERROR
  ## or TIMED_OUT is RUNNING again, its steps that failed (FAILED, LOST, TIMED_OUT) get a new attempt and wait to be handed out, and the steps that succeeded are not run again:
  ## the script is replayed from the journal up to the failed step. The journal is chained and only grows, so the record of a failed step stays; a record of kind `retry`
  ## names the keys it supersedes, and the new result of the step is written under `s<n>~<retries>` (executor/replay.nim finds it there). Everything is one transaction
  ## with the record, so a retry that is asked twice at once is one retry.
  let plan = c.retryPlan(runId)
  if plan.outcome != roRetried: return (plan.outcome, plan.state, @[])
  let was = plan.state
  let failed = plan.failed
  var keys = newJArray()
  var ordinals: seq[int]
  for v in failed:
    keys.add %stepKeyOf(v[0].getInt, v[1].getInt)
    ordinals.add v[0].getInt
  let markers = c.query(%*[["SELECT count(*) FROM run_journal WHERE run_id = ? AND kind = 'retry'", runId]])["results"][0]{"values"}[0][0].getInt
  let again = c.appendRow(runId, "retry#" & $markers, "retry", $keys, "", alongside = %*[
    ["UPDATE runs SET state = ?, updated_at = ?, version = version + 1, lease_until = 0, fail_code = '', fail_message = '' WHERE id = ? AND state = ?", protoName(rsRunning), $now, runId, was],
    ["UPDATE log_streams SET state = 'abandoned', closed_at = ? WHERE state = 'open' AND step_id IN (SELECT id FROM steps WHERE run_id = ? AND state IN (?, ?, ?))",
     $now, runId, protoName(ssFailed), protoName(ssLost), protoName(ssTimedOut)],
    ["UPDATE steps SET state = ?, attempt = attempt + 1, retries = retries + 1, controller_id = NULL, wait_reason = NULL, exit_code = NULL, shim_n = 0, shim_phase = '', shim_json = '', " &
     "shim_seen_at = 0, shim_source = '', termination = NULL, pod_reason = '', pod_message = '', pod_diag = '', not_before = 0, finished_at = NULL, version = version + 1 " &
     "WHERE run_id = ? AND state IN (?, ?, ?)", protoName(ssPending), runId, protoName(ssFailed), protoName(ssLost), protoName(ssTimedOut)]])
  if not again: return (roNotRetryable, was, @[])          # another retry of the same run won the race: this one did nothing
  kickProfile(profileOfRun(c, runId, ""))
  (roRetried, protoName(rsRunning), ordinals)

proc stateOfRun*(co: Core; runId: string): string =
  ## the state a run is in now (a new one is QUEUED, or WAITING for approval, or ABORTED at once when nobody could approve it)
  var c = newRq(co.rqliteUrl)
  let v = c.query(%*[["SELECT state FROM runs WHERE id = ?", runId]])["results"][0]{"values"}
  if v != nil and v.len > 0: v[0][0].getStr else: ""

proc getRun*(co: Core; runId: string): JsonNode =
  var c = newRq(co.rqliteUrl)
  let r = c.query(%*[["SELECT r.id, COALESCE((SELECT g.path FROM groups g WHERE g.id = r.group_id), ''), r.state, r.created_at, r.updated_at, COALESCE(o.slug, ''), r.params, COALESCE(r.trigger_id, ''), r.fail_code, r.fail_message, r.source_repository, r.source_commit, r.source_path, r.source_base, r.source_ref, r.trusted, COALESCE(r.actor_id, ''), r.approval_required, r.approval_deadline " &
    "FROM runs r LEFT JOIN organizations o ON o.id = r.tenant_id WHERE r.id = ?", runId]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0: return nil
  let row = vals[0]
  result = %*{"id": row[0].getStr, "organization": row[5].getStr, "project": row[1].getStr, "state": row[2].getStr,
              "created_at": row[3].getStr, "updated_at": row[4].getStr}
  if row[7].getStr.len > 0: result["trigger_id"] = %row[7].getStr
  if row[10].getStr.len > 0:
    result["source"] = %*{"repository": row[10].getStr, "commit": row[11].getStr, "path": row[12].getStr}
    if row[13].getStr.len > 0: result["source"]["base"] = %row[13].getStr          # D-82
    if row[14].getStr.len > 0: result["source"]["ref"] = %row[14].getStr           # D-86
  if row[16].getStr.len > 0: result["started_by"] = %row[16].getStr                  # D-92: `user:<name>`, `token:<id>`, `trigger:<id>`
  if row[17].getInt > 0:
    # D-93: the approvals a run asks for, who has given them, and until when it waits
    var yes, no: seq[string]
    let ans = c.query(%*[["SELECT user_name, decision FROM run_approvals WHERE run_id = ? ORDER BY at, user_name", runId]])["results"][0]{"values"}
    if ans != nil:
      for a in ans:
        if a[1].getStr == "approve": yes.add a[0].getStr else: no.add a[0].getStr
    result["approval"] = %*{"required": row[17].getInt, "approved_by": yes, "rejected_by": no, "deadline": row[18].getBiggestInt, "waiting": row[2].getStr == protoName(rsWaiting)}
  result["trusted"] = %(row[15].getInt > 0)                                          # D-86: a run on a protected ref of its project
  if row[8].getStr.len > 0 or row[9].getStr.len > 0: result["failure"] = %*{"code": row[8].getStr, "message": row[9].getStr}
  if row[6].getStr.len > 0:
    result["params"] = (try: parseJson(row[6].getStr) except JsonParsingError: newJObject())
  let vars = c.effectiveVariables(runId)
  if vars.len > 0:
    # VAR-001: what the steps see, and where each value came from (an override at a lower level is shown, not hidden)
    var vj = newJArray()
    for e in vars:
      var item = %*{"name": e.name, "value": e.value, "source": e.source}
      if e.group.len > 0: item["group"] = %e.group
      vj.add item
    result["variables"] = vj
  let held = c.holdOf(runId)
  if held.held: result["hold"] = held.hold.view      # DAT-006: a legal hold
  let covering = c.coveringHold(runId)               # ... and the one of its group or of its organisation that covers it
  if covering.held: result["held_by"] = covering.hold.view
  let lockWait = c.waitingFor(runId)
  if lockWait.waiting: result["waiting_for_lock"] = %*{"name": lockWait.name, "held_by": lockWait.heldBy}
  # RUN-015: a queued step that waits for the log circuit says so (API shows the reason)
  let w = c.query(%*[["SELECT wait_reason FROM steps WHERE run_id = ? AND wait_reason IS NOT NULL LIMIT 1", runId]])
  let wv = w["results"][0]{"values"}
  if wv != nil and wv.len > 0: result["wait_reason"] = %wv[0][0].getStr
  # the steps with their attempt and the reason the last attempt ended the way it did (lost_never_started was retried,
  # outcome_unknown was not, logs_undelivered = result known but the log is incomplete, ...): visible, not buried in a log
  let st = c.query(%*[["SELECT ordinal, attempt, state, exit_code, termination, pod_reason, pod_message, pod_diag, COALESCE(CAST(started_at AS INTEGER), 0), COALESCE(CAST(finished_at AS INTEGER), 0), COALESCE(wait_reason, ''), not_before FROM steps WHERE run_id = ? ORDER BY ordinal", runId]])
  var steps = newJArray()
  let sv = st["results"][0]{"values"}
  # D-94: why a run or a step is not running yet: the limits of the organisation, a pause after a lost attempt, the log circuit, or nobody has taken it
  let pid = profileOfRun(c, runId, "")
  let limit = loadSettings(c, pid).podLimit
  var inFlight = 0
  if sv != nil and sv.len > 0:
    let fl = c.query(%*[["SELECT COUNT(*) FROM steps WHERE profile_id = ? AND state IN (?, ?)", pid, protoName(ssStarting), protoName(ssRunning)]])["results"][0]{"values"}
    if fl != nil and fl.len > 0: inFlight = fl[0][0].getInt
  let nowSec = getTime().toUnix()
  if row[2].getStr == protoName(rsQueued):
    let lv = c.query(%*[["SELECT COUNT(*) FROM runs WHERE profile_id = ? AND state = ? AND lease_attempt > 0", pid, protoName(rsRunning)]])["results"][0]{"values"}
    let led = if lv != nil and lv.len > 0: lv[0][0].getInt else: 0
    result["queue"] = %*{"reason": (if led >= limit: "the organisation leads " & $led & " runs and its limit is " & $limit & " (pod_limit): this run starts when one of them ends"
                                    else: "no conductor of the organisation has taken it yet; one starts when the organisation has a free place")}
  # D-94: PENDING - the run is being led, nothing of it runs, and its steps wait for a place
  var anyRunning, firstPending = ""
  if sv != nil:
    for r in sv:
      if r[2].getStr in [protoName(ssStarting), protoName(ssRunning)]: anyRunning = "yes"
  if sv != nil:
    for r in sv:
      var pending = ""
      if r[2].getStr == protoName(ssPending):
        pending = if r[10].getStr.len > 0: (if r[10].getStr == reasonUnavailable: "the log circuit is open: the log store does not answer" else: r[10].getStr)
                  elif r[11].getBiggestInt > nowSec: "paused after a lost attempt until " & $r[11].getBiggestInt & " (epoch seconds)"
                  elif inFlight >= limit: "the organisation runs " & $inFlight & " pods and its limit is " & $limit & " (pod_limit)"
                  else: "no controller has taken it yet"
        if firstPending.len == 0: firstPending = pending
      steps.add %*{"pending_reason": pending, "seq": r[0].getInt, "attempt": r[1].getInt, "state": r[2].getStr,
                   "exit_code": (if r[3].kind == JNull: newJNull() else: %r[3].getInt), "termination": r[4].getStr,
                   "pod_reason": r[5].getStr, "pod_message": r[6].getStr,
                   "started_at": r[8].getInt, "finished_at": r[9].getInt,        # epoch seconds; 0: not yet (the UI says how long a step took)
                   "pod_diag": (if r[7].getStr.len > 0: (try: parseJson(r[7].getStr) except CatchableError: newJNull()) else: newJNull())}
  result["steps"] = steps
  if row[2].getStr == protoName(rsRunning) and anyRunning.len == 0 and firstPending.len > 0: result["pending"] = %*{"reason": firstPending}

# ------------------------------------------------------------------ retry settings (D-27)

proc getProfileSettings*(co: Core; profileId = ""): JsonNode =
  ## What the UI shows and edits; of the profile given (an organisation's) or the shard's default one.
  var c = newRq(co.rqliteUrl)
  let p = loadSettings(c, if profileId.len > 0: profileId else: co.profileId)
  %*{"infra_retries": p.infraRetries, "log_max_bytes": p.logMaxBytes, "liveness_timeout": p.livenessTimeout,
     "log_spool_bytes": p.logSpoolBytes, "log_hold_timeout": p.logHoldTimeout,
     "pod_limit": p.podLimit, "job_pod_limit_percent": p.jobPodLimitPercent,
     "runs_per_conductor": p.runsPerConductor, "conductor_min": p.conductorMin,
     "artifact_quota_bytes": p.artifactQuotaBytes, "artifact_retention_days": p.artifactRetentionDays,
     "cache_quota_bytes": p.cacheQuotaBytes, "cache_retention_days": p.cacheRetentionDays, "audit_variables": p.auditVariables}

proc setProfileSettings*(co: Core; s: ProfileSettings; profileId = "") =
  var c = newRq(co.rqliteUrl)
  discard c.execute(%*[["UPDATE execution_profiles SET infra_retries = ?, log_max_bytes = ?, liveness_timeout = ?, " &
    "log_spool_bytes = ?, log_hold_timeout = ?, pod_limit = ?, job_pod_limit_percent = ?, runs_per_conductor = ?, conductor_min = ?, " &
    "artifact_quota_bytes = ?, artifact_retention_days = ?, cache_quota_bytes = ?, cache_retention_days = ?, audit_variables = ? WHERE id = ?",
    s.infraRetries, s.logMaxBytes, s.livenessTimeout, s.logSpoolBytes, s.logHoldTimeout, s.podLimit, s.jobPodLimitPercent, s.runsPerConductor, s.conductorMin,
    s.artifactQuotaBytes, s.artifactRetentionDays, s.cacheQuotaBytes, s.cacheRetentionDays, s.auditVariables,
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

const defaultRunWindow* = 200       ## lines in a window of the log of a run when the request says none (DAT-007)

proc getRunLog*(co: Core; runId: string; wantCursor: bool; cursor: RunCursor; backwards: bool; limit = defaultRunWindow): JsonNode =
  ## D-77: a window of the log of the whole run, the lines of its steps in the order of step, attempt and line, in one query of the store. With no cursor it is the last `limit` lines of the run
  ## (`backwards`) or the first (not); with a cursor, the lines after it (its own included) or the ones before it (not included, the nearest). `earlier` and `later` are the cursors to ask next, left out when
  ## there is nothing that way. nil for a run that does not exist. A run logged before the records carried a step has no lines here.
  var c = newRq(co.rqliteUrl)
  let st = c.query(%*[["SELECT state FROM runs WHERE id = ?", runId]])["results"][0]{"values"}
  if st == nil or st.len == 0: return nil
  let n = min(max(1, limit), maxWindow)
  let q = runLogQuery(runId, wantCursor, cursor, backwards, n + 1)         # one more than asked: that there is one is how it is known that there is more
  var lines: seq[RunLine]
  if q.len > 0:
    try:
      var http = newHttpClient(timeout = 5000)
      defer: http.close()
      lines = parseRunRecords(http.getContent(co.victoriaLogsUrl & "/select/logsql/query?query=" & encodeUrl(q) & "&limit=" & $(n + 1)))
    except CatchableError:
      discard                                                           # the store does not answer: an empty window, not a platform error (as for a step)
  let more = lines.len > n
  if more:
    if backwards: lines.delete(0) else: lines.setLen n                   # the extra one is the farthest from the cursor
  var arr = newJArray()
  for l in lines:
    arr.add %*{"step": l.step, "job_id": l.jobId, "step_id": l.stepId, "attempt": l.attempt, "ln": l.ln, "text": l.text}
  result = %*{"run_id": runId, "run_state": st[0][0].getStr, "lines": arr}
  let finished = st[0][0].getStr notin ["CREATED", "COMPILING", "QUEUED", "RUNNING", "WAITING"]
  if lines.len > 0:
    let first = RunCursor(step: lines[0].step, attempt: lines[0].attempt, ln: lines[0].ln)
    let last = RunCursor(step: lines[^1].step, attempt: lines[^1].attempt, ln: lines[^1].ln + 1)
    if backwards:
      if more: result["earlier"] = %cursorText(first)
      if wantCursor or not finished: result["later"] = %cursorText(last)         # a page before a cursor has the lines after it; the last page of a run that goes on may get more
    else:
      if wantCursor: result["earlier"] = %cursorText(first)
      if more: result["later"] = %cursorText(last)

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

proc stepJournalKey(c: var RqClient; runId: string; ordinal: int): string =
  let r = c.query(%*[["SELECT retries FROM steps WHERE run_id = ? AND ordinal = ?", runId, ordinal]])["results"][0]{"values"}
  stepKeyOf(ordinal, if r != nil and r.len > 0: r[0][0].getInt else: 0)

proc answerText(c: var RqClient; t: PodTransition; attempt: int): string =
  ## What follows the exit code in the answer of a step, from the shim's newest state (the one the controller read from the Pod's log, or the one stored). The answer of a `j.cache.restore`
  ## step (DAT-004) is the key the shim restored, "" for a miss. The answer of any other step is its outputs (STO-003): the validated text of `$CICD_OUTPUT`, which the script reads as `r.outputs`.
  let r = c.query(%*[["SELECT opts, shim_json FROM steps WHERE run_id = ? AND ordinal = ? AND attempt = ?", t.step.run_id, int(t.step.seq), attempt]])["results"][0]{"values"}
  if r == nil or r.len == 0: return
  let ds = cacheDecls(r[0][0].getStr)
  let restore = ds.len > 0 and ds[0].mode == "restore"
  var best = none(ShimState)
  for text in [t.shim_state_json, r[0][1].getStr]:
    if text.len == 0: continue
    let st = try: fromJson(parseJson(text)) except CatchableError: none(ShimState)
    if st.isSome and (best.isNone or st.get.n > best.get.n): best = st
  if best.isNone: return
  if restore: (if t.exit_code == 0 and best.get.cache.len > 0: best.get.cache[0] else: "")
  else: best.get.outputs

proc applyTransition*(c: var RqClient; policy: RetryPolicy; t: PodTransition) =
  let attempt = int(t.step.attempt)
  let now = getTime().toUnix()
  # Fencing (the zombie/ghost problem of Jenkins and TeamCity agents): a report about an attempt that is no longer
  # the step's current one - the step was already requeued, or finished - changes nothing.
  let cur = c.query(%*[["SELECT attempt, state FROM steps WHERE run_id = ? AND ordinal = ?", t.step.run_id, int(t.step.seq)]])
  let cv = cur["results"][0]{"values"}
  if cv == nil or cv.len == 0 or cv[0][0].getInt != attempt: return
  if cv[0][1].getStr in [protoName(ssOk), protoName(ssFailed), protoName(ssLost), protoName(ssAborted)]:
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
        let podSays = if t.exit_code == 0: ssOk else: ssFailed
        let shimSays = stepStateOf(shim.get)
        if shimSays != podSays and not (shimSays == ssTimedOut and podSays == ssFailed):
          stderr.writeLine "core: step " & t.step.run_id & "/" & $t.step.seq & " attempt " & $attempt & ": the Pod says " &
            protoName(podSays) & ", the shim's last state says " & protoName(shimSays) & " (" & shim.get.reason & ")"
    # the step's own result: write it into run_journal, close out the step
    let res = $t.exit_code & "\n" & c.answerText(t, attempt)
    # payload must equal exactly what the executor's host call sent (bootstrap.lua Job:sh:
    # self.__key .. "\t" .. self.__image .. "\t" .. profile .. "\t" .. opts .. "\t" .. cmd, handleCall's req.payload) or replay sees it
    # as a different call than the one in the journal and fails script_nondeterminism - steps.command
    # alone is missing the job key and image, so join jobs for the key.
    let pl = c.query(%*[["SELECT j.key || char(9) || s.image || char(9) || s.profile || char(9) || s.opts || char(9) || s.command " &
      "FROM steps s JOIN jobs j ON j.id = s.job_id WHERE s.run_id = ? AND s.ordinal = ?", t.step.run_id, int(t.step.seq)]])
    let plv = pl["results"][0]{"values"}
    if plv != nil and plv.len > 0:
      try:
        # the step is closed out and its result goes into the journal, chained, in one transaction; if the record is already there
        # (a retried poll) nothing is done again
        discard c.appendRow(t.step.run_id, stepJournalKey(c, t.step.run_id, int(t.step.seq)), "job_sh", plv[0][0].getStr, res, alongside = %*[
          ["UPDATE steps SET state = ?, exit_code = ?, termination = ?, pod_reason = ?, pod_message = ?, pod_diag = ?, finished_at = ? WHERE run_id = ? AND ordinal = ? AND attempt = ?",
           protoName(if t.exit_code == 0: ssOk else: ssFailed), t.exit_code, reason, podReason, podMessage, podDiag, $now,
           t.step.run_id, int(t.step.seq), attempt],
          ["UPDATE runs SET dirty = 1 WHERE id = ?", t.step.run_id]])
        # the shim could not hand over its artifacts or its log: they are on the run's volume, to be fetched when the controller is told to (core/drains.nim)
        c.noteUndelivered(t.step.run_id, int(t.step.seq), attempt, reason, int(t.exit_code), now)
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
  let state = if exitCode == 0: STEP_STATE_OK else: STEP_STATE_FAILED
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
  if now mod 60 < 6: audit.prune(c, now)          # about once a minute: the audit keeps 90 days (core/audit.nim)
  c.settle(now)       # locks of jobs: what a run that has ended held is let go, and the lists are looked at (core/joblocks.nim)
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

proc startEnv(c: var RqClient; runId: string; ordinal, attempt: int; claimedAt: int64; optsJson = ""): seq[(string, string)] =
  ## The environment of a step, from the lowest (VAR-004): the plain variables of the run's organisation and its launch parameters (core/orgvars.nim), then the `env` of the
  ## pipeline and of the job that the script put in the step's options. And for the first step of the run only, in `CICD_VARIABLES`, their names, so that its shim prints the
  ## header of VAR-005. The first step is the one with no step claimed before it (two claimed in the same second: the lower number); two steps claimed together may both
  ## print it, which is harmless; a step that is run again does not. (What a step writes to $CICD_ENV and its own `env` are applied by the shim, above these.)
  result = c.stepEnv(runId)
  for (k, v) in envOf(optsJson, "env"):
    var found = false
    for i in 0 ..< result.len:
      if result[i][0] == k:
        result[i] = (k, v)
        found = true
    if not found: result.add (k, v)
  if attempt != 1 or result.len == 0: return
  let earlier = c.query(%*[["SELECT count(*) FROM steps WHERE run_id = ? AND claimed_at > 0 AND (claimed_at < ? OR (claimed_at = ? AND ordinal < ?))", runId, claimedAt, claimedAt, ordinal]])
  if earlier["results"][0]{"values"}[0][0].getInt > 0: return
  var names: seq[string]
  for (k, v) in result: names.add k
  result.add ("CICD_VARIABLES", names.join(","))

const cancelGraceSeconds* = 50       ## a Pod that is removed while it runs: its shim stops the build (SIGTERM, then SIGKILL after 20 s), delivers the log (up to 15 s) and exits, so the Pod has this long (less than the 60 s of its spec)

proc unwantedPods*(c: var RqClient; inventory: seq[PodInfo]): seq[StepRef] =
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
        elif attempt == int(p.step.attempt) and state in [protoName(ssLost), protoName(ssAborted)]: wanted = false     # core gave up on it, or it was cancelled: no grace needed
        elif attempt == int(p.step.attempt) and state notin [protoName(ssStarting), protoName(ssRunning), protoName(ssPending)] and
             now - row[4].getBiggestInt > 30: wanted = false     # finished by itself: its shim is exiting, leave it a little time
    if not found or not wanted: result.add p.step

var unenrolledControllers* = getEnv("CINIM_UNENROLLED_CONTROLLERS") == "on"
  ## serve a controller whose namespace has no identity (or names none) instead of refusing it: for development and tests, never in a cluster (T-46); set at start

var releaseAskedAt {.threadvar.}: Table[string, float]     ## when the runs whose volume may go were last looked for, per profile (STO-006)
var refusedLoggedAt {.threadvar.}: Table[string, float]    ## a controller that keeps being refused is said once a minute, not every poll

proc controllerConfigOf*(s: ShardSettings): ControllerConfig =
  ## the settings of the shard as the wire carries them to a controller
  ControllerConfig(present: true, build_enabled: s.buildEnabled, build_seccomp: s.buildSeccomp, build_caps: s.buildCaps,
                   build_memory_limit: s.buildMemoryLimit, build_ephemeral_limit: s.buildEphemeralLimit, build_cpu_request: s.buildCpuRequest, build_cpu_limit: s.buildCpuLimit,
                   run_storage_size: s.runStorageSize,
                   run_storage_class: s.runStorageClass, run_storage_access: s.runStorageAccess,
                   collector_addr: s.collectorAddr, step_report_addr: s.stepReportAddr, artifact_addr: s.artifactAddr, status_addr: s.statusAddr,
                   log_spool_bytes: uint64(s.logSpoolBytes), log_hold_timeout_seconds: uint32(s.logHoldTimeout),
                   pod_retention_read_seconds: uint32(max(s.podRetentionRead, 0)), pod_retention_unread_seconds: uint32(max(s.podRetentionUnread, 0)))

var conductorImage*: string = getEnv("CINIM_CONDUCTOR_IMAGE")      ## the conductor image of the shard; empty: the controllers are told nothing about conductors
const conductorDrainSeconds* = 30

proc runCounts*(c: var RqClient; profileId: string): tuple[active, waiting: int] =
  ## the organisation's runs that are not over: those that were led before (they hold a place of pod_limit) and those that have not been led yet
  let r = c.query(%*[["SELECT COUNT(CASE WHEN lease_attempt > 0 THEN 1 END), COUNT(*) FROM runs WHERE profile_id = ? AND state IN (?, ?)", profileId, protoName(rsQueued), protoName(rsRunning)]])
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
  # an identity is refused, unless the core runs with CINIM_UNENROLLED_CONTROLLERS=on (development and tests).
  let identity = c.credentialRow(req.namespace)
  let decision = decide(identity, master, req.namespace, req.credential, req.bootstrap_token, getTime().toUnix(), unenrolledControllers)
  case decision.verdict
  of vRefused:
    let why = refusal(identity, master, req.namespace, req.credential, req.bootstrap_token, getTime().toUnix())
    let now = epochTime()
    if now - refusedLoggedAt.getOrDefault(req.namespace, 0.0) > 60:
      refusedLoggedAt[req.namespace] = now
      stderr.writeLine "core: a controller for the namespace '" & req.namespace & "' (session " & req.session_id & ") is refused (" & why.code & "): " & why.detail
    return PollResponse(header: Header(protocol: 1), unauthorized: true, refusal: why.code, poll_after_ms: 5000)
  of vIssue:
    let row = c.credentialRow(req.namespace)
    echo "core: the controller of ", req.namespace, " enrolled with its bootstrap token"
    return PollResponse(header: Header(protocol: 1), issued_credential: controllerCredential(master, req.namespace, row.generation), poll_after_ms: 200)
  of vOk:
    if decision.confirm: c.confirmCredential(req.namespace)
    if not push: notePoll(req.namespace, getTime().toUnix())       # the controller is heard: the supervisor of the organisation (orgreconcile.nim) leaves it alone
  of vUnenrolled: discard
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
  # DAT-003: what the controller said of the drains it was ordered
  for d in req.steps_drained: c.recordDrained(d.step.run_id, int(d.step.seq), int(d.step.attempt), d.ok, d.final, d.detail, getTime().toUnix())
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
    commands.add Command(seq: seq, body: CommandBody(kind: CommandBodyKind.cancel, cancel: CancelStep(step: step, grace_seconds: cancelGraceSeconds)))
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
    let claimedNow = getTime().toUnix()
    let r = c.execute(%*[["UPDATE steps SET state = ?, controller_id = ?, claimed_at = ?, version = version + 1, " &
      "pod_reason = CASE WHEN wait_reason = 'quota_exceeded' THEN '' ELSE pod_reason END, " &
      "pod_message = CASE WHEN wait_reason = 'quota_exceeded' THEN '' ELSE pod_message END, " &
      "wait_reason = CASE WHEN wait_reason = 'quota_exceeded' THEN NULL ELSE wait_reason END " &
      "WHERE id = ? AND state = ? RETURNING run_id, ordinal, image, command, attempt, opts, profile, job_id",
      protoName(ssStarting), req.session_id, claimedNow, stepId, protoName(ssPending)]])
    let vals = r["results"][0]{"values"}
    if vals == nil or vals.len == 0: continue    # another poll took it first
    let row = vals[0]
    commands.add Command(seq: seq, body: CommandBody(kind: CommandBodyKind.start, start: StartStep(
      step: StepRef(run_id: row[0].getStr, seq: uint32(row[1].getInt), attempt: uint32(row[4].getInt)),
      image: row[2].getStr, command: @["sh", "-c", row[3].getStr], opts_json: row[5].getStr, log_max_bytes: uint64(settings.logMaxBytes),
      log_spool_bytes: uint64(settings.logSpoolBytes), log_hold_timeout_seconds: uint32(settings.logHoldTimeout),
      profile: row[6].getStr, volume: (if isolatedWorkspace(row[5].getStr): row[7].getStr else: ""), secret_names: secretNamesOf(row[5].getStr), env: startEnv(c, row[0].getStr, row[1].getInt, row[4].getInt, claimedNow, row[5].getStr).mapIt(EnvEntry(key: it[0], value: it[1])),
      step_token: (if secretNamesOf(row[5].getStr).len > 0 or hasArtifacts(row[5].getStr) or cacheDecls(row[5].getStr).len > 0: stepToken(master, row[0].getStr, row[1].getInt, row[4].getInt) else: ""))))
    inc seq
  # STO-006: the controller deleted these volumes; and the runs whose volume may go now (it is told again until it says it is done)
  markReleased(c, req.storage_released)
  notePressure(profileId, req.storage_used_bytes, req.storage_hard_bytes)      # a report without a quota says nothing
  var release: seq[string]
  if epochTime() - releaseAskedAt.getOrDefault(profileId, 0.0) >= 10.0 or req.storage_released.len > 0:   # a few seconds' delay in deleting a volume costs nothing
    releaseAskedAt[profileId] = epochTime()
    release = releasableRuns(c, profileId, getTime().toUnix(), retentionFromEnv())
  var drainOrders: seq[DrainStep]
  if not push and profileId.len > 0:      # the push channel answers for work, the poll names the drains
    for d in c.dueDrains(profileId, getTime().toUnix()):
      drainOrders.add DrainStep(step: StepRef(run_id: d.runId, seq: uint32(d.ordinal), attempt: uint32(d.attempt)), image: d.image,
                                step_token: stepToken(master, d.runId, d.ordinal, d.attempt), artifacts: d.artifacts, logs: d.logs, volume: d.volume)
  PollResponse(header: Header(protocol: 1), commands: commands, drain_steps: drainOrders, release_storage: release, config: controllerConfigOf(shardSettingsFromEnv()),
               gate: protos.GateState(open: gate.isOpen, reason: gate.reason), poll_after_ms: 1000,
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
# a check of a script before a run exists (PIP-016, core/preflight.nim)
proc encodeCheckScript*(r: CheckScript): string = wireString(Protobuf.encode(r))
proc decodeCheckScript*(payload: string): CheckScript = Protobuf.decode(cast[seq[byte]](payload), CheckScript)
proc encodeCheckResult*(r: CheckResult): string = wireString(Protobuf.encode(r))
proc decodeCheckResult*(payload: string): CheckResult = Protobuf.decode(cast[seq[byte]](payload), CheckResult)

# ------------------------------------------------------------------ ExecutorChannel (executor <-> core)

proc loadScript(c: var RqClient; runId: string): string =
  let r = c.query(%*[["SELECT payload FROM run_journal WHERE run_id = ? AND seq = -1", runId]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: vals[0][0].getStr else: ""

proc journalEntries(rows: seq[Row]): seq[JournalEntry] =
  for r in rows:
    result.add JournalEntry(seq: uint64(r.seq), key: r.key, kind: r.kind, payload: cast[seq[byte]](r.payload), result: cast[seq[byte]](r.result),
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
  let r = c.execute(%*[["UPDATE runs SET lease_attempt = lease_attempt + 1, lease_until = ?, lease_owner = ?, dirty = 0, " &
    "state = '" & protoName(rsRunning) & "', updated_at = CASE WHEN state = '" & protoName(rsQueued) & "' THEN '" & $now & "' ELSE updated_at END, version = version + 1 " &
    "WHERE id = ? AND lease_attempt = ? AND (lease_until = 0 OR lease_until < ?) AND state IN (?, ?) " &
    (if versions.len > 0: "AND api_version IN (" & sqlVersionList(versions) & ") " else: "") & "RETURNING lease_attempt",
    now + leaseTtlSeconds, owner, runId, st.attempt, now, protoName(rsQueued), protoName(rsRunning)]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0: "" else: leaseToken(master, runId, vals[0][0].getInt)

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
      "WHERE id = ? AND state IN (?, ?)", protoName(rsInfrastructureError), $getTime().toUnix(), v.check.why, candidate, protoName(rsQueued), protoName(rsRunning)]])
    return none(LeaseGranted)
  let vr = c.query(%*[["SELECT api_version, step_table, source_repository, source_commit, source_path, source_base FROM runs WHERE id = ?", candidate]])["results"][0]{"values"}
  var given = runParams(c, candidate).mapIt(ParamsEntry(key: it[0], value: it[1]))
  if vr != nil and vr.len > 0 and vr[0][2].getStr.len > 0:
    for (k, v) in sourceParams(vr[0][2].getStr, vr[0][3].getStr, vr[0][4].getStr, vr[0][5].getStr): given.add ParamsEntry(key: k, value: v)
  some LeaseGranted(lease_token: token, ttl_seconds: uint32(leaseTtlSeconds), run_id: candidate,
                    api_version: uint32(if vr != nil and vr.len > 0: vr[0][0].getInt(1) else: 1),
                    step_table: (if vr != nil and vr.len > 0: vr[0][1].getStr else: ""),
                    script: loadScript(c, candidate), journal: journalEntries(v.rows),
                    params: given)

proc leaseForConductor*(c: var RqClient; profileId, master, owner: string; versions: seq[int]; places: int): seq[LeaseGranted] =
  ## What the core pushes to a conductor of an organisation that has `places` free: first the runs that were led before and whose wait is over (they
  ## already hold a place of the organisation), then new runs while the organisation has fewer active runs than its `pod_limit` (RUN-004). Only the
  ## organisation's own runs, only of the host API versions the conductor can run.
  if places <= 0: return
  # one look at what is free: the runs that were led before come first. When nothing is free (the usual case) that is the only query.
  let r = c.query(%*[["SELECT id, lease_attempt FROM runs WHERE state IN (?, ?) AND (lease_until = 0 OR lease_until < ?) AND profile_id = ? " &
    (if versions.len > 0: "AND api_version IN (" & sqlVersionList(versions) & ") " else: "") & "AND (dirty = 1 OR id NOT IN " &
    "(SELECT run_id FROM steps WHERE state IN (?, ?, ?))) AND id NOT IN (SELECT run_id FROM lock_waiters) ORDER BY (lease_attempt > 0) DESC, created_at LIMIT ?",
    protoName(rsQueued), protoName(rsRunning), getTime().toUnix(), profileId, protoName(ssPending), protoName(ssStarting), protoName(ssRunning), places]])
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

proc cancelStepByDecision*(c: var RqClient; runId: string; ordinal: int; by: string): bool =
  ## fail_fast: the step is ABORTED (a step that waits is never handed out, one that runs is told to stop) and its record in the journal, `~canceled:<by>`, is the answer the script
  ## gets. One transaction with the record: if the step has a record already (it ended) nothing is done and false is returned.
  let pl = c.query(%*[["SELECT j.key || char(9) || s.image || char(9) || s.profile || char(9) || s.opts || char(9) || s.command " &
    "FROM steps s JOIN jobs j ON j.id = s.job_id WHERE s.run_id = ? AND s.ordinal = ?", runId, ordinal]])["results"][0]{"values"}
  if pl == nil or pl.len == 0: return false
  let now = $getTime().toUnix()
  try:
    c.appendRow(runId, stepJournalKey(c, runId, ordinal), "job_sh", pl[0][0].getStr, "~canceled:" & by, alongside = %*[
      ["UPDATE steps SET state = ?, finished_at = ?, version = version + 1 WHERE run_id = ? AND ordinal = ? AND state IN (?, ?, ?)",
       protoName(ssAborted), now, runId, ordinal, protoName(ssPending), protoName(ssStarting), protoName(ssRunning)]])
  except RqError as e:
    stderr.writeLine "core: could not cancel step " & runId & "/" & $ordinal & ": " & e.msg
    false

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
    if req.key.len == 0:
      return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
        kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: "a host call without its key in the journal")))
    c.storeEffectiveParams(req.run_id, json)
    # a call that answers at once has no step to write its journal entry later: core writes it (the replay of a restarted executor finds it there)
    discard c.appendRow(req.run_id, req.key, "params", json, "")
    return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
      kind: ExecutorResponseBodyKind.result, result: HostResult(seq: req.seq, suspended: false)))
  if req.kind == "par_cancel":
    # The decision of `fail_fast` (docs/parallel.md section 6): a branch of a ci.parallel failed, the steps of the branches still running are cancelled. Each cancelled step is answered in the
    # journal at once (`~canceled:<path of the ci.parallel>`), so the answer is the same in every replay whatever the Pod does meanwhile; a step that has ended already has its record and is
    # left as it is. The decision itself is written under its key; its result is the branches that were not started, which a replay must not start. The Pods are removed by the
    # controllers (a step that is ABORTED is not wanted, as in `abortRun`).
    if req.key.len == 0:
      return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
        kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: "a host call without its key in the journal")))
    let text = cast[string](req.payload)
    var by = ""
    var unstarted: seq[string]
    var keys: seq[string]
    try:
      let d = parseJson(text)
      by = d{"by"}.getStr
      if d{"unstarted"} != nil and d{"unstarted"}.kind == JArray:
        for u in d{"unstarted"}.elems: unstarted.add u.getStr
      if d{"steps"} != nil and d{"steps"}.kind == JArray:
        for k in d{"steps"}.elems: keys.add k.getStr
    except CatchableError:
      return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
        kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: "the decision of fail_fast is not understood")))
    for k in keys:
      if k.len < 2 or k[0] != 's' or by.len == 0: continue
      var digits = ""
      for ch in k[1 .. ^1]:
        if ch notin {'0' .. '9'}: break
        digits.add ch
      if digits.len > 0: discard c.cancelStepByDecision(req.run_id, parseInt(digits), by)
    let outcome = "u:" & unstarted.join("\t")
    discard c.appendRow(req.run_id, req.key, "par_cancel", text, outcome)
    kickProfile(profileOfRun(c, req.run_id, co.profileId))        # the controllers hear of the cancelled steps now
    return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
      kind: ExecutorResponseBodyKind.result, result: HostResult(seq: req.seq, result: cast[seq[byte]](outcome), suspended: false)))
  if req.kind == "park":
    # every branch of the run waits for something: the lease goes back, and the run is leased again when a step of it has ended (`dirty`) or none is in flight
    giveBackLease(c, req.run_id, caller.attempt)
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
  if req.kind == lockKind or req.kind == unlockKind:
    # PIP-014: the lock of a job (core/joblocks.nim). `lock` answers at once when the lock is the run's, and suspends the run (no place, no Pod) when it is not; the record
    # of the call is written when the lock is granted. `unlock` lets go of one level and answers at once.
    let payloadParts = cast[string](req.payload).split('\t', 1)         # `lock`: the name and the job (its key in the run); `unlock`: the name
    let name = payloadParts[0]
    let jobKey = if payloadParts.len > 1: payloadParts[1] else: ""
    let bad = if req.key.len == 0: "a host call without its key in the journal" elif not validLockName(name): "a lock is a name of 1 to " & $maxLockName & " letters, digits and . _ : -" else: ""
    if bad.len > 0:
      return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
        kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: bad)))
    let lockProfile = profileOfRun(c, req.run_id, co.profileId)
    let nowL = getTime().toUnix()
    if req.kind == lockKind:
      if not c.acquire(req.run_id, lockProfile, name, req.key, cast[string](req.payload), nowL, jobKey):
        # pending: the executor gives the lease back (`park`) when no branch can go on
        return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
          kind: ExecutorResponseBodyKind.result, result: HostResult(seq: req.seq, suspended: true)))
    else:
      c.release(req.run_id, lockProfile, name, nowL)
      discard c.appendRow(req.run_id, req.key, unlockKind, name, "")
    return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
      kind: ExecutorResponseBodyKind.result, result: HostResult(seq: req.seq, suspended: false)))
  if req.kind != "job_sh":
    return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
      kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: "unknown host call " & req.kind)))
  if not req.numbered:
    return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(kind: ExecutorResponseBodyKind.failure,
      failure: Failure(code: "executor_too_old", detail: "the step has no number from a table of step numbers; rebuild the executor")))
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
    # D-86: a pipeline may use a privileged profile only if its project allows it, and deploy only on a protected ref
    let rr = c.query(%*[["SELECT group_id, trusted FROM runs WHERE id = ?", req.run_id]])["results"][0]{"values"}
    if rr != nil and rr.len > 0:
      let why = c.profileProblem(rr[0][0].getStr, profile, rr[0][1].getInt > 0)
      if why.len > 0: return fail(why)
  if (hasArtifacts(opts) or cacheDecls(opts).len > 0) and not storesReady():
    return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
      kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error",
        detail: "the step declares artifacts or a cache, and this shard has no object store (the storage module, docs/storage-module.md)")))
  let badCache = checkCacheDecl(opts)
  if badCache.len > 0:
    return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
      kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: badCache)))
  let badEnv = checkEnv(opts)
  if badEnv.len > 0:
    return ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
      kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: badEnv)))
  let wantedSecrets = secretNamesOf(opts)
  if wantedSecrets.len > 0:
    # the step asks for secrets of the organisation (6.7): they must exist now, and the run must belong to an organisation
    let fail = proc (detail: string): ExecutorResponse =
      ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
        kind: ExecutorResponseBodyKind.failure, failure: Failure(code: "script_error", detail: detail)))
    if wantedSecrets.len > maxSecretsPerStep: return fail("a step may ask for at most " & $maxSecretsPerStep & " secrets")
    let o = c.query(%*[["SELECT tenant_id, group_id, trusted FROM runs r WHERE r.id = ? AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = r.tenant_id)", req.run_id]])
    let ov = o["results"][0]{"values"}
    if ov == nil or ov.len == 0: return fail("secrets need a run that belongs to an organisation")
    # D-86: the secrets of the project, of the groups above it and of the organisation, the nearest by name; a protected one only for a run on a protected ref
    let missing = missingSecrets(c.visibleSecrets(ov[0][0].getStr, ov[0][1].getStr), wantedSecrets, trusted = ov[0][2].getInt > 0)
    if missing.len > 0: return fail("this run has no secret " & missing.join(", ") & ": it is not set for the project, the groups above it or the organisation (PUT /api/v1/organizations/{slug}/secrets/{NAME}, or .../projects/{path}/secrets/{NAME}), or it is protected and the run is not on a protected ref")
  try:
    discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, ?, ?, ?)",
      schema.newId(), req.run_id, jobKey, protoName(ssRunning), profileId]])
  except RqError:
    discard   # already exists (a later step of the same job): fine, jobs.key is unique per (run_id, key, attempt)
  let jr = c.query(%*[["SELECT id FROM jobs WHERE run_id = ? AND key = ?", req.run_id, jobKey]])
  let jobId = jr["results"][0]{"values"}[0][0].getStr
  # OR IGNORE: the same call twice (two executors met the same run during a rollout, or one asked again after a lost answer) is one step, not a crash of the core
  # the number of the step is the one the executor gave it from its table; its record in the journal is found by the key `s<number>`
  let number = int(req.step_no)
  discard c.execute(%*[["INSERT OR IGNORE INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, profile, queued_at) " &
    "VALUES (?, ?, ?, ?, 'sh', ?, ?, ?, ?, ?, ?, ?)",
    schema.newId(), req.run_id, jobId, number, protoName(ssPending), profileId, image, cmd, opts, profile, now]])
  kickProfile(profileId)       # the push channel hands it to the organisation's controller at once
  # pending (`suspended`): the step waits or runs. The lease stays with the executor, which goes on with its other branches and gives it back with `park` when none can
  # (docs/parallel.md section 6); the end of the step marks the run dirty, and the run is leased again.
  ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(
    kind: ExecutorResponseBodyKind.result, result: HostResult(seq: req.seq, suspended: true)))

proc handleFinish*(c: var RqClient; req: FinishRun; master: string): ExecutorResponse =
  let caller = checkCaller(c, master, req.run_id, req.lease_token)
  if not caller.ok: return leaseLost(caller.why)
  let now = $getTime().toUnix()
  # why a run did not succeed is kept with it (the API shows it as `failure`): the script's error, the parameter that was refused, the limit
  discard c.execute(%*[["UPDATE runs SET state = ?, updated_at = ?, version = version + 1, fail_code = ?, fail_message = ? WHERE id = ?",
    protoName(case req.state
              of RUN_STATE_OK: rsOk
              of RUN_STATE_FAILED: rsFailed
              else: rsInfrastructureError), now,
    (if req.state == RUN_STATE_OK: "" else: req.code[0 ..< min(req.code.len, 64)]),
    (if req.state == RUN_STATE_OK: "" else: req.message[0 ..< min(req.message.len, maxFailMessage)]), req.run_id]])
  giveBackLease(c, req.run_id, caller.attempt)
  c.releaseRun(req.run_id, getTime().toUnix())          # a run that has ended holds no lock of a job (core/joblocks.nim)
  ExecutorResponse(header: Header(protocol: 1), body: ExecutorResponseBody(kind: ExecutorResponseBodyKind.result,
    result: HostResult(suspended: false)))

