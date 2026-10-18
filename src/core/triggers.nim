## Triggers (spec 6.3, TRG-001..TRG-004): a stored way to start a run of an organisation, so that nobody has to POST the script each time.
##
##   schedule  the clock: a cron expression in UTC (common/cron.nim). Core looks every 20 seconds; a firing is claimed with a compare-and-swap on
##             `last_fired_at`, so it starts one run even if two cores look at the same time, and a core that was down fires once when it is up again.
##   webhook   a call to `POST /api/v1/hooks/{id}` with the trigger's own secret as the bearer token (shown once, only its SHA-256 is kept). The secret
##             can start this trigger's run and nothing else: it is no API token. The call may carry `{"params": {...}}`, checked as launch parameters.
##   manual    `POST /api/v1/organizations/{slug}/triggers/{id}:fire` by an administrator, for any trigger (and for trying one out).
##
## A trigger keeps the group, the pipeline script and the launch parameters of the runs it starts (until pipelines are read from repositories,
## PRJ-003, the script lives here). `concurrency` is `parallel` (every firing starts a run at once; when the organisation has no room, the run waits for it, which is the queue), `cancel_newest` (the new firing is cancelled - no run is started - while an earlier run of the same
## trigger has not ended - any run that is not in a final state, not only a RUNNING one: the usual answer to a slow nightly, and "never start a new one while the old one works")
## or `cancel_previous` (the earlier runs of the trigger that have not ended are cancelled, RUN-006, and the new one is started: the usual answer to a push storm, where
## only the newest commit matters). A run started by a trigger carries `trigger_id`.
import std/[json, strutils, times, atomics, os, tables]
import health
import ../common/[rqlite, states, cron, ctrlauth, luaapi]
import schema, scheduler, runparams, orgrules, apiauth, groups, preflight
from ../common/scriptsource import Source, defaultPath, validRepository, validRef, validPath

const
  maxScriptBytes* = 256 * 1024
  maxTriggersPerOrg* = 200
  loopEverySeconds = 20

type
  TriggerSpec* = object
    name*, kind*, schedule*, groupPath*, script*, concurrency*: string        ## groupPath: the group the runs belong to ("" = the organisation)
    repository*, ref0*, scriptPath*: string   ## D-63: instead of `script`, a repository (https), the commit / branch / tag a firing runs when the call names none ("" = HEAD), and the path of the script in it
    params*: seq[(string, string)]
    enabled*: bool

  TriggerRow* = object
    id*, tenantId*, slug*, name*, kind*, schedule*, secretHash*, groupId*, groupPath*, script*, concurrency*, lastRunId*, lastResult*: string
    repository*, ref0*, scriptPath*: string
    params*: seq[(string, string)]
    enabled*: bool
    createdAt*, lastFiredAt*: int64

  Fired* = object
    started*: bool
    runId*, reason*: string      ## when not started: why (`disabled`, `organization_disabled`, `still_running`, or a code of the script that could not be read from the repository)
    status*: int                 ## the HTTP status to answer with when it is not 409 (0 = the usual)
    detail*: string

func validTriggerName*(n: string): bool =
  if n.len < 1 or n.len > 64: return false
  for ch in n:
    if ch notin {'a' .. 'z', '0' .. '9', '-', '_', '.'}: return false
  true

proc parseTriggerSpec*(j: JsonNode): tuple[error: string, spec: TriggerSpec] =
  ## the body of the creation call; "" if it describes a trigger
  if j == nil or j.kind != JObject: return ("the body is a JSON object", result.spec)
  template str(key: string; into: untyped; required = true) =
    if j.hasKey(key):
      if j[key].kind != JString: return (key & " must be a string", result.spec)
      into = j[key].getStr
    elif required: return (key & " is required", result.spec)
  str("name", result.spec.name)
  str("kind", result.spec.kind)
  str("group", result.spec.groupPath, required = false)
  str("script", result.spec.script, required = false)
  str("repository", result.spec.repository, required = false)
  str("ref", result.spec.ref0, required = false)
  str("path", result.spec.scriptPath, required = false)
  str("schedule", result.spec.schedule, required = false)
  result.spec.concurrency = "parallel"
  str("concurrency", result.spec.concurrency, required = false)
  result.spec.enabled = true
  if j.hasKey("enabled"):
    if j["enabled"].kind != JBool: return ("enabled must be a boolean", result.spec)
    result.spec.enabled = j["enabled"].getBool
  if not validTriggerName(result.spec.name):
    return ("name is 1..64 characters: lowercase letters, digits, - _ .", result.spec)
  if result.spec.kind notin ["schedule", "webhook"]: return ("kind is schedule or webhook (a manual start is the :fire call on either)", result.spec)
  if result.spec.concurrency notin ["parallel", "cancel_newest", "cancel_previous"]: return ("concurrency is parallel, cancel_newest or cancel_previous", result.spec)
  result.spec.groupPath = normalPath(result.spec.groupPath)
  if result.spec.groupPath.len > 400: return ("group is too long", result.spec)
  if result.spec.repository.len > 0:
    # D-63: the script is read from the repository at every firing
    if result.spec.script.len > 0: return ("give the script or the repository it is read from, not both", result.spec)
    if not validRepository(result.spec.repository): return ("repository must be an https:// or http:// URL", result.spec)
    if result.spec.ref0.len > 0 and not validRef(result.spec.ref0): return ("ref is a branch or a tag name (or a SHA)", result.spec)
    if result.spec.scriptPath.len > 0 and not validPath(result.spec.scriptPath): return ("path is a relative path inside the repository", result.spec)
  else:
    if result.spec.ref0.len > 0 or result.spec.scriptPath.len > 0: return ("ref and path belong to a trigger with a repository", result.spec)
    if result.spec.script.len == 0: return ("script (or repository) is required", result.spec)
    if result.spec.script.len > maxScriptBytes: return ("script is longer than " & $maxScriptBytes & " bytes", result.spec)
  if result.spec.kind == "schedule":
    let c = parseCron(result.spec.schedule)
    if not c.ok: return ("schedule: " & c.error, result.spec)
  elif result.spec.schedule.len > 0: return ("only a schedule trigger has a schedule", result.spec)
  let p = checkParams(j{"params"})
  if p.error.len > 0: return ("params: " & p.error, result.spec)
  result.spec.params = p.pairs

# ------------------------------------------------------------------ the rows

const columns = "t.id, t.tenant_id, o.slug, t.name, t.kind, t.schedule, t.secret_hash, t.group_id, t.script, t.concurrency, t.last_run_id, " &
                "t.last_result, t.params, t.enabled, t.created_at, t.last_fired_at, COALESCE((SELECT g.path FROM groups g WHERE g.id = t.group_id), ''), " &
                "t.repository, t.ref, t.script_path"

proc rowOf(v: JsonNode): TriggerRow =
  TriggerRow(id: v[0].getStr, tenantId: v[1].getStr, slug: v[2].getStr, name: v[3].getStr, kind: v[4].getStr, schedule: v[5].getStr,
             secretHash: v[6].getStr, groupId: v[7].getStr, groupPath: v[16].getStr, script: v[8].getStr, concurrency: v[9].getStr, lastRunId: v[10].getStr,
             lastResult: v[11].getStr, params: fromJson(v[12].getStr), enabled: v[13].getInt > 0, createdAt: v[14].getBiggestInt,
             lastFiredAt: v[15].getBiggestInt, repository: v[17].getStr, ref0: v[18].getStr, scriptPath: v[19].getStr)

proc view*(t: TriggerRow): JsonNode =
  ## what the API shows; never the secret or its hash
  result = %*{"id": t.id, "organization": t.slug, "name": t.name, "kind": t.kind, "group": t.groupPath, "concurrency": t.concurrency,
              "enabled": t.enabled, "created_at": t.createdAt, "last_fired_at": t.lastFiredAt, "script_bytes": t.script.len}
  if t.repository.len > 0: result["source"] = %*{"repository": t.repository, "ref": t.ref0, "path": (if t.scriptPath.len > 0: t.scriptPath else: defaultPath)}
  if t.kind == "schedule": result["schedule"] = %t.schedule
  if t.kind == "webhook": result["hook"] = %("/api/v1/hooks/" & t.id)
  if t.params.len > 0: result["params"] = parseJson(toJson(t.params))
  if t.lastRunId.len > 0: result["last_run_id"] = %t.lastRunId
  if t.lastResult.len > 0: result["last_result"] = %t.lastResult

proc selectTriggers(c: var RqClient; where: string; args: seq[JsonNode]): seq[TriggerRow] =
  var stmt = %*["SELECT " & columns & " FROM triggers t JOIN organizations o ON o.id = t.tenant_id " & where]
  for a in args: stmt.add a
  let r = c.query(%*[stmt])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add rowOf(v)

proc listTriggers*(c: var RqClient; tenantId: string): seq[TriggerRow] =
  c.selectTriggers("WHERE t.tenant_id = ? ORDER BY t.name", @[%tenantId])

proc getTrigger*(c: var RqClient; tenantId, id: string): tuple[found: bool, row: TriggerRow] =
  let l = c.selectTriggers("WHERE t.tenant_id = ? AND t.id = ?", @[%tenantId, %id])
  if l.len > 0: (true, l[0]) else: (false, TriggerRow())

proc getTriggerById*(c: var RqClient; id: string): tuple[found: bool, row: TriggerRow] =
  let l = c.selectTriggers("WHERE t.id = ?", @[%id])
  if l.len > 0: (true, l[0]) else: (false, TriggerRow())

proc countTriggers*(c: var RqClient; tenantId: string): int =
  c.query(%*[["SELECT count(*) FROM triggers WHERE tenant_id = ?", tenantId]])["results"][0]{"values"}[0][0].getInt

proc hookCommit*(body: JsonNode; t: TriggerRow): tuple[error, commit: string] =
  ## What a webhook call may say (D-63): the commit to run, and the repository only if it is the trigger's own. It carries no launch parameters, and a commit means something only to a trigger that
  ## has a repository. `error` is the 400's words.
  if body == nil or body.kind != JObject: return ("the body is empty or {\"commit\": \"...\"}", "")
  if body.hasKey("params"):
    return ("a webhook carries no params; the parameters of the trigger are used. Name the commit: {\"commit\": \"...\"}", "")
  for k in ["commit", "repository"]:
    if body.hasKey(k) and body[k].kind != JString: return (k & " must be text", "")
  if body.hasKey("repository") and body["repository"].getStr != t.repository:
    return ("repository is not this trigger's repository: a webhook cannot point the trigger elsewhere", "")
  let wanted = body{"commit"}.getStr
  if wanted.len > 0 and t.repository.len == 0: return ("this trigger has a script of its own, not a repository: there is no commit to name", "")
  if wanted.len > 0 and not validRef(wanted): return ("commit is a SHA, a branch or a tag name", "")
  ("", wanted)

proc nameTaken*(c: var RqClient; tenantId, name: string): bool =
  c.query(%*[["SELECT count(*) FROM triggers WHERE tenant_id = ? AND name = ?", tenantId, name]])["results"][0]{"values"}[0][0].getInt > 0

proc createTrigger*(c: var RqClient; tenantId: string; s: TriggerSpec; now: int64; groupId = ""): tuple[id, secret: string] =
  ## `secret` is the webhook's secret, shown once ("" for a schedule); `groupId` is the id of the group named by `s.groupPath` ("" = the organisation), which the caller has looked up
  result.id = newId()
  var hash = ""
  if s.kind == "webhook":
    result.secret = mintToken().secret
    hash = secretHash(result.secret)
  discard c.execute(%*[["INSERT INTO triggers (id, tenant_id, name, kind, schedule, secret_hash, group_id, script, params, concurrency, enabled, created_at, last_fired_at, repository, ref, script_path) " &
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", result.id, tenantId, s.name, s.kind, s.schedule, hash, groupId, s.script,
    (if s.params.len > 0: toJson(s.params) else: ""), s.concurrency, (if s.enabled: 1 else: 0), now, now, s.repository, s.ref0, s.scriptPath]])

proc deleteTrigger*(c: var RqClient; tenantId, id: string): bool =
  c.execute(%*[["DELETE FROM triggers WHERE tenant_id = ? AND id = ?", tenantId, id]])["results"][0]{"rows_affected"}.getInt > 0

proc setEnabled*(c: var RqClient; tenantId, id: string; on: bool; now: int64): bool =
  ## switching a schedule on does not fire what was missed while it was off: the clock starts from now
  c.execute(%*[["UPDATE triggers SET enabled = ?, last_fired_at = CASE WHEN ? = 1 AND enabled = 0 THEN ? ELSE last_fired_at END WHERE tenant_id = ? AND id = ?",
                (if on: 1 else: 0), (if on: 1 else: 0), now, tenantId, id]])["results"][0]{"rows_affected"}.getInt > 0

proc rotateHookSecret*(c: var RqClient; tenantId, id: string): string =
  ## a new secret for a webhook, the old one stops working at once; "" if there is no such webhook
  let t = mintToken().secret
  let r = c.execute(%*[["UPDATE triggers SET secret_hash = ? WHERE tenant_id = ? AND id = ? AND kind = 'webhook'", secretHash(t), tenantId, id]])
  if r["results"][0]{"rows_affected"}.getInt > 0: t else: ""

proc authenticateHook*(c: var RqClient; id, bearer: string): tuple[ok: bool, row: TriggerRow] =
  ## the trigger a webhook call is for, if the secret is its own. An unknown id and a wrong secret look the same to the caller.
  let t = c.getTriggerById(id)
  if bearer.len == 0 or not t.found or t.row.kind != "webhook": return
  if not constantTimeEqual(secretHash(bearer), t.row.secretHash): return
  (true, t.row)

# ------------------------------------------------------------------ firing

const finalRunStates = [rsSucceeded, rsFailed, rsCanceled, rsSkipped, rsTimedOut, rsInfrastructureError]

proc unfinishedRuns(c: var RqClient; triggerId: string): seq[string] =
  ## the runs of the trigger that have not reached a final state (created, queued, running, waiting): they are what `cancel_newest` waits for and `cancel_previous` cancels
  var stmt = %*["SELECT id FROM runs WHERE trigger_id = ? AND state NOT IN (" & "?,".repeat(finalRunStates.len - 1) & "?) ORDER BY created_at", triggerId]
  for s in finalRunStates: stmt.add %protoName(s)
  let vals = c.query(%*[stmt])["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add v[0].getStr

proc stillRunning(c: var RqClient; triggerId: string): bool = c.unfinishedRuns(triggerId).len > 0

proc fire*(co: Core; t: TriggerRow; extra: seq[(string, string)]; now: int64; byClock = false; commit = ""): Fired =
  ## Starts the trigger's run (or says why not). `extra` are launch parameters of this call; they replace the trigger's own of the same name. `commit` (a webhook's, D-63) is the commit of a trigger
  ## that reads its script from a repository; without one the trigger's `ref` is run.
  var c = newRq(co.rqliteUrl)
  let org = c.query(%*[["SELECT state FROM organizations WHERE id = ?", t.tenantId]])["results"][0]{"values"}
  if org == nil or org.len == 0 or org[0][0].getStr != "active":
    return Fired(reason: "organization_disabled")
  if not t.enabled and byClock: return Fired(reason: "disabled")
  # a manual start of a schedule does not move its clock
  let clock = if byClock or t.kind != "schedule": now else: t.lastFiredAt
  if t.concurrency == "cancel_newest" and c.stillRunning(t.id):
    discard c.execute(%*[["UPDATE triggers SET last_fired_at = ?, last_result = ? WHERE id = ?", clock, "cancelled the new firing: the previous run has not ended", t.id]])
    return Fired(reason: "still_running")
  var params = initOrderedTable[string, string]()
  for (k, v) in t.params: params[k] = v
  for (k, v) in extra: params[k] = v
  var pairs: seq[(string, string)]
  for k, v in params: pairs.add (k, v)
  # the script is had before anything is cancelled: a firing that cannot read its repository must not stop the runs that are going
  var script = t.script
  var source = Source()
  if t.repository.len > 0:
    # D-63: a conductor of the organisation reads the script at the commit; a run that cannot be had is told in the trigger's last result
    let ask = Source(repository: t.repository, commit: (if commit.len > 0: commit else: t.ref0), path: t.scriptPath)
    let ans = checkSource(namespaceName(co.orgPrefix, co.orgShard, t.slug), ask, pairs, currentApiVersion)
    let fp = ans.fetchProblem
    if fp.status != 0 and ans.script.len == 0:
      discard c.execute(%*[["UPDATE triggers SET last_fired_at = ?, last_result = ? WHERE id = ?", clock, "not started: " & fp.message, t.id]])
      return Fired(reason: fp.code, status: fp.status, detail: fp.message)
    if ans.problemOf.len > 0:
      discard c.execute(%*[["UPDATE triggers SET last_fired_at = ?, last_result = ? WHERE id = ?", clock, "not started: " & ans.message, t.id]])
      return Fired(reason: ans.code, status: 400, detail: ans.message)
    script = ans.script
    source = Source(repository: t.repository, commit: ans.commit, path: (if t.scriptPath.len > 0: t.scriptPath else: defaultPath))
  var cancelled: seq[string]
  if t.concurrency == "cancel_previous":
    # the newest commit is the one that matters: the runs of this trigger that have not ended are stopped first (their Pods are removed by the controllers)
    for old in c.unfinishedRuns(t.id):
      if c.cancelRun(old, now).outcome == coCanceled: cancelled.add old
  let profile = c.ensureOrganizationProfile(t.tenantId, namespaceName(co.orgPrefix, co.orgShard, t.slug))
  if c.queueIsFull(profile):
    discard c.execute(%*[["UPDATE triggers SET last_fired_at = ?, last_result = ? WHERE id = ?", clock, "not started: the organisation has " & $maxUnfinishedRuns & " runs that have not ended", t.id]])
    return Fired(reason: "queue_full")
  let id = co.createRun(script, t.tenantId, profile, pairs, t.id, t.groupId, source)
  let result = if cancelled.len == 0: "started" else: "started; cancelled the earlier run" & (if cancelled.len > 1: "s " else: " ") & cancelled.join(", ")
  discard c.execute(%*[["UPDATE triggers SET last_fired_at = ?, last_run_id = ?, last_result = ? WHERE id = ?", clock, id, result, t.id]])
  Fired(started: true, runId: id)

proc fireSchedules*(co: Core; now: int64): int =
  ## One look at the clock: every enabled schedule that came due since its last firing starts one run. The claim of the firing is the compare-and-swap
  ## of `last_fired_at` from the value read to the minute that fired, so that a second core (or a second look) finds nothing to do.
  var c = newRq(co.rqliteUrl)
  for t in c.selectTriggers("WHERE t.kind = 'schedule' AND t.enabled = 1", @[]):
    let p = parseCron(t.schedule)
    if not p.ok: continue
    let due = p.cron.latestDue(t.lastFiredAt, now)
    if due == 0: continue
    let claim = c.execute(%*[["UPDATE triggers SET last_fired_at = ? WHERE id = ? AND last_fired_at = ?", due, t.id, t.lastFiredAt]])
    if claim["results"][0]{"rows_affected"}.getInt == 0: continue
    var again = t
    again.lastFiredAt = due
    beat(bTriggers)                              # a firing that reads its script from a repository can take a minute
    let f = co.fire(again, @[], due, byClock = true)
    if f.started:
      inc result
      echo "core: trigger ", t.name, " (", t.slug, ") started run ", f.runId

proc runTriggerLoop*(a: tuple[co: Core, stop: ptr Atomic[bool]]) {.thread.} =
  {.cast(gcsafe).}:
    while not a.stop[].load:
      beat(bTriggers)
      try: discard fireSchedules(a.co, getTime().toUnix())
      except CatchableError as e: stderr.writeLine "core: triggers: " & e.msg
      for _ in 0 ..< loopEverySeconds * 10:
        if a.stop[].load: break
        sleep 100
