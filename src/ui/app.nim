## The UI service (docs/ui.md, UI-001, UI-009): pages rendered on the server from what the core's API says, with the token of the user in a cookie and nothing kept here. `handle` takes a request
## and gives a response, and knows the core only as a `CoreApi`: the tests give it one that says what they want, `main.nim` gives it the real one and makes it a server.
##   /login, /logout, /orgs, /orgs/<slug>/runs, /runs, /runs/<id>, /runs/<id>/steps/<n>/log, /status, /static/ui.css  (all under the prefix `base`), and /healthz outside it.
## A page that needs a session sends a visitor without one to the login and brings them back; a token that the core refuses ends the session; what a page puts in a link to the core is checked
## first (a slug, an id, a number), so that an address cannot reach further than the page it names.
import std/[json, strutils, tables, times, uri, os, hashes, algorithm]
import nimja
import render, coreapi

type
  UiConfig* = object
    base*: string                    ## the prefix of the UI in the address ("/ui", or "" at the root)
    secureCookie*: bool              ## the cookie says Secure: set it when the UI is reached over HTTPS

  UiRequest* = object
    meth*, path*, query*, cookie*, host*, origin*, secFetchSite*: string
    form*: Table[string, string]

  UiResponse* = object
    status*: int
    headers*: seq[(string, string)]
    body*: string

  OrgRow = object
    slug, name, state, namespace: string
  RunItem = object
    id, short, state, organization, source, created, updated, failure, took: string
  StateLink = object
    name, link: string
    active: bool
  ParamRow = object
    name, value: string
  StepRow = object
    seq, attempt: int
    state, exitCode, termination, pod, took: string
  RunView = object
    id, state, organization, group, created, updated, repository, commit, path, waitReason, failureCode, failureMessage, took: string
    params: seq[ParamRow]
    steps: seq[StepRow]
  LogLine = object
    n: int
    text: string
  StepLog = object
    seq, attempt, earlier: int
    state, earlierLink, note: string
    lines: seq[LogLine]
  ComponentRow = object
    kind, id, state, seen: string

const
  cookieName = "cinim_ui"
  logWindow = 200
  runLogLines = 100          ## the log of a run: the last lines of each step, no more (DAT-007)
  runLogSteps = 30           ## ... and this many steps to a page
  runsPerPage = 50
  sessionMax = 8 * 3600
  templateDir = currentSourcePath().parentDir / "templates"
  css = staticRead("ui.css")
  cssVersion = toHex(int64(hash(css)), 8)       # in the link: a new style sheet is a new address, and the day of caching does not hold back a change
  runStates = ["PENDING", "RUNNING", "SUCCEEDED", "FAILED", "ABORTED"]   # the core's word (RUN_STATE_ABORTED); a state that is spelled two ways is a filter that matches nothing

func isId(s: string): bool =
  ## the id of a run, or the cursor: what the core makes (letters, digits, - and _)
  if s.len < 1 or s.len > 80: return false
  for c in s:
    if c notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_'}: return false
  true

func isSlug(s: string): bool =
  if s.len < 1 or s.len > 40 or s[0] notin {'a' .. 'z'}: return false
  for c in s:
    if c notin {'a' .. 'z', '0' .. '9', '-'}: return false
  true

func isWord(s: string): bool =
  if s.len < 1 or s.len > 24: return false
  for c in s:
    if c notin {'A' .. 'Z', '_'}: return false
  true

func isNumber(s: string; digits = 9): bool =
  ## step numbers are hashes below 2^31 (ten digits); a line number has nine at most
  if s.len < 1 or s.len > digits: return false
  for c in s:
    if c notin {'0' .. '9'}: return false
  true

func shortRunId(id: string): string =
  ## the list shows the last six characters of the id (of an id, where the time is the start and the end changes fastest; the row has the time in a column of its own);
  ## the whole id is the title of the link and the heading of the run's page
  if id.len > 12: "…" & id[^6 .. ^1] else: id

func isKind(n: JsonNode; k: JsonNodeKind): bool =
  ## `n{"key"}` is nil for a key that is not there, and `.kind` of nil is a segmentation fault
  not n.isNil and n.kind == k

proc timeText(s: string): string =
  ## the core's times are seconds since the epoch, as text: a person reads them in UTC
  let whole = s.split('.')[0]
  if whole.len in 1 .. 12 and whole.allCharsInSet({'0' .. '9'}):
    try: return fromUnix(parseBiggestInt(whole)).utc.format("yyyy-MM-dd HH:mm:ss")
    except CatchableError: discard
  s

func plainText*(line: string): string =
  ## A line of a log without the control sequences that a tool writes for a terminal (colours, moving the cursor): `ESC [ ... final byte`. The log itself is kept as it was written.
  var i = 0
  while i < line.len:
    if line[i] == '\x1b' and i + 1 < line.len and line[i + 1] == '[':
      i += 2
      while i < line.len and line[i] in {'0' .. '?'}: inc i          # the parameters
      while i < line.len and line[i] in {' ' .. '/'}: inc i          # the intermediate bytes
      if i < line.len: inc i                                          # the final byte
    elif line[i] == '\x1b':
      inc i                                                           # a lone escape: nothing to show
    else:
      result.add line[i]
      inc i

func durationText*(seconds: int64): string =
  ## "45 s", "1 min 30 s", "1 h 02 min", "1 d 01 h": two units, the first is the biggest that is not zero
  if seconds < 0: ""
  elif seconds < 60: $seconds & " s"
  elif seconds < 3600: $(seconds div 60) & " min " & $(seconds mod 60) & " s"
  elif seconds < 86400: $(seconds div 3600) & " h " & align($((seconds mod 3600) div 60), 2, '0') & " min"
  else: $(seconds div 86400) & " d " & align($((seconds mod 86400) div 3600), 2, '0') & " h"

func tookText*(start, stop: int64; ended: bool; now: int64): string =
  ## How long it took: from `start` to `stop` when it has ended, to `now` while it goes on. Nothing for what has not started or whose end is before its start.
  if start <= 0: return ""
  let finish = if ended: stop else: now
  if finish < start: "" else: durationText(finish - start)

func secondsOf(text: string): int64 =
  ## the core's times are seconds since the epoch, as text or as a number; 0 for anything else
  let whole = text.split('.')[0]
  if whole.len in 1 .. 12 and whole.allCharsInSet({'0' .. '9'}):
    try: return parseBiggestInt(whole) except ValueError: discard

const finalRunStates = ["SUCCEEDED", "FAILED", "ABORTED", "SKIPPED", "TIMED_OUT", "INFRASTRUCTURE_ERROR"]

func runTook(state, created, updated: string; now: int64): string =
  ## a run ends when it reaches a final state; its `updated_at` is then the moment it did
  tookText(secondsOf(created), secondsOf(updated), state in finalRunStates, now)

func ago(seconds: float): string =
  if seconds > 3.0e8: "never"                 # the core counts from the epoch for what it has not heard of
  elif seconds < 90: $int(seconds) & " s ago"
  elif seconds < 5400: $int(seconds / 60) & " min ago"
  else: $int(seconds / 3600) & " h ago"

proc security(r: var UiResponse) =
  r.headers.add ("Content-Security-Policy", "default-src 'none'; style-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
  r.headers.add ("X-Content-Type-Options", "nosniff")
  r.headers.add ("Referrer-Policy", "same-origin")
  r.headers.add ("Cache-Control", "no-store")

proc page(status: int; body: string): UiResponse =
  result = UiResponse(status: status, body: body)
  result.headers.add ("Content-Type", "text/html; charset=utf-8")
  security(result)

proc redirect(location: string; cookie = ""): UiResponse =
  result = UiResponse(status: 303)
  result.headers.add ("Location", location)
  if cookie.len > 0: result.headers.add ("Set-Cookie", cookie)
  security(result)

func cookiePath(cfg: UiConfig): string =
  if cfg.base.len > 0: cfg.base else: "/"

func sessionCookie(cfg: UiConfig; token: string; maxAge: int): string =
  cookieName & "=" & token & "; Path=" & cookiePath(cfg) & "; HttpOnly; SameSite=Strict; Max-Age=" & $maxAge & (if cfg.secureCookie: "; Secure" else: "")

func clearCookie(cfg: UiConfig): string =
  sessionCookie(cfg, "", 0)

func tokenOf(cookie: string): string =
  for part in cookie.split(';'):
    let p = part.strip
    if p.startsWith(cookieName & "="):
      let v = p[cookieName.len + 1 .. ^1]
      if v.len in 1 .. 512:
        for c in v:
          if c notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '~', '-', ':', '+'}: return ""
        return v

# ------------------------------------------------------------------ the pages (templates/*.nimja: every expression through h() or raw(), tests/unit/ttemplates.nim)

proc renderLogin(base, message, user, next: string): string =
  let loggedIn = false
  compileTemplateFile("login.nimja", templateDir)

proc renderMessage(base: string; loggedIn: bool; title, text, detail, back, backText: string): string =
  compileTemplateFile("message.nimja", templateDir)

proc renderOrgs(base: string; orgs: seq[OrgRow]): string =
  let loggedIn = true
  compileTemplateFile("orgs.nimja", templateDir)

proc renderRuns(base, org, allLink, older: string; states: seq[StateLink]; runs: seq[RunItem]): string =
  let loggedIn = true
  compileTemplateFile("runs.nimja", templateDir)

proc renderRun(base: string; run: RunView): string =
  let loggedIn = true
  compileTemplateFile("run.nimja", templateDir)

proc renderLog(base, runId: string; step: int; stepState: string; complete: bool; prev, next: string; lines: seq[LogLine]): string =
  let loggedIn = true
  compileTemplateFile("log.nimja", templateDir)

proc renderRunLog(base, runId, runState: string; window: int; blocks: seq[StepLog]; later: string): string =
  let loggedIn = true
  compileTemplateFile("runlog.nimja", templateDir)

proc renderStatus(base: string; components: seq[ComponentRow]): string =
  let loggedIn = true
  compileTemplateFile("status.nimja", templateDir)

# ------------------------------------------------------------------ the handlers

proc loginPage(cfg: UiConfig; status: int; message, user, next: string): UiResponse =
  page(status, renderLogin(cfg.base, message, user, next))

proc messagePage(cfg: UiConfig; status: int; loggedIn: bool; title, text: string; detail = ""; back = ""; backText = ""): UiResponse =
  page(status, renderMessage(cfg.base, loggedIn, title, text, detail, back, backText))

func safeNext(cfg: UiConfig; next: string): string =
  ## where a login may go on to: a page of this UI (the prefix and then a path), never another address
  let prefix = cfg.base & "/"
  if next.len > 1 and next.len < 300 and next.startsWith(prefix) and "//" notin next and ".." notin next and "\\" notin next:
    for c in next:
      if c notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '/', '_', '-', '.', '?', '=', '&', '%'}: return cfg.base & "/orgs"
    return next
  cfg.base & "/orgs"

func sameOrigin(r: UiRequest): bool =
  ## a POST comes from this host: the Origin (when the browser sends one) names it, and the browser does not say it is another site
  if r.secFetchSite.len > 0 and r.secFetchSite notin ["same-origin", "none"]: return false
  if r.origin.len == 0: return true
  let o = r.origin.toLowerAscii
  let at = o.find("://")
  at > 0 and o[at + 3 .. ^1] == r.host.toLowerAscii

proc failed(cfg: UiConfig; r: ApiResult; what: string): UiResponse =
  ## what a page says when the core did not give it what it asked for
  case r.status
  of asUnauthorized:
    redirect(cfg.base & "/login", clearCookie(cfg))
  of asForbidden:
    messagePage(cfg, 403, true, "Not allowed", "Your user may not see this: " & what & ".", r.message)
  of asNotFound:
    messagePage(cfg, 404, true, "Not found", "No such " & what & ".", "", cfg.base & "/orgs", "Organisations")
  of asUnavailable:
    messagePage(cfg, 503, true, "The core does not answer", "Try again in a moment.", r.message)
  else:
    messagePage(cfg, 502, true, "The core refused", "The core did not do what the page asked.", r.message)

proc doLogin(cfg: UiConfig; api: CoreApi; req: UiRequest): UiResponse =
  let user = req.form.getOrDefault("user")
  let next = req.form.getOrDefault("next")
  let r = api.login(user, req.form.getOrDefault("password"))
  case r.status
  of asOk:
    if r.body{"password_change_required"}.getBool:
      return messagePage(cfg, 403, false, "Change the password first",
        "This user has to change the password before anything else; the UI does not do that. Use the API:", "PUT /api/v1/users/" & r.body{"user"}.getStr(user) & "/password",
        cfg.base & "/login", "Back to the login")
    let token = r.body{"token"}.getStr
    let left = r.body{"expires_at"}.getBiggestInt(0) - getTime().toUnix()
    let maxAge = int(min(max(left, 60), sessionMax))
    redirect(safeNext(cfg, next), sessionCookie(cfg, token, maxAge))
  of asUnauthorized:
    loginPage(cfg, 401, "Wrong user name or password.", user, next)
  of asRefused:
    loginPage(cfg, (if r.code == 429: 429 else: 502), "The login was refused: " & r.message & ".", user, next)
  else:
    messagePage(cfg, 503, false, "The core does not answer", "Try again in a moment.", r.message, cfg.base & "/login", "Back to the login")

proc orgsPage(cfg: UiConfig; api: CoreApi; token: string): UiResponse =
  let r = api.get(token, "/api/v1/organizations")
  if r.status != asOk: return failed(cfg, r, "list of organisations")
  var orgs: seq[OrgRow]
  for o in r.body{"organizations"}.getElems:
    let slug = o{"slug"}.getStr
    if isSlug(slug): orgs.add OrgRow(slug: slug, name: o{"name"}.getStr, state: o{"state"}.getStr, namespace: o{"namespace"}.getStr)
  page(200, renderOrgs(cfg.base, orgs))

proc runsPage(cfg: UiConfig; api: CoreApi; token, org: string; query: Table[string, string]): UiResponse =
  ## `org` is "" for the runs the token may see in all organisations
  var state = query.getOrDefault("state")
  if not isWord(state): state = ""
  var before = query.getOrDefault("before")
  if not isId(before): before = ""
  var path = "/api/v1/runs?"
  if org.len > 0: path.add "organization=" & org & "&"
  if state.len > 0: path.add "state=" & state & "&"
  path.add "limit=" & $runsPerPage
  if before.len > 0: path.add "&before=" & before
  let r = api.get(token, path)
  if r.status != asOk: return failed(cfg, r, "list of runs")
  var runs: seq[RunItem]
  for x in r.body{"runs"}.getElems:
    let commit = x{"source"}{"commit"}.getStr
    let failure = if x.hasKey("failure"): x["failure"]{"code"}.getStr & (if x["failure"]{"message"}.getStr.len > 0: ": " & x["failure"]{"message"}.getStr else: "") else: ""
    runs.add RunItem(id: x{"id"}.getStr, short: shortRunId(x{"id"}.getStr), state: x{"state"}.getStr, organization: x{"organization"}.getStr, source: (if commit.len > 7: commit[0 ..< 7] else: commit),
                     created: timeText(x{"created_at"}.getStr), updated: timeText(x{"updated_at"}.getStr), failure: failure,
                     took: runTook(x{"state"}.getStr, x{"created_at"}.getStr, x{"updated_at"}.getStr, getTime().toUnix))
  let here = if org.len > 0: cfg.base & "/orgs/" & org & "/runs" else: cfg.base & "/runs"
  var states: seq[StateLink]
  for s in runStates: states.add StateLink(name: s, link: here & "?state=" & s, active: s == state)
  var older = ""
  if r.body{"next"}.isKind(JString):
    older = here & "?" & (if state.len > 0: "state=" & state & "&" else: "") & "before=" & r.body["next"].getStr
  page(200, renderRuns(cfg.base, org, here, older, states, runs))

proc runPage(cfg: UiConfig; api: CoreApi; token, id: string): UiResponse =
  let r = api.get(token, "/api/v1/runs/" & id)
  if r.status != asOk: return failed(cfg, r, "run " & id)
  let j = r.body
  var v = RunView(id: j{"id"}.getStr, state: j{"state"}.getStr, organization: j{"organization"}.getStr, group: j{"group"}.getStr,
                  created: timeText(j{"created_at"}.getStr), updated: timeText(j{"updated_at"}.getStr), waitReason: j{"wait_reason"}.getStr,
                  failureCode: j{"failure"}{"code"}.getStr, failureMessage: j{"failure"}{"message"}.getStr,
                  took: runTook(j{"state"}.getStr, j{"created_at"}.getStr, j{"updated_at"}.getStr, getTime().toUnix),
                  repository: j{"source"}{"repository"}.getStr, commit: j{"source"}{"commit"}.getStr, path: j{"source"}{"path"}.getStr)
  if not isSlug(v.organization): v.organization = ""
  if j{"params"}.isKind(JObject):
    for k, x in j["params"]: v.params.add ParamRow(name: k, value: (if x.kind == JString: x.getStr else: $x))
  for s in j{"steps"}.getElems:
    let reason = s{"pod_reason"}.getStr
    v.steps.add StepRow(seq: s{"seq"}.getInt, attempt: s{"attempt"}.getInt, state: s{"state"}.getStr,
                        exitCode: (if s{"exit_code"}.isKind(JInt): $s["exit_code"].getInt else: ""), termination: s{"termination"}.getStr, pod: reason,
                        took: tookText(s{"started_at"}.getInt(0), s{"finished_at"}.getInt(0), s{"finished_at"}.getInt(0) > 0, getTime().toUnix))
  page(200, renderRun(cfg.base, v))

proc logPage(cfg: UiConfig; api: CoreApi; token, id, stepText: string; query: Table[string, string]): UiResponse =
  let step = parseInt(stepText)
  var from0 = 0
  if isNumber(query.getOrDefault("from")): from0 = parseInt(query["from"])
  let r = api.get(token, "/api/v1/runs/" & id & "/steps/" & stepText & "/log?from=" & $from0 & "&limit=" & $logWindow)
  if r.status != asOk: return failed(cfg, r, "log of step " & stepText & " of run " & id)
  let here = cfg.base & "/runs/" & id & "/steps/" & stepText & "/log?from="
  var lines: seq[LogLine]
  var n = r.body{"from"}.getInt(from0)
  for l in r.body{"lines"}.getElems:
    lines.add LogLine(n: n, text: plainText(l.getStr))
    inc n
  let nextFrom = r.body{"next"}.getInt(n)
  let complete = r.body{"complete"}.getBool
  let more = (not complete) or nextFrom < r.body{"lines_total"}.getInt(0)
  let prev = if from0 > 0: here & $max(0, from0 - logWindow) else: ""
  let next = if more: here & $nextFrom else: ""
  page(200, renderLog(cfg.base, id, step, r.body{"step_state"}.getStr, complete, prev, next, lines))

proc runLogPage(cfg: UiConfig; api: CoreApi; token, id: string; query: Table[string, string]): UiResponse =
  ## The log of the whole run (DAT-007: still a window, never the whole log): the steps in the order of their numbers, each with the last lines of its log, one after the other. A step that
  ## writes while others do stays in its own place, which is why this is not one stream in the order of the time. A page holds `runLogSteps` steps; the next is named by the last number shown.
  var after = -1
  if isNumber(query.getOrDefault("after")): after = parseInt(query["after"])
  let r = api.get(token, "/api/v1/runs/" & id)
  if r.status != asOk: return failed(cfg, r, "run " & id)
  var steps: seq[tuple[seq, attempt: int, state: string]]
  for s in r.body{"steps"}.getElems:
    if s{"seq"}.isKind(JInt) and s["seq"].getInt > after: steps.add (s["seq"].getInt, s{"attempt"}.getInt, s{"state"}.getStr)
  steps.sort(proc (x, y: tuple[seq, attempt: int, state: string]): int = cmp(x.seq, y.seq))
  let more = steps.len > runLogSteps
  if more: steps.setLen runLogSteps
  var blocks: seq[StepLog]
  for st in steps:
    var b = StepLog(seq: st.seq, attempt: st.attempt, state: st.state)
    let stepPath = "/api/v1/runs/" & id & "/steps/" & $st.seq & "/log"
    var w = api.get(token, stepPath & "?from=0&limit=" & $runLogLines)
    if w.status == asNotFound:
      b.note = "No log yet."
      blocks.add b
      continue
    if w.status != asOk: return failed(cfg, w, "log of step " & $st.seq & " of run " & id)
    let total = w.body{"lines_total"}.getInt(0)
    if total > runLogLines:                      # the last lines are the ones that tell what the step is doing, or how it ended
      let tail = api.get(token, stepPath & "?from=" & $(total - runLogLines) & "&limit=" & $runLogLines)
      if tail.status != asOk: return failed(cfg, tail, "log of step " & $st.seq & " of run " & id)
      w = tail
    var n = w.body{"from"}.getInt(0)
    b.earlier = n
    if n > 0: b.earlierLink = cfg.base & "/runs/" & id & "/steps/" & $st.seq & "/log?from=0"
    for l in w.body{"lines"}.getElems:
      b.lines.add LogLine(n: n, text: plainText(l.getStr))
      inc n
    blocks.add b
  let later = if more and blocks.len > 0: cfg.base & "/runs/" & id & "/log?after=" & $blocks[^1].seq else: ""
  page(200, renderRunLog(cfg.base, id, r.body{"state"}.getStr, runLogLines, blocks, later))

proc statusPage(cfg: UiConfig; api: CoreApi; token: string): UiResponse =
  let r = api.get(token, "/api/v1/components")
  if r.status != asOk: return failed(cfg, r, "list of components")
  var rows: seq[ComponentRow]
  for c in r.body.getElems:                  # the core answers with the array itself
    rows.add ComponentRow(kind: c{"kind"}.getStr, id: c{"id"}.getStr, state: c{"state"}.getStr, seen: ago(c{"last_seen_seconds_ago"}.getFloat))
  page(200, renderStatus(cfg.base, rows))

proc notFound(cfg: UiConfig; loggedIn: bool): UiResponse =
  messagePage(cfg, 404, loggedIn, "Not found", "There is no such page.", "", cfg.base & "/orgs", "Organisations")

proc parseQuery(q: string): Table[string, string] =
  for k, v in decodeQuery(q): result[k] = v

proc pages(cfg: UiConfig; api: CoreApi; req: UiRequest; token, path: string; query: Table[string, string]): UiResponse =
  if req.meth != "GET":
    result = messagePage(cfg, 405, true, "Method not allowed", "GET.")
    result.headers.add ("Allow", "GET")
    return
  let parts = path.strip(chars = {'/'}).split('/')
  if path == "/" or path == "": return redirect(cfg.base & "/orgs")
  if parts == @["orgs"]: return orgsPage(cfg, api, token)
  if parts == @["runs"]: return runsPage(cfg, api, token, "", query)
  if parts == @["status"]: return statusPage(cfg, api, token)
  if parts.len == 3 and parts[0] == "orgs" and parts[2] == "runs" and isSlug(parts[1]): return runsPage(cfg, api, token, parts[1], query)
  if parts.len == 2 and parts[0] == "runs" and isId(parts[1]): return runPage(cfg, api, token, parts[1])
  if parts.len == 3 and parts[0] == "runs" and isId(parts[1]) and parts[2] == "log": return runLogPage(cfg, api, token, parts[1], query)
  if parts.len == 5 and parts[0] == "runs" and isId(parts[1]) and parts[2] == "steps" and isNumber(parts[3], 10) and parts[4] == "log":
    return logPage(cfg, api, token, parts[1], parts[3], query)
  notFound(cfg, true)

proc handle*(cfg: UiConfig; api: CoreApi; req: UiRequest): UiResponse =
  if req.path == "/healthz":
    result = UiResponse(status: 200, body: "ok")
    result.headers.add ("Content-Type", "text/plain")
    return
  if not req.path.startsWith(cfg.base & "/") and req.path != cfg.base:
    return notFound(cfg, false)
  let path = (if req.path.len > cfg.base.len: req.path[cfg.base.len .. ^1] else: "/")
  let token = tokenOf(req.cookie)
  let query = parseQuery(req.query)
  let isPost = req.meth == "POST"
  # the places that need no session
  if path == "/static/ui.css":
    if req.meth != "GET": return messagePage(cfg, 405, false, "Method not allowed", "GET.")
    result = UiResponse(status: 200, body: css)
    result.headers.add ("Content-Type", "text/css; charset=utf-8")
    result.headers.add ("Cache-Control", "public, max-age=86400")
    result.headers.add ("X-Content-Type-Options", "nosniff")
    return
  if path == "/login":
    if isPost:
      if not sameOrigin(req): return messagePage(cfg, 403, false, "Refused", "The form was not sent from this site.")
      return doLogin(cfg, api, req)
    if req.meth != "GET":
      result = messagePage(cfg, 405, false, "Method not allowed", "GET or POST.")
      result.headers.add ("Allow", "GET, POST")
      return
    return loginPage(cfg, 200, "", "", query.getOrDefault("next"))
  if path == "/logout":
    if not isPost:
      result = messagePage(cfg, 405, false, "Method not allowed", "POST.")
      result.headers.add ("Allow", "POST")
      return
    if not sameOrigin(req): return messagePage(cfg, 403, true, "Refused", "The form was not sent from this site.")
    return redirect(cfg.base & "/login", clearCookie(cfg))
  # the pages that do: without a session, or with a token that the core refuses, the way is through the login and back to this page
  let wanted = req.path & (if req.query.len > 0: "?" & req.query else: "")
  let toLogin = cfg.base & "/login" & (if path == "/" or path == "": "" else: "?next=" & encodeUrl(wanted, usePlus = false))
  if token.len == 0: return redirect(toLogin, clearCookie(cfg))
  result = pages(cfg, api, req, token, path, query)
  if result.status == 303 and result.headers.len > 0 and result.headers[0] == ("Location", cfg.base & "/login"):
    result.headers[0] = ("Location", toLogin)       # the core refused the token (failed()): the same way as with no session
