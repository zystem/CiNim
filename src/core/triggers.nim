## Triggers (spec 6.3, TRG-001..TRG-004): a stored way to start a run of an organisation, so that nobody has to POST the script each time.
##
##   schedule  the clock: a cron expression in UTC (common/cron.nim). Core looks every 20 seconds; a firing is claimed with a compare-and-swap on
##             `last_fired_at`, so it starts one run even if two cores look at the same time, and a core that was down fires once when it is up again.
##   webhook   a call to `POST /api/v1/hooks/{id}` with the trigger's own secret as the bearer token (shown once, only its SHA-256 is kept). The secret
##             can start this trigger's run and nothing else: it is no API token. The call may carry `{"params": {...}}`, checked as launch parameters.
##   manual    `POST /api/v1/organizations/{slug}/triggers/{id}:fire` by an administrator, for any trigger (and for trying one out).
##
## A trigger keeps the project, the pipeline script and the launch parameters of the runs it starts (until pipelines are read from repositories,
## PRJ-003, the script lives here). `concurrency` is `allow` (every firing starts a run) or `skip` (a firing is skipped while an earlier run of the same
## trigger is still running: the usual answer to a push storm or a slow nightly). A run started by a trigger carries `trigger_id`.
import std/[json, strutils, times, atomics, os, tables]
import ../common/[rqlite, states, cron, ctrlauth]
import schema, scheduler, runparams, orgrules, apiauth

const
  maxScriptBytes* = 256 * 1024
  maxTriggersPerOrg* = 200
  loopEverySeconds = 20

type
  TriggerSpec* = object
    name*, kind*, schedule*, projectId*, script*, concurrency*: string
    params*: seq[(string, string)]
    enabled*: bool

  TriggerRow* = object
    id*, tenantId*, slug*, name*, kind*, schedule*, secretHash*, projectId*, script*, concurrency*, lastRunId*, lastResult*: string
    params*: seq[(string, string)]
    enabled*: bool
    createdAt*, lastFiredAt*: int64

  Fired* = object
    started*: bool
    runId*, reason*: string      ## when not started: why (`disabled`, `organization_disabled`, `still_running`)

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
  str("project_id", result.spec.projectId)
  str("script", result.spec.script)
  str("schedule", result.spec.schedule, required = false)
  result.spec.concurrency = "allow"
  str("concurrency", result.spec.concurrency, required = false)
  result.spec.enabled = true
  if j.hasKey("enabled"):
    if j["enabled"].kind != JBool: return ("enabled must be a boolean", result.spec)
    result.spec.enabled = j["enabled"].getBool
  if not validTriggerName(result.spec.name):
    return ("name is 1..64 characters: lowercase letters, digits, - _ .", result.spec)
  if result.spec.kind notin ["schedule", "webhook"]: return ("kind is schedule or webhook (a manual start is the :fire call on either)", result.spec)
  if result.spec.concurrency notin ["allow", "skip"]: return ("concurrency is allow or skip", result.spec)
  if result.spec.projectId.len == 0 or result.spec.projectId.len > 128: return ("project_id is 1..128 characters", result.spec)
  if result.spec.script.len == 0: return ("script is empty", result.spec)
  if result.spec.script.len > maxScriptBytes: return ("script is longer than " & $maxScriptBytes & " bytes", result.spec)
  if result.spec.kind == "schedule":
    let c = parseCron(result.spec.schedule)
    if not c.ok: return ("schedule: " & c.error, result.spec)
  elif result.spec.schedule.len > 0: return ("only a schedule trigger has a schedule", result.spec)
  let p = checkParams(j{"params"})
  if p.error.len > 0: return ("params: " & p.error, result.spec)
  result.spec.params = p.pairs

# ------------------------------------------------------------------ the rows

const columns = "t.id, t.tenant_id, o.slug, t.name, t.kind, t.schedule, t.secret_hash, t.project_id, t.script, t.concurrency, t.last_run_id, " &
                "t.last_result, t.params, t.enabled, t.created_at, t.last_fired_at"

proc rowOf(v: JsonNode): TriggerRow =
  TriggerRow(id: v[0].getStr, tenantId: v[1].getStr, slug: v[2].getStr, name: v[3].getStr, kind: v[4].getStr, schedule: v[5].getStr,
             secretHash: v[6].getStr, projectId: v[7].getStr, script: v[8].getStr, concurrency: v[9].getStr, lastRunId: v[10].getStr,
             lastResult: v[11].getStr, params: fromJson(v[12].getStr), enabled: v[13].getInt > 0, createdAt: v[14].getBiggestInt,
             lastFiredAt: v[15].getBiggestInt)

proc view*(t: TriggerRow): JsonNode =
  ## what the API shows; never the secret or its hash
  result = %*{"id": t.id, "organization": t.slug, "name": t.name, "kind": t.kind, "project_id": t.projectId, "concurrency": t.concurrency,
              "enabled": t.enabled, "created_at": t.createdAt, "last_fired_at": t.lastFiredAt, "script_bytes": t.script.len}
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

proc nameTaken*(c: var RqClient; tenantId, name: string): bool =
  c.query(%*[["SELECT count(*) FROM triggers WHERE tenant_id = ? AND name = ?", tenantId, name]])["results"][0]{"values"}[0][0].getInt > 0

proc createTrigger*(c: var RqClient; tenantId: string; s: TriggerSpec; now: int64): tuple[id, secret: string] =
  ## `secret` is the webhook's secret, shown once ("" for a schedule)
  result.id = newId()
  var hash = ""
  if s.kind == "webhook":
    result.secret = mintToken().secret
    hash = secretHash(result.secret)
  discard c.execute(%*[["INSERT INTO triggers (id, tenant_id, name, kind, schedule, secret_hash, project_id, script, params, concurrency, enabled, created_at, last_fired_at) " &
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", result.id, tenantId, s.name, s.kind, s.schedule, hash, s.projectId, s.script,
    (if s.params.len > 0: toJson(s.params) else: ""), s.concurrency, (if s.enabled: 1 else: 0), now, now]])

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

proc stillRunning(c: var RqClient; triggerId: string): bool =
  c.query(%*[["SELECT count(*) FROM runs WHERE trigger_id = ? AND state = ?", triggerId, protoName(rsRunning)]])["results"][0]{"values"}[0][0].getInt > 0

proc fire*(co: Core; t: TriggerRow; extra: seq[(string, string)]; now: int64; byClock = false): Fired =
  ## Starts the trigger's run (or says why not). `extra` are launch parameters of this call; they replace the trigger's own of the same name.
  var c = newRq(co.rqliteUrl)
  let org = c.query(%*[["SELECT state FROM organizations WHERE id = ?", t.tenantId]])["results"][0]{"values"}
  if org == nil or org.len == 0 or org[0][0].getStr != "active":
    return Fired(reason: "organization_disabled")
  if not t.enabled and byClock: return Fired(reason: "disabled")
  # a manual start of a schedule does not move its clock
  let clock = if byClock or t.kind != "schedule": now else: t.lastFiredAt
  if t.concurrency == "skip" and c.stillRunning(t.id):
    discard c.execute(%*[["UPDATE triggers SET last_fired_at = ?, last_result = ? WHERE id = ?", clock, "skipped: the previous run is still running", t.id]])
    return Fired(reason: "still_running")
  var params = initOrderedTable[string, string]()
  for (k, v) in t.params: params[k] = v
  for (k, v) in extra: params[k] = v
  var pairs: seq[(string, string)]
  for k, v in params: pairs.add (k, v)
  let profile = c.ensureOrganizationProfile(t.tenantId, namespaceName(co.orgPrefix, co.orgShard, t.slug))
  let id = co.createRun(t.projectId, t.script, t.tenantId, profile, pairs, t.id)
  discard c.execute(%*[["UPDATE triggers SET last_fired_at = ?, last_run_id = ?, last_result = 'started' WHERE id = ?", clock, id, t.id]])
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
    let f = co.fire(again, @[], due, byClock = true)
    if f.started:
      inc result
      echo "core: trigger ", t.name, " (", t.slug, ") started run ", f.runId

proc runTriggerLoop*(a: tuple[co: Core, stop: ptr Atomic[bool]]) {.thread.} =
  {.cast(gcsafe).}:
    while not a.stop[].load:
      try: discard fireSchedules(a.co, getTime().toUnix())
      except CatchableError as e: stderr.writeLine "core: triggers: " & e.msg
      for _ in 0 ..< loopEverySeconds * 10:
        if a.stop[].load: break
        sleep 100
