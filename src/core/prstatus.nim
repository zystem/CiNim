## D-96: the state of a run is told to the host of its repository, as the status of the commit (GitHub) or of the pipeline (GitLab), which is what a pull request shows: "cinim/.ci/pipeline.lua"
## is green when the build passed, and the run of the pipeline that follows it (`ci.trigger`) is "waits for approval (0 of 1)" with a link to its page until it is approved. A project says where
## (`groups.status_target`: provider, repository, the name of the secret of the organisation that holds the token, optionally the address of the API) and the core tells it each beat: a run whose
## state is not the one it last told (`runs.status_sent`) is told again, and a refusal of the host is tried again a minute later. The address must be one the shard allows
## (`CINIM_STATUS_API_URLS`, by default the two public hosts), because the core sends a token there: a project must not be able to point it anywhere.
import std/[json, strutils, httpclient, times, os, tables, uri]
import ../common/rqlite
import secretvault, projectpolicy

const
  defaultApiUrls = ["https://api.github.com", "https://gitlab.com/api/v4"]
  retryAfterSeconds = 60'i64
  statusWindowSeconds = 3'i64 * 86400         ## runs older than this are not told any more

type StatusTarget* = object
  provider*, repository*, secret*, apiUrl*: string           ## provider is "" when the project tells nobody

func allowedApiUrls*(): seq[string] =
  let e = getEnv("CINIM_STATUS_API_URLS")
  if e.len == 0: return @defaultApiUrls
  for x in e.split(','):
    if x.strip.len > 0: result.add x.strip.strip(leading = false, chars = {'/'})

func defaultApiUrl(provider: string): string =
  if provider == "gitlab": "https://gitlab.com/api/v4" else: "https://api.github.com"

proc parseStatusTarget*(j: JsonNode): tuple[target: StatusTarget, error: string] =
  ## {"provider": "github" | "gitlab", "repository": "owner/name", "secret": "NAME", "api_url": "..."}; the address is one of the allowed
  if j == nil or j.kind != JObject: return (StatusTarget(), "status is {provider, repository, secret, api_url?} or null")
  for k in ["provider", "repository", "secret"]:
    if not j.hasKey(k) or j[k].kind != JString or j[k].getStr.len == 0: return (StatusTarget(), "status." & k & " is required")
  let t = StatusTarget(provider: j["provider"].getStr, repository: j["repository"].getStr, secret: j["secret"].getStr,
                       apiUrl: (if j.hasKey("api_url") and j["api_url"].kind == JString and j["api_url"].getStr.len > 0: j["api_url"].getStr.strip(leading = false, chars = {'/'}) else: defaultApiUrl(j["provider"].getStr)))
  if t.provider notin ["github", "gitlab"]: return (StatusTarget(), "status.provider is github or gitlab")
  if t.repository.len > 200 or t.repository.count('/') < 1 or t.repository.startsWith("/") or t.repository.endsWith("/"): return (StatusTarget(), "status.repository is owner/name (a GitLab project may have groups: group/sub/name)")
  for ch in t.repository:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '-', '/'}: return (StatusTarget(), "status.repository has a character a repository name does not")
  if t.secret.len > 100 or t.secret.contains({' ', '\n'}): return (StatusTarget(), "status.secret is the name of a secret of the organisation or of the project")
  if t.apiUrl notin allowedApiUrls(): return (StatusTarget(), "status.api_url is not one the shard allows (" & allowedApiUrls().join(", ") & ")")
  (t, "")

proc statusTargetOf*(c: var RqClient; groupId: string): StatusTarget =
  if groupId.len == 0: return
  let v = c.query(%*[["SELECT status_target FROM groups WHERE id = ?", groupId]])["results"][0]{"values"}
  if v == nil or v.len == 0 or v[0][0].getStr.len == 0: return
  let j = try: parseJson(v[0][0].getStr) except CatchableError: return
  let p = parseStatusTarget(j)
  if p.error.len == 0: result = p.target                   # one that is not allowed any more (the list of the shard changed) is told nobody

proc setStatusTarget*(c: var RqClient; groupId: string; j: JsonNode): string =
  ## "" when saved; JNull clears it
  if j == nil or j.kind == JNull:
    discard c.execute(%*[["UPDATE groups SET status_target = '' WHERE id = ?", groupId]])
    return
  let p = parseStatusTarget(j)
  if p.error.len > 0: return p.error
  discard c.execute(%*[["UPDATE groups SET status_target = ? WHERE id = ?", $(%*{"provider": p.target.provider, "repository": p.target.repository, "secret": p.target.secret, "api_url": p.target.apiUrl}), groupId]])

func viewOf*(t: StatusTarget): JsonNode =
  if t.provider.len == 0: newJNull() else: %*{"provider": t.provider, "repository": t.repository, "secret": t.secret, "api_url": t.apiUrl}

func pick(gh: bool; a, b: string): string = (if gh: a else: b)

func statusOf*(provider, state, failMessage: string; have, need: int): tuple[code, text: string] =
  ## what the host is told for the state of a run: its word for it, and a line of at most 140 characters
  let gh = provider == "github"
  func clip(s: string): string = (if s.len > 130: s[0 ..< 130] else: s)
  case state
  of "QUEUED": result = ("pending", "queued")
  of "WAITING": result = ("pending", "waits for approval (" & $have & " of " & $need & ")")
  of "RUNNING": result = (pick(gh, "pending", "running"), "running")
  of "OK": result = ("success", "passed")
  of "FAILED": result = (pick(gh, "failure", "failed"), clip("failed: " & failMessage))
  of "ABORTED": result = (pick(gh, "error", "canceled"), clip(if failMessage.len > 0: failMessage else: "aborted"))
  of "TIMED_OUT": result = (pick(gh, "error", "failed"), clip(if failMessage.len > 0: failMessage else: "timed out"))
  of "INFRASTRUCTURE_ERROR": result = (pick(gh, "error", "failed"), clip("infrastructure error: " & failMessage))
  else: result = ("", "")

proc postStatus*(t: StatusTarget; token, sha, code, text, context, targetUrl: string): tuple[ok: bool, error: string] =
  let headers = newHttpHeaders({"User-Agent": "cinim-core", "Accept": "application/json"})
  var url, body: string
  let proxyUrl = getEnv("CINIM_STATUS_PROXY")
  try:
    let client = if proxyUrl.len > 0: newHttpClient(timeout = 10000, headers = headers, proxy = newProxy(proxyUrl)) else: newHttpClient(timeout = 10000, headers = headers)
    defer: client.close()
    if t.provider == "github":
      url = t.apiUrl & "/repos/" & t.repository & "/statuses/" & sha
      client.headers["Authorization"] = "Bearer " & token
      client.headers["Content-Type"] = "application/json"
      var j = %*{"state": code, "description": text, "context": context}
      if targetUrl.len > 0: j["target_url"] = %targetUrl
      body = $j
    else:
      url = t.apiUrl & "/projects/" & encodeUrl(t.repository, usePlus = false) & "/statuses/" & sha & "?state=" & code & "&name=" & encodeUrl(context, usePlus = false) &
            "&description=" & encodeUrl(text, usePlus = false) & (if targetUrl.len > 0: "&target_url=" & encodeUrl(targetUrl, usePlus = false) else: "")
      client.headers["PRIVATE-TOKEN"] = token
    let r = client.post(url, body)
    if r.code.int in 200 .. 299: return (true, "")
    (false, "the host answered " & $r.code.int & ": " & r.body[0 ..< min(r.body.len, 200)])
  except CatchableError as e:
    (false, e.msg)

var retryAt {.threadvar.}: Table[string, int64]

proc syncStatuses*(rqliteUrl: string; now: int64): int =
  ## One look: every run of a project that tells a host, whose state is not the one told last, is told. Returns how many were told.
  var c = newRq(rqliteUrl)
  let rows = c.query(%*[["SELECT r.id, r.state, r.source_commit, r.source_path, r.fail_message, r.tenant_id, r.group_id, g.status_target, r.approval_required, " &
    "(SELECT count(*) FROM run_approvals a WHERE a.run_id = r.id AND a.decision = 'approve') FROM runs r JOIN groups g ON g.id = r.group_id " &
    "WHERE g.status_target <> '' AND r.source_repository <> '' AND r.status_sent <> r.state AND CAST(r.created_at AS INTEGER) > ? ORDER BY r.id LIMIT 50", now - statusWindowSeconds]])["results"][0]{"values"}
  if rows == nil: return
  let vk = vaultKek()
  let ui = getEnv("CINIM_UI_URL").strip(leading = false, chars = {'/'})
  var tokens = initTable[string, string]()
  for v in rows:
    let id = v[0].getStr
    let sha = v[2].getStr
    if sha.len notin [40, 64] or retryAt.getOrDefault(id) > now: continue          # the commit is not resolved yet, or the host refused a moment ago
    let target = statusTargetOf(c, v[6].getStr)
    if target.provider.len == 0: continue
    let st = statusOf(target.provider, v[1].getStr, v[4].getStr, v[9].getInt, v[8].getInt)
    if st.code.len == 0: continue
    if not vk.ready: continue
    let tk = v[5].getStr & "|" & v[6].getStr & "|" & target.secret
    if tk notin tokens:
      let got = c.getSecrets(vk.kek, v[5].getStr, @[target.secret], v[6].getStr, true)
      tokens[tk] = if got.ok and got.values.len > 0: got.values[0][1] else: ""
    if tokens[tk].len == 0:
      retryAt[id] = now + retryAfterSeconds
      continue
    let told = postStatus(target, tokens[tk], sha, st.code, st.text, "cinim/" & v[3].getStr, (if ui.len > 0: ui & "/runs/" & id else: ""))
    if told.ok:
      discard c.execute(%*[["UPDATE runs SET status_sent = ? WHERE id = ?", v[1].getStr, id]])
      retryAt.del id
      inc result
    else:
      stderr.writeLine "core: status of run " & id & " to " & target.repository & ": " & told.error
      retryAt[id] = now + retryAfterSeconds
