## D-111: outbound webhooks. The platform tells an address what happens to the runs of an organisation or of a project: a run started, a step failed, a run finished. It is for a person or a tool that
## follows runs without asking for them again and again, and, in time, for the status of a build in a pull request (core/prstatus.nim, D-96, is the same thing made for the hosts of repositories).
##
## The core sends, in the shape of prstatus.nim, not a module of its own: a beat of the loop of the triggers looks at the runs of the webhooks and writes down, once, each event that has happened (a row of
## `webhook_deliveries`, which `(webhook, run, event, key)` makes unique, so that looking again writes nothing new), and sends the rows that are due. A refusal is tried again after a longer pause each time
## (`backoffSeconds`), at most `maxAttempts` times; a receiver that does not answer never holds a run, and a run does not wait for a delivery. The addresses are the ones the shard allows
## (`CINIM_WEBHOOK_HOSTS`: the core must not be made to call what is inside the cluster by whoever sets a webhook); a shard that lists none sends nothing. A webhook may name a secret of the organisation
## (the name only): the body is then signed with the value, `X-CiNim-Signature: sha256=<HMAC-SHA256 of the body>`, as GitHub signs its own.
import std/[json, strutils, uri, tables, times, os, httpclient, algorithm, sequtils]
import crunchy
import ../common/rqlite
import groups, schema, secretvault

const
  allEvents* = ["run.started", "step.failed", "run.finished"]
  maxAttempts* = 8                  ## a delivery is tried this many times, then left (it stays in the table for a person to see)
  maxWebhooksPerOrg* = 50
  maxUrlBytes = 400
  windowSeconds = 3'i64 * 86400     ## runs older than this are not looked at, and rows older than this that are done are removed

type
  WebhookSpec* = object
    name*, url*, secret*, groupPath*: string        ## groupPath: the project ("" = the whole organisation); secret: the NAME of a secret of the organisation
    events*: seq[string]
    enabled*: bool

  WebhookRow* = object
    id*, tenantId*, slug*, groupId*, groupPath*, name*, url*, secret*: string
    events*: seq[string]
    enabled*: bool
    createdAt*: int64

  RunFacts* = object
    id*, organization*, project*, state*, commit*, refName*, repository*, triggerId*, failCode*, failMessage*: string
    createdAt*: int64

  StepFacts* = object
    number*, attempt*, exitCode*: int
    termination*: string

# ------------------------------------------------------------------ the addresses

func allowedHosts*(): seq[string] =
  ## `CINIM_WEBHOOK_HOSTS`: hosts, or hosts with a port, separated by commas; nothing listed, nothing allowed
  for x in getEnv("CINIM_WEBHOOK_HOSTS").split(','):
    if x.strip.len > 0: result.add x.strip.toLowerAscii

proc urlAllowed*(url: string; allowed: openArray[string]): string =
  ## "" when `url` is an http(s) address whose host (and port, if the shard lists one) the shard allows; else why not
  if allowed.len == 0: return "the shard allows no address for webhooks: list the hosts in CINIM_WEBHOOK_HOSTS"
  if url.len == 0 or url.len > maxUrlBytes: return "url is an http or https address of at most " & $maxUrlBytes & " characters"
  for c in url:
    if c <= ' ' or c == '\x7f' or c in {'\\', '\'', '"', '`', '<', '>'}: return "url has a character that an address does not"
  let u = parseUri(url)
  let scheme = u.scheme.toLowerAscii
  if scheme notin ["http", "https"]: return "url is an http or https address"
  if u.username.len > 0 or u.password.len > 0: return "url has a login in it: the host would be hidden behind it; give the login another way"
  let host = u.hostname.toLowerAscii
  if host.len == 0: return "url has no host"
  let port = if u.port.len > 0: u.port else: (if scheme == "https": "443" else: "80")
  for a in allowed:
    if a == host or a == host & ":" & port: return ""
  "the shard does not allow " & host & ":" & port & " (it allows " & @allowed.join(", ") & ")"

# ------------------------------------------------------------------ what a webhook is

func validName(n: string): bool =
  if n.len < 1 or n.len > 64: return false
  for ch in n:
    if ch notin {'a' .. 'z', '0' .. '9', '-', '_', '.'}: return false
  true

func validSecretName(n: string): bool =
  n.len <= 100 and not n.contains({' ', '\n', '\t'})

proc checkEvents(j: JsonNode): tuple[error: string, events: seq[string]] =
  if j.kind != JArray or j.len == 0: return ("events is a list of at least one of " & @allEvents.join(", "), @[])
  for e in j:
    if e.kind != JString or e.getStr notin allEvents: return ("events has only " & @allEvents.join(", "), @[])
    if e.getStr notin result.events: result.events.add e.getStr

proc parseWebhookSpec*(j: JsonNode; allowed: openArray[string]; checkUrl = true): tuple[error: string, spec: WebhookSpec] =
  ## the body of the creation call: {"name", "url", "project"?, "secret"?, "events"?, "enabled"?}; "" if it describes a webhook
  if j == nil or j.kind != JObject: return ("the body is a JSON object", result.spec)
  for k, _ in j.pairs:
    if k notin ["name", "url", "project", "secret", "events", "enabled"]: return ("unknown field " & k & " (name, url, project, secret, events, enabled)", result.spec)
  for k in ["name", "url"]:
    if not j.hasKey(k) or j[k].kind != JString: return (k & " is required, a text", result.spec)
  result.spec.name = j["name"].getStr
  result.spec.url = j["url"].getStr
  if not validName(result.spec.name): return ("name is 1..64 characters: lowercase letters, digits, - _ .", result.spec)
  if j.hasKey("project"):
    if j["project"].kind != JString: return ("project is a text, the path of a project", result.spec)
    result.spec.groupPath = normalPath(j["project"].getStr)
    if result.spec.groupPath.len > 400: return ("project is too long", result.spec)
    for part in pathParts(result.spec.groupPath):
      if not validGroupSlug(part): return ("project is a path of names of groups (lowercase letters, digits and '-'): " & part, result.spec)
  if j.hasKey("secret"):
    if j["secret"].kind != JString or not validSecretName(j["secret"].getStr): return ("secret is the name of a secret of the organisation (no spaces)", result.spec)
    result.spec.secret = j["secret"].getStr
  result.spec.events = @allEvents
  if j.hasKey("events"):
    let e = checkEvents(j["events"])
    if e.error.len > 0: return (e.error, result.spec)
    result.spec.events = e.events
  result.spec.enabled = true
  if j.hasKey("enabled"):
    if j["enabled"].kind != JBool: return ("enabled must be a boolean", result.spec)
    result.spec.enabled = j["enabled"].getBool
  if checkUrl:
    let why = urlAllowed(result.spec.url, allowed)
    if why.len > 0: return (why, result.spec)

proc parseWebhookUpdate*(j: JsonNode; cur: WebhookRow; allowed: openArray[string]): tuple[error: string, spec: WebhookSpec] =
  ## The body of a change (`PATCH .../webhooks/{id}`): `url`, `secret` (the name; "" takes the signature off), `events`, `enabled`; the fields named replace the webhook's own and the result is checked as a
  ## webhook that is made. The name and the project are not changed (the deliveries written for a webhook belong to them). The address is looked at only when it is changed: a webhook whose address the
  ## shard has stopped allowing can still be switched off.
  if j == nil or j.kind != JObject: return ("the body is a JSON object", result.spec)
  for k, _ in j.pairs:
    if k in ["name", "project"]: return (k & " cannot be changed: make a new webhook (its deliveries belong to this one)", result.spec)
    if k notin ["url", "secret", "events", "enabled"]: return ("unknown field " & k & " (url, secret, events, enabled can be changed)", result.spec)
  if j.len == 0: return ("nothing to change: give url, secret, events or enabled", result.spec)
  var merged = %*{"name": cur.name, "url": cur.url, "events": cur.events, "enabled": cur.enabled}
  if cur.groupPath.len > 0: merged["project"] = %cur.groupPath
  if cur.secret.len > 0: merged["secret"] = %cur.secret
  for k, v in j.pairs: merged[k] = v
  if merged.hasKey("secret") and merged["secret"].kind == JString and merged["secret"].getStr == "": merged.delete("secret")
  parseWebhookSpec(merged, allowed, checkUrl = j.hasKey("url"))

func view*(w: WebhookRow): JsonNode =
  %*{"id": w.id, "organization": w.slug, "name": w.name, "url": w.url, "project": w.groupPath, "secret": w.secret, "events": w.events, "enabled": w.enabled, "created_at": w.createdAt}

# ------------------------------------------------------------------ the signature and the pauses

proc signature*(secret, body: string): string =
  ## `sha256=` and the HMAC-SHA256 of the body under the secret in lowercase hexadecimal, the form GitHub signs its own webhooks in
  const digits = "0123456789abcdef"
  result = "sha256="
  for b in hmacSha256(secret, body):
    result.add digits[int(b) shr 4]
    result.add digits[int(b) and 15]

func backoffSeconds*(attempts: int): int64 =
  ## the pause after the n-th refusal (0-based): 30 s, doubled each time, at most an hour
  min(30'i64 shl min(max(attempts, 0), 7), 3600'i64)

# ------------------------------------------------------------------ the events

const
  notStarted = ["CREATED", "COMPILING", "QUEUED", "WAITING"]
  finalStates = ["OK", "FAILED", "ABORTED", "TIMED_OUT", "INFRASTRUCTURE_ERROR", "SKIPPED"]

func hasStarted*(state: string): bool = state.len > 0 and state notin notStarted
func hasFinished*(state: string): bool = state in finalStates

func stepIds*(number: int): tuple[job, step: string] =
  ## the two ids of a step in the words of the log (D-77): the number is `job * 2^20 + step`, each in base 32 (the alphabet of the ids), 2 and 4 characters
  const b32 = "0123456789abcdefghjkmnpqrstvwxyz"
  func part(n, width: int): string =
    result = newString(width)
    var x = n
    for i in countdown(width - 1, 0):
      result[i] = b32[x and 31]
      x = x shr 5
  (part(number shr 20, 2), part(number and 0xFFFFF, 4))

proc eventBody*(event, delivery: string; run: RunFacts; now: int64; uiUrl: string; step = StepFacts()): JsonNode =
  var r = %*{"id": run.id, "state": run.state, "commit": run.commit, "ref": run.refName, "repository": run.repository, "trigger_id": run.triggerId, "created_at": run.createdAt}
  let ui = uiUrl.strip(leading = false, chars = {'/'})
  if ui.len > 0: r["link"] = %(ui & "/runs/" & run.id)
  result = %*{"event": event, "delivery": delivery, "time": now, "organization": run.organization, "project": run.project, "run": r}
  if event == "step.failed":
    let ids = stepIds(step.number)
    result["step"] = %*{"number": step.number, "job_id": ids.job, "step_id": ids.step, "attempt": step.attempt, "exit_code": step.exitCode, "termination": step.termination}
  if event == "run.finished" and run.state notin ["OK", "SKIPPED"] and (run.failCode.len > 0 or run.failMessage.len > 0):
    result["failure"] = %*{"code": run.failCode, "message": run.failMessage}

func pingBody*(delivery, organization: string; now: int64): JsonNode =
  %*{"event": "ping", "delivery": delivery, "time": now, "organization": organization}

# ------------------------------------------------------------------ the rows

type
  Poster* = proc (url, body: string; headers: seq[(string, string)]): tuple[ok: bool, error: string] {.gcsafe.}
  SecretFor* = proc (w: WebhookRow): string {.gcsafe.}      ## the value of the secret the webhook names ("" when it cannot be had now)

const
  columns = "w.id, w.tenant_id, o.slug, w.group_id, COALESCE(g.path, ''), w.name, w.url, w.secret, w.events, w.enabled, w.created_at"
  fromTables = " FROM webhooks w JOIN organizations o ON o.id = w.tenant_id LEFT JOIN groups g ON g.id = w.group_id "

proc rowOf(v: JsonNode): WebhookRow =
  WebhookRow(id: v[0].getStr, tenantId: v[1].getStr, slug: v[2].getStr, groupId: v[3].getStr, groupPath: v[4].getStr, name: v[5].getStr, url: v[6].getStr,
             secret: v[7].getStr, events: v[8].getStr.split(',').filterIt(it.len > 0), enabled: v[9].getInt > 0, createdAt: v[10].getBiggestInt)

proc selectWebhooks(c: var RqClient; where: string; args: seq[JsonNode]): seq[WebhookRow] =
  var stmt = %*["SELECT " & columns & fromTables & where]
  for a in args: stmt.add a
  let vals = c.query(%*[stmt])["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add rowOf(v)

proc listWebhooks*(c: var RqClient; tenantId: string): seq[WebhookRow] =
  c.selectWebhooks("WHERE w.tenant_id = ? ORDER BY w.name", @[%tenantId])

proc getWebhook*(c: var RqClient; tenantId, id: string): tuple[found: bool, row: WebhookRow] =
  let l = c.selectWebhooks("WHERE w.tenant_id = ? AND w.id = ?", @[%tenantId, %id])
  if l.len > 0: (true, l[0]) else: (false, WebhookRow())

proc countWebhooks*(c: var RqClient; tenantId: string): int =
  c.query(%*[["SELECT count(*) FROM webhooks WHERE tenant_id = ?", tenantId]])["results"][0]{"values"}[0][0].getInt

proc webhookNameTaken*(c: var RqClient; tenantId, name: string): bool =
  c.query(%*[["SELECT count(*) FROM webhooks WHERE tenant_id = ? AND name = ?", tenantId, name]])["results"][0]{"values"}[0][0].getInt > 0

proc createWebhook*(c: var RqClient; tenantId: string; s: WebhookSpec; groupId: string; now: int64): string =
  ## `groupId` is the id of the project named by `s.groupPath` ("" = the whole organisation), which the caller has looked up
  result = newId()
  discard c.execute(%*[["INSERT INTO webhooks (id, tenant_id, group_id, name, url, secret, events, enabled, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    result, tenantId, groupId, s.name, s.url, s.secret, s.events.join(","), (if s.enabled: 1 else: 0), now]])

proc updateWebhook*(c: var RqClient; tenantId, id: string; s: WebhookSpec): bool =
  ## the address, the secret's name, the events and on or off change; the name and the project do not (the deliveries written for it belong to them)
  c.execute(%*[["UPDATE webhooks SET url = ?, secret = ?, events = ?, enabled = ? WHERE tenant_id = ? AND id = ?",
    s.url, s.secret, s.events.join(","), (if s.enabled: 1 else: 0), tenantId, id]])["results"][0]{"rows_affected"}.getInt > 0

proc deleteWebhook*(c: var RqClient; tenantId, id: string): bool =
  ## with the deliveries written for it
  if not c.getWebhook(tenantId, id).found: return false
  discard c.execute(%*[["DELETE FROM webhook_deliveries WHERE webhook_id = ?", id], ["DELETE FROM webhooks WHERE tenant_id = ? AND id = ?", tenantId, id]], transaction = true)
  true

# ------------------------------------------------------------------ writing the events down

proc queueEvents*(c: var RqClient; now: int64; uiUrl = ""): int =
  ## One look at the runs of every webhook that is on: each event that has happened and is not written down yet is written (a row, once: the key of the table is the webhook, the run, the event and,
  ## for a failed step, its number), whatever the beat missed in between. Only runs made after the webhook was, and not older than three days. Returns how many rows are new.
  for w in c.selectWebhooks("WHERE w.enabled = 1", @[]):
    let since = max(now - windowSeconds, w.createdAt)
    var sql = "SELECT r.id, r.state, r.source_commit, r.source_ref, r.source_repository, COALESCE(r.trigger_id, ''), r.fail_code, r.fail_message, CAST(r.created_at AS INTEGER), " &
              "COALESCE((SELECT g2.path FROM groups g2 WHERE g2.id = r.group_id), '') FROM runs r WHERE r.tenant_id = ? AND CAST(r.created_at AS INTEGER) >= ?"
    var args = @[%w.tenantId, %since]
    if w.groupId.len > 0:
      sql.add " AND r.group_id IN (SELECT id FROM groups WHERE tenant_id = ? AND (path = ? OR path LIKE ?))"      # the project and the groups under it (a name of a group has no % or _)
      args.add [%w.tenantId, %w.groupPath, %(w.groupPath & "/%")]
    sql.add " ORDER BY r.id DESC LIMIT 200"
    var stmt = %*[sql]
    for a in args: stmt.add a
    let rows = c.query(%*[stmt])["results"][0]{"values"}
    if rows == nil or rows.len == 0: continue
    var runs: seq[RunFacts]
    for v in rows:
      runs.add RunFacts(id: v[0].getStr, organization: w.slug, state: v[1].getStr, commit: v[2].getStr, refName: v[3].getStr, repository: v[4].getStr, triggerId: v[5].getStr,
                        failCode: v[6].getStr, failMessage: v[7].getStr, createdAt: v[8].getBiggestInt, project: v[9].getStr)
    var failed = initTable[string, seq[StepFacts]]()
    if "step.failed" in w.events:
      var q = %*["SELECT s.run_id, s.ordinal, s.attempt, COALESCE(s.exit_code, -1), COALESCE(s.termination, '') FROM steps s WHERE s.state = 'FAILED' AND s.run_id IN (" &
                 runs.mapIt("?").join(",") & ")"]
      for r in runs: q.add %r.id
      let fs = c.query(%*[q])["results"][0]{"values"}
      if fs != nil:
        for v in fs: failed.mgetOrPut(v[0].getStr, @[]).add StepFacts(number: v[1].getInt, attempt: v[2].getInt, exitCode: v[3].getInt, termination: v[4].getStr)
    var stmts = newJArray()
    template add(run: RunFacts; event, key: string; step = StepFacts()) =
      let id = newId()
      stmts.add %*["INSERT OR IGNORE INTO webhook_deliveries (id, webhook_id, run_id, event, ekey, body, created_at, attempts, next_at, sent_at, last_error) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 0, '')",
                   id, w.id, run.id, event, key, $eventBody(event, id, run, now, uiUrl, step), now]
    for r in runs:
      if "run.started" in w.events and hasStarted(r.state):
        var started = r
        started.state = "RUNNING"                                    # the event is the start; the state it names is the one it started in
        add(started, "run.started", "")
      for st in failed.getOrDefault(r.id):
        add(r, "step.failed", $st.number & "." & $st.attempt, st)
      if "run.finished" in w.events and hasFinished(r.state):
        add(r, "run.finished", "")
    if stmts.len > 0:
      let res = c.execute(stmts, transaction = true)
      for x in res["results"]: result += x{"rows_affected"}.getInt

proc queuePing*(c: var RqClient; w: WebhookRow; now: int64): string =
  ## a row that is sent at the next beat: for a person who wants to see that the address answers
  result = newId()
  discard c.execute(%*[["INSERT INTO webhook_deliveries (id, webhook_id, run_id, event, ekey, body, created_at, attempts, next_at, sent_at, last_error) VALUES (?, ?, '', 'ping', ?, ?, ?, 0, 0, 0, '')",
    result, w.id, result, $pingBody(result, w.slug, now), now]])

# ------------------------------------------------------------------ sending

proc deliverDue*(c: var RqClient; now: int64; post: Poster; allowed: seq[string]; secretOf: SecretFor): int =
  ## The rows that are due (not sent, tried fewer than `maxAttempts` times, whose pause is over) of the webhooks that are on, at most 50 in a look. A refusal is written down with its reason and the time of
  ## the next try; an address the shard does not allow (any more) is given up at once; a secret that cannot be had now is a refusal too (nothing goes out unsigned that should be signed).
  ## Returns how many were accepted.
  let due = c.query(%*[["SELECT d.id, d.webhook_id, d.event, d.body, d.attempts FROM webhook_deliveries d JOIN webhooks w ON w.id = d.webhook_id " &
    "WHERE w.enabled = 1 AND d.sent_at = 0 AND d.attempts < ? AND d.next_at <= ? ORDER BY d.created_at LIMIT 50", maxAttempts, now]])["results"][0]{"values"}
  if due == nil: return
  var hooks = initTable[string, WebhookRow]()
  for v in due:
    let id = v[0].getStr
    let attempts = v[4].getInt
    if v[1].getStr notin hooks:
      let l = c.selectWebhooks("WHERE w.id = ?", @[%v[1].getStr])
      if l.len == 0: continue
      hooks[v[1].getStr] = l[0]
    let w = hooks[v[1].getStr]
    template refuse(why: string; final = false) =
      discard c.execute(%*[["UPDATE webhook_deliveries SET attempts = ?, next_at = ?, last_error = ? WHERE id = ?",
        (if final: maxAttempts else: attempts + 1), now + backoffSeconds(attempts), why, id]])
    let notAllowed = urlAllowed(w.url, allowed)
    if notAllowed.len > 0:
      refuse(notAllowed, final = true)
      continue
    let body = v[3].getStr
    var headers = @[("Content-Type", "application/json"), ("User-Agent", "cinim-core"), ("X-CiNim-Event", v[2].getStr), ("X-CiNim-Delivery", id)]
    if w.secret.len > 0:
      let value = secretOf(w)
      if value.len == 0:
        refuse("the secret " & w.secret & " cannot be had now")
        continue
      headers.add ("X-CiNim-Signature", signature(value, body))
    let r = post(w.url, body, headers)
    if r.ok:
      discard c.execute(%*[["UPDATE webhook_deliveries SET sent_at = ?, attempts = ?, last_error = '' WHERE id = ?", now, attempts + 1, id]])
      inc result
    else:
      refuse(r.error)

proc pruneDeliveries*(c: var RqClient; now: int64): int =
  ## what is done (sent, or given up) and older than three days
  c.execute(%*[["DELETE FROM webhook_deliveries WHERE (sent_at > 0 OR attempts >= ?) AND created_at < ?", maxAttempts, now - windowSeconds]])["results"][0]{"rows_affected"}.getInt

proc httpPost*(url, body: string; headers: seq[(string, string)]): tuple[ok: bool, error: string] {.gcsafe.} =
  {.cast(gcsafe).}:
    try:
      let client = newHttpClient(timeout = 10000, headers = newHttpHeaders(headers))
      defer: client.close()
      let r = client.post(url, body)
      if r.code.int in 200 .. 299: return (true, "")
      (false, "the receiver answered " & $r.code.int & ": " & r.body[0 ..< min(r.body.len, 200)])
    except CatchableError as e:
      (false, e.msg)

# ------------------------------------------------------------------ the beat

proc syncWebhooks*(rqliteUrl: string; now: int64): int =
  ## One beat (the loop of the triggers calls it, like prstatus.syncStatuses): the events are written down, the rows that are due are sent. Returns how many were accepted.
  let allowed = allowedHosts()
  if allowed.len == 0: return                          # a shard that allows no address sends nothing, and need not look
  var c = newRq(rqliteUrl)
  discard c.queueEvents(now, getEnv("CINIM_UI_URL"))
  let vk = vaultKek()
  var cache = initTable[string, string]()
  let secretOf: SecretFor = proc (w: WebhookRow): string {.gcsafe.} =
    {.cast(gcsafe).}:
      if not vk.ready: return ""
      let key = w.tenantId & "|" & w.groupId & "|" & w.secret
      if key notin cache:
        var rc = newRq(rqliteUrl)
        let got = rc.getSecrets(vk.kek, w.tenantId, @[w.secret], w.groupId, true)
        cache[key] = if got.ok and got.values.len > 0: got.values[0][1] else: ""
      cache[key]
  result = c.deliverDue(now, httpPost, allowed, secretOf)
  discard c.pruneDeliveries(now)
