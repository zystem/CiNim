## The UI service (docs/ui.md, UI-001, UI-009): pages rendered on the server from what the core's API says, with the token of the user in a cookie and nothing kept here. `handle` takes a request
## and gives a response, and knows the core only as a `CoreApi`: the tests give it one that says what they want, `main.nim` gives it the real one and makes it a server.
##   POST /runs/<id>/abort and /runs/<id>/retry (the buttons of a run's page).
##   /login, /logout, /orgs, /orgs/<slug>/runs, /runs, /runs/<id>, /runs/<id>/steps/<n>/log, /status, /static/ui.css  (all under the prefix `base`), and /healthz outside it.
## A page that needs a session sends a visitor without one to the login and brings them back; a token that the core refuses ends the session; what a page puts in a link to the core is checked
## first (a slug, an id, a number), so that an address cannot reach further than the page it names.
import std/[json, strutils, tables, times, uri, os, hashes, algorithm, sequtils]
import nimja
import render, coreapi

type
  UiConfig* = object
    base*: string                    ## the prefix of the UI in the address ("/ui", or "" at the root)
    secureCookie*: bool              ## the cookie says Secure: set it when the UI is reached over HTTPS

  UiRequest* = object
    meth*, path*, query*, cookie*, host*, origin*, secFetchSite*: string
    form*: Table[string, string]
    formPairs*: seq[(string, string)]                  ## every name and value of a form, in order: a field that is there several times (the boxes of a list) keeps all its values

  UiResponse* = object
    status*: int
    headers*: seq[(string, string)]
    body*: string

  OrgRow = object
    slug, name, state, namespace: string
  RunItem = object
    id, short, state, organization, project, pipeline, repository, source, created, updated, failure, took: string
  StateLink = object
    name, link: string
    active: bool
  ParamRow = object
    name, value: string
  StepRow = object
    seq, attempt: int
    state, exitCode, termination, pod, took, pending: string        ## `pending`: why a step that is PENDING is not running (D-94)
  RunView = object
    id, state, organization, project, created, updated, repository, commit, path, waitReason, failureCode, failureMessage, took: string
    queue: string                    ## D-94: why a QUEUED run is not led yet
    approval: string                 ## D-93: what the run waits for, or how the wait ended
    canApprove: bool                 ## approve / reject buttons
    canAbort, canRetry: bool         ## the buttons of the page: `actions` of the run, as the core says them
    params: seq[ParamRow]
    steps: seq[StepRow]
  LogLine = object
    n: int
    text: string
  RunLogLine = object
    step, ln: int
    label, text: string
  ComponentRow = object
    kind, id, state, seen: string
  RoleRow = object
    name, description: string
    builtin: bool
    count: int
  PermRow = object
    name, level, text: string
    held: bool
  RoleView = object
    name, description: string
    builtin, isNew, editable: bool
    perms: seq[PermRow]
  MemberRow = object
    user, roles: string
  MapRow = object
    id, directory, groupDn, role: string
  AccountRow = object
    account, directory, dn, roles: string
    off: bool
  TeamMemberRow = object
    user, source: string
  TeamRow = object
    name, description, ldap, roles: string
    members: seq[TeamMemberRow]
  DirRow = object
    name, url, warnings, lastSync: string
    priority: int
    autoCreate, enabled, startTls: bool

const
  cookieName = "cinim_ui"
  orgCookieName = "cinim_org"        # the organisation chosen at the last login, so that the list shows it again (not a secret; it is only a default)
  logWindow = 200
  runLogWindow = 200         ## the log of a run: this many lines to a window (DAT-007)
  runsPerPage = 50
  sessionMax = 8 * 3600
  templateDir = currentSourcePath().parentDir / "templates"
  css = staticRead("ui.css")
  cssVersion = toHex(int64(hash(css)), 8)       # in the link: a new style sheet is a new address, and the day of caching does not hold back a change
  runStates = ["QUEUED", "WAITING", "RUNNING", "OK", "FAILED", "ABORTED", "TIMED_OUT"]   # the core's word (RUN_STATE_ABORTED); a state that is spelled two ways is a filter that matches nothing

func isDirName(s: string): bool =
  if s.len < 1 or s.len > 40 or s[0] notin {'a' .. 'z'}: return false
  for c in s:
    if c notin {'a' .. 'z', '0' .. '9', '_', '-'}: return false
  true

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

const finalRunStates = ["OK", "FAILED", "ABORTED", "SKIPPED", "TIMED_OUT", "INFRASTRUCTURE_ERROR"]

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

func orgOfCookie(cookie: string): string =
  for part in cookie.split(';'):
    let p = part.strip
    if p.startsWith(orgCookieName & "="):
      let v = p[orgCookieName.len + 1 .. ^1]
      if v == "local" or isSlug(v): return v

func tokenOf(cookie: string): string =
  for part in cookie.split(';'):
    let p = part.strip
    if p.startsWith(cookieName & "="):
      let v = p[cookieName.len + 1 .. ^1]
      if v.len in 1 .. 512:
        for c in v:
          if c notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '~', '-', ':', '+'}: return ""
        return v

var
  hideRuns {.threadvar.}: bool        ## the menu of the request being served: what the core says the caller cannot use is not shown (D-84; the core refuses it all the same)
  hideStatus {.threadvar.}: bool
  hideAccess {.threadvar.}: bool
  meNode {.threadvar.}: JsonNode      ## GET /api/v1/me of the request being served, for the pages that show a form only to those who may use it

func listHas(n: JsonNode; name: string): bool =
  if not n.isKind(JArray): return false
  for x in n.elems:
    if x.kind == JString and x.getStr == name: return true

func covers(bound, group: string): bool = bound.len > 0 and (group == bound or group.startsWith(bound & "/"))

func holdsAnywhere(me: JsonNode; perm: string): bool =
  ## whether /me says the caller holds `perm` at the shard, in some organisation or on some group
  if me.isNil or not me.isKind(JObject): return false
  if me{"administrator"}.getBool: return true
  let perms = me{"permissions"}
  if not perms.isKind(JObject): return false
  if listHas(perms{"shard"}, perm): return true
  if perms{"organizations"}.isKind(JObject):
    for _, l in perms["organizations"]:
      if listHas(l, perm): return true
  if perms{"groups"}.isKind(JObject):
    for _, arr in perms["groups"]:
      if arr.isKind(JArray):
        for g in arr.elems:
          if listHas(g{"permissions"}, perm): return true

proc can(perm, org, group: string): bool =
  ## whether /me says the caller holds `perm` here: at the shard, in the organisation, or on the group (or above it). False when the core did not say.
  let me = meNode
  if me.isNil or not me.isKind(JObject): return false
  if me{"administrator"}.getBool: return true
  let perms = me{"permissions"}
  if not perms.isKind(JObject): return false
  if listHas(perms{"shard"}, perm): return true
  if org.len == 0: return false
  if perms{"organizations"}.isKind(JObject) and listHas(perms["organizations"]{org}, perm): return true
  if group.len > 0 and perms{"groups"}.isKind(JObject) and perms["groups"]{org}.isKind(JArray):
    for g in perms["groups"][org].elems:
      if covers(g{"path"}.getStr, group) and listHas(g{"permissions"}, perm): return true

proc setMenu(api: CoreApi; token: string) =
  ## asks GET /api/v1/me what the caller comes to, and hides the entries of the menu that would only be a 403. If the core does not say, everything is shown.
  hideRuns = false
  hideStatus = false
  hideAccess = false
  meNode = nil
  let r = api.get(token, "/api/v1/me")
  if r.status != asOk or not r.body.isKind(JObject): return
  meNode = r.body
  if r.body{"administrator"}.getBool or not r.body{"permissions"}.isKind(JObject): return
  hideRuns = not holdsAnywhere(r.body, "run.read")
  hideStatus = not listHas(r.body{"permissions"}{"shard"}, "shard.read")
  hideAccess = not (holdsAnywhere(r.body, "access.read") or holdsAnywhere(r.body, "ldap.read") or holdsAnywhere(r.body, "role.manage"))

# ------------------------------------------------------------------ the pages (templates/*.nimja: every expression through h() or raw(), tests/unit/ttemplates.nim)

proc renderLogin(base, message, user, next, chosen: string; orgs: seq[OrgRow]): string =
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

proc renderRunLog(base, runId, runState: string; lines: seq[RunLogLine]; earlier, later, newest: string): string =
  let loggedIn = true
  compileTemplateFile("runlog.nimja", templateDir)

proc renderStatus(base: string; components: seq[ComponentRow]): string =
  let loggedIn = true
  compileTemplateFile("status.nimja", templateDir)

proc renderRoles(base: string; roles: seq[RoleRow]; canManage: bool): string =
  let loggedIn = true
  compileTemplateFile("roles.nimja", templateDir)

proc renderRole(base: string; role: RoleView): string =
  let loggedIn = true
  compileTemplateFile("role.nimja", templateDir)

proc renderMembers(base, scopeText, group, here, orgMembers: string; members: seq[MemberRow]; roleNames: seq[string]; canEdit: bool): string =
  let loggedIn = true
  compileTemplateFile("members.nimja", templateDir)

proc renderTeams(base, org, here: string; teams: seq[TeamRow]; roleNames: seq[string]; canEdit: bool): string =
  let loggedIn = true
  compileTemplateFile("teams.nimja", templateDir)

proc renderLdap(base, org, here: string; dirs: seq[DirRow]; maps: seq[MapRow]; accounts: seq[AccountRow]; roleNames: seq[string]; canMap, canWrite: bool): string =
  let loggedIn = true
  compileTemplateFile("ldap.nimja", templateDir)

# ------------------------------------------------------------------ the handlers

proc loginOrgs(api: CoreApi): seq[OrgRow] =
  ## the organisations that have a directory, for the list of the login form (D-87); none when the core does not say, and then the form is the plain one
  if api.loginOptions == nil: return
  let r = api.loginOptions()
  if r.status != asOk: return
  for o in r.body{"organizations"}.getElems:
    let slug = o{"slug"}.getStr
    if isSlug(slug): result.add OrgRow(slug: slug, name: o{"name"}.getStr)

proc loginPage(cfg: UiConfig; api: CoreApi; status: int; message, user, next: string; chosen = ""): UiResponse =
  page(status, renderLogin(cfg.base, message, user, next, chosen, api.loginOrgs))

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

const localAccount = "local"          ## the value of the list for a user of the shard itself (no organisation)

proc doLogin(cfg: UiConfig; api: CoreApi; req: UiRequest): UiResponse =
  let user = req.form.getOrDefault("user")
  let next = req.form.getOrDefault("next")
  # D-87: when some organisation has a directory the form has a list to choose the organisation from, and a choice is required (`local`: a user of the shard); the core is given `login@organisation`
  let orgs = api.loginOrgs
  let chosen = req.form.getOrDefault("organization")
  var name = user
  if orgs.len > 0:
    if chosen.len == 0 or (chosen != localAccount and not orgs.anyIt(it.slug == chosen)):
      return loginPage(cfg, api, 400, "Choose the organisation you log in to (or Local account).", user, next)
    if chosen != localAccount:
      if '@' in user: return loginPage(cfg, api, 400, "Write the login without @organisation: the organisation is chosen in the list.", user, next, chosen)
      name = user & "@" & chosen
  let r = api.login(name, req.form.getOrDefault("password"))
  case r.status
  of asOk:
    if r.body{"password_change_required"}.getBool:
      return messagePage(cfg, 403, false, "Change the password first",
        "This user has to change the password before anything else; the UI does not do that. Use the API:", "PUT /api/v1/users/" & r.body{"user"}.getStr(user) & "/password",
        cfg.base & "/login", "Back to the login")
    let token = r.body{"token"}.getStr
    let left = r.body{"expires_at"}.getBiggestInt(0) - getTime().toUnix()
    let maxAge = int(min(max(left, 60), sessionMax))
    result = redirect(safeNext(cfg, next), sessionCookie(cfg, token, maxAge))
    if orgs.len > 0:
      result.headers.add ("Set-Cookie", orgCookieName & "=" & chosen & "; Path=" & cookiePath(cfg) & "; SameSite=Strict; Max-Age=31536000" & (if cfg.secureCookie: "; Secure" else: ""))
  of asUnauthorized:
    result = loginPage(cfg, api, 401, "Wrong user name or password.", user, next, chosen)
  of asRefused:
    result = loginPage(cfg, api, (if r.code == 429: 429 else: 502), "The login was refused: " & r.message & ".", user, next, chosen)
  else:
    result = messagePage(cfg, 503, false, "The core does not answer", "Try again in a moment.", r.message, cfg.base & "/login", "Back to the login")

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
    runs.add RunItem(id: x{"id"}.getStr, short: shortRunId(x{"id"}.getStr), state: (if x{"pending"}.getBool: "PENDING" else: x{"state"}.getStr), organization: x{"organization"}.getStr,
                     project: x{"project"}.getStr, pipeline: x{"source"}{"path"}.getStr, repository: x{"source"}{"repository"}.getStr, source: (if commit.len > 7: commit[0 ..< 7] else: commit),
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
  var v = RunView(id: j{"id"}.getStr, state: j{"state"}.getStr, organization: j{"organization"}.getStr, project: j{"project"}.getStr,
                  created: timeText(j{"created_at"}.getStr), updated: timeText(j{"updated_at"}.getStr), waitReason: j{"wait_reason"}.getStr,
                  failureCode: j{"failure"}{"code"}.getStr, failureMessage: j{"failure"}{"message"}.getStr,
                  took: runTook(j{"state"}.getStr, j{"created_at"}.getStr, j{"updated_at"}.getStr, getTime().toUnix),
                  repository: j{"source"}{"repository"}.getStr, commit: j{"source"}{"commit"}.getStr, path: j{"source"}{"path"}.getStr)
  if not isSlug(v.organization): v.organization = ""
  v.canAbort = j{"actions"}{"abort"}.getBool        # the core's word: the state of the run allows it and so do the rights of this user in this organisation
  v.canRetry = j{"actions"}{"retry"}.getBool
  v.canApprove = j{"actions"}{"approve"}.getBool
  v.queue = j{"queue"}{"reason"}.getStr
  if j{"pending"}.isKind(JObject) and v.state == "RUNNING":
    v.state = "PENDING"                                  # D-94: led, but nothing of it runs: its steps wait for a place
    v.queue = j["pending"]{"reason"}.getStr
  if j{"approval"}.isKind(JObject):
    let a = j["approval"]
    let by = a{"approved_by"}.getElems.mapIt(it.getStr).join(", ")
    v.approval = $a{"approved_by"}.getElems.len & " of " & $a{"required"}.getInt & " approval" & (if a{"required"}.getInt > 1: "s" else: "") & (if by.len > 0: " (" & by & ")" else: "") &
      (if a{"rejected_by"}.getElems.len > 0: ", rejected by " & a{"rejected_by"}.getElems.mapIt(it.getStr).join(", ") else: "") &
      (if a{"waiting"}.getBool and a{"deadline"}.getBiggestInt > 0: "; waits until " & fromUnix(a["deadline"].getBiggestInt).utc.format("yyyy-MM-dd HH:mm") & " UTC" else: "")
  if j{"params"}.isKind(JObject):
    for k, x in j["params"]: v.params.add ParamRow(name: k, value: (if x.kind == JString: x.getStr else: $x))
  for s in j{"steps"}.getElems:
    let reason = s{"pod_reason"}.getStr
    v.steps.add StepRow(seq: s{"seq"}.getInt, attempt: s{"attempt"}.getInt, state: s{"state"}.getStr,
                        pending: s{"pending_reason"}.getStr, exitCode: (if s{"exit_code"}.isKind(JInt): $s["exit_code"].getInt else: ""), termination: s{"termination"}.getStr, pod: reason,
                        took: tookText(s{"started_at"}.getInt(0), s{"finished_at"}.getInt(0), s{"finished_at"}.getInt(0) > 0, getTime().toUnix))
  page(200, renderRun(cfg.base, v))

proc runAction(cfg: UiConfig; api: CoreApi; req: UiRequest; token, id, action: string): UiResponse =
  ## The buttons of a run's page (RUN-006 abort, PIP-015 retry): a POST that asks the core for `POST /api/v1/runs/<id>:<action>` with the token of the user, and goes back to the run.
  ## What the core refuses (the run has ended, nothing failed, the volume is gone, the role may not) is told in words, and the run is left as it is.
  if not sameOrigin(req): return messagePage(cfg, 403, true, "Refused", "The form was not sent from this site.")
  let r = api.post(token, "/api/v1/runs/" & id & ":" & action, (if action in ["approve", "reject"]: $(%*{"comment": req.form.getOrDefault("comment").strip[0 ..< min(500, req.form.getOrDefault("comment").strip.len)]}) else: "{}"))
  let back = cfg.base & "/runs/" & id
  case r.status
  of asOk: redirect(back)
  of asRefused: messagePage(cfg, 409, true, (case action
    of "abort": "The run was not stopped"
    of "approve": "The run was not approved"
    of "reject": "The run was not rejected"
    else: "The run was not started again"), "The core refused.", r.message, back, "Back to the run")
  else: failed(cfg, r, "run " & id)

# ------------------------------------------------------------------ roles, members, directories (D-84, D-85, D-87, D-88)

func isRoleName(s: string): bool =
  if s.len < 1 or s.len > 32 or s[0] notin {'a' .. 'z'}: return false
  for c in s:
    if c notin {'a' .. 'z', '0' .. '9', '_', '-'}: return false
  true

func isAccountName(s: string): bool =
  ## a local user, `login@slug`, or a team `team:name`: lowercase letters, digits and . _ - @ :
  if s.len < 1 or s.len > 100: return false
  for c in s:
    if c notin {'a' .. 'z', '0' .. '9', '.', '_', '-', '@', ':'}: return false
  true

func isLogin(s: string): bool =
  if s.len < 1 or s.len > 64: return false
  for c in s:
    if c notin {'a' .. 'z', '0' .. '9', '.', '_', '-'}: return false
  true

func isPermName(s: string): bool =
  if s.len < 3 or s.len > 40: return false
  for c in s:
    if c notin {'a' .. 'z', '.'}: return false
  true

func isGroupPath(s: string): bool =
  let segs = s.split('/')
  if segs.len < 1 or segs.len > 8: return false
  for seg in segs:
    if not isSlug(seg): return false
  true

func formAll(req: UiRequest; key: string): seq[string] =
  for (k, v) in req.formPairs:
    if k == key and v notin result: result.add v

proc explained(cfg: UiConfig; api: CoreApi; token: string; r: ApiResult; what, meth, apiPath: string): UiResponse =
  ## like `failed`, and for a 403 says why, in the words of GET /api/v1/me/can: which permission the call needs, where, and what the caller has
  if r.status != asForbidden: return failed(cfg, r, what)
  let e = api.get(token, "/api/v1/me/can?method=" & meth & "&path=" & encodeUrl(apiPath, usePlus = false))
  var detail = r.message
  if e.status == asOk:
    let need = e.body{"permission"}.getStr
    detail = (if need.len > 0: "needs " & need & " " & e.body{"needs"}.getStr & ". " else: "") & e.body{"reason"}.getStr
  messagePage(cfg, 403, true, "Not allowed", "Your user may not do this: " & what & ".", detail)

proc afterAction(cfg: UiConfig; api: CoreApi; token: string; r: ApiResult; goTo, title, what, meth, apiPath: string): UiResponse =
  ## the end of a form: back to the page on success, the core's words when it refused, the reason when the right is missing
  case r.status
  of asOk: redirect(goTo)
  of asRefused: messagePage(cfg, 409, true, title, "The core refused.", r.message, goTo, "Back")
  else: explained(cfg, api, token, r, what, meth, apiPath)

proc roleNamesOf(api: CoreApi; token: string): seq[string] =
  let r = api.get(token, "/api/v1/roles")
  if r.status == asOk:
    for x in r.body{"roles"}.getElems:
      if isRoleName(x{"name"}.getStr): result.add x{"name"}.getStr

proc rolesPage(cfg: UiConfig; api: CoreApi; token: string): UiResponse =
  let r = api.get(token, "/api/v1/roles")
  if r.status != asOk: return explained(cfg, api, token, r, "the list of roles", "GET", "/api/v1/roles")
  var rows: seq[RoleRow]
  for x in r.body{"roles"}.getElems:
    if isRoleName(x{"name"}.getStr):
      rows.add RoleRow(name: x["name"].getStr, description: x{"description"}.getStr, builtin: x{"builtin"}.getBool, count: x{"permissions"}.getElems.len)
  page(200, renderRoles(cfg.base, rows, can("role.manage", "", "")))

proc rolePage(cfg: UiConfig; api: CoreApi; token, name: string; isNew: bool): UiResponse =
  let cat = api.get(token, "/api/v1/permissions")
  if cat.status != asOk: return explained(cfg, api, token, cat, "the list of permissions", "GET", "/api/v1/permissions")
  var view = RoleView(name: name, isNew: isNew, editable: can("role.manage", "", ""))
  var held: seq[string]
  if not isNew:
    let r = api.get(token, "/api/v1/roles")
    if r.status != asOk: return explained(cfg, api, token, r, "the list of roles", "GET", "/api/v1/roles")
    var found = false
    for x in r.body{"roles"}.getElems:
      if x{"name"}.getStr == name:
        found = true
        view.description = x{"description"}.getStr
        view.builtin = x{"builtin"}.getBool
        for p in x{"permissions"}.getElems: held.add p.getStr
    if not found: return messagePage(cfg, 404, true, "Not found", "No such role.", "", cfg.base & "/roles", "Roles")
    if view.builtin: view.editable = false
  for p in cat.body{"permissions"}.getElems:
    if isPermName(p{"name"}.getStr):
      view.perms.add PermRow(name: p["name"].getStr, level: p{"level"}.getStr, text: p{"description"}.getStr, held: p["name"].getStr in held)
  page(200, renderRole(cfg.base, view))

proc saveRole(cfg: UiConfig; api: CoreApi; req: UiRequest; token, nameGiven: string): UiResponse =
  ## the form of a role: a new one (`nameGiven` empty: the name is in the form) or a custom one that changes
  let name = if nameGiven.len > 0: nameGiven else: req.form.getOrDefault("name")
  if not isRoleName(name): return messagePage(cfg, 400, true, "Not saved", "A role name is lowercase letters, digits, - and _, starting with a letter, at most 32.", "", cfg.base & "/roles", "Roles")
  var perms: seq[string]
  for p in req.formAll("perm"):
    if isPermName(p): perms.add p
  let desc = req.form.getOrDefault("description")
  let r = api.send("PUT", token, "/api/v1/roles/" & name, $(%*{"description": desc[0 ..< min(200, desc.len)], "permissions": perms}))
  afterAction(cfg, api, token, r, cfg.base & "/roles/" & name, "The role was not saved", "role " & name, "PUT", "/api/v1/roles/" & name)

proc deleteRole(cfg: UiConfig; api: CoreApi; token, name: string): UiResponse =
  let r = api.send("DELETE", token, "/api/v1/roles/" & name, "")
  afterAction(cfg, api, token, r, cfg.base & "/roles", "The role was not deleted", "delete role " & name, "DELETE", "/api/v1/roles/" & name)

type Target = object
  ## where a members page is: the organisation, or a group or project of it
  ok: bool
  slug, group, kind: string          ## kind: "groups" or "projects" ("" for the organisation)

func targetOf(parts: seq[string]; endAt: int): Target =
  ## parts[0 ..< endAt] is `orgs/<slug>` or `orgs/<slug>/groups|projects/<path...>`
  if endAt < 2 or parts[0] != "orgs" or not isSlug(parts[1]): return
  result.slug = parts[1]
  if endAt == 2: (result.ok = true; return)
  if parts[2] notin ["groups", "projects"] or endAt < 4: (result.slug = ""; return)
  result.kind = parts[2]
  result.group = parts[3 ..< endAt].join("/")
  result.ok = isGroupPath(result.group)

func apiBase(t: Target): string =
  "/api/v1/organizations/" & t.slug & (if t.kind.len > 0: "/" & t.kind & "/" & t.group else: "")

func uiBase(cfg: UiConfig; t: Target): string =
  cfg.base & "/orgs/" & t.slug & (if t.kind.len > 0: "/" & t.kind & "/" & t.group else: "")

proc membersPage(cfg: UiConfig; api: CoreApi; token: string; t: Target): UiResponse =
  let r = api.get(token, t.apiBase & "/members")
  if r.status != asOk: return explained(cfg, api, token, r, "the members of " & t.slug & (if t.group.len > 0: "/" & t.group else: ""), "GET", t.apiBase & "/members")
  var rows: seq[MemberRow]
  for m in r.body{"members"}.getElems:
    var roles: seq[string]
    for x in m{"roles"}.getElems:
      # D-92: what a role is tied to, said after its name
      let cond = m{"conditions"}{x.getStr}
      var tied: seq[string]
      if cond != nil and cond.kind == JObject:
        if cond{"expires_at"} != nil and cond{"expires_at"}.kind == JInt: tied.add((if cond{"expired"}.getBool: "ended " else: "until ") & fromUnix(cond["expires_at"].getBiggestInt).utc.format("yyyy-MM-dd HH:mm") & " UTC")
        if cond{"only_own"}.getBool: tied.add "own runs only"
        if cond{"refs"} != nil and cond{"refs"}.kind == JArray: tied.add "refs " & cond["refs"].getElems.mapIt(it.getStr).join(", ")
      roles.add x.getStr & (if tied.len > 0: " (" & tied.join("; ") & ")" else: "")
    if isAccountName(m{"user"}.getStr): rows.add MemberRow(user: m["user"].getStr, roles: roles.join(", "))
  let here = cfg.base & "/orgs/" & t.slug & (if t.kind.len > 0: "/" & t.kind & "/" & t.group else: "") & "/members"
  let canEdit = can("access.write", t.slug, t.group)
  page(200, renderMembers(cfg.base, "organisation " & t.slug & (if t.group.len > 0: ", " & t.group else: ""), t.group, here, cfg.base & "/orgs/" & t.slug & "/members", rows, (if canEdit: api.roleNamesOf(token) else: @[]), canEdit))

proc setMember(cfg: UiConfig; api: CoreApi; req: UiRequest; token: string; t: Target; remove: bool): UiResponse =
  let user = req.form.getOrDefault("user")
  let here = uiBase(cfg, t) & "/members"
  if not isAccountName(user): return messagePage(cfg, 400, true, "Not saved", "Name the person: an account that exists.", "", here, "Back")
  var roles: seq[JsonNode]
  if not remove:
    # D-92: a term (a date, to the end of that day, UTC), the person's own runs only, and refs (one to a line or separated by commas) apply to every role ticked
    var cond = newJObject()
    let until = req.form.getOrDefault("until").strip
    if until.len > 0:
      if until.len != 10 or until[4] != '-' or until[7] != '-' or not (until[0 ..< 4] & until[5 ..< 7] & until[8 ..< 10]).allIt(it in {'0' .. '9'}):
        return messagePage(cfg, 400, true, "Not saved", "The term is a date: year-month-day.", "", here, "Back")
      cond["expires_at"] = %(until & "T23:59:59Z")
    if req.form.getOrDefault("only_own") == "1": cond["only_own"] = %true
    let refs = req.form.getOrDefault("refs").replace(',', '\n').splitLines.mapIt(it.strip).filterIt(it.len > 0)
    if refs.len > 0: cond["refs"] = %refs
    for x in req.formAll("role"):
      if isRoleName(x):
        if cond.len == 0: roles.add %x
        else:
          var item = copy(cond)
          item["role"] = %x
          roles.add item
  let path = t.apiBase & "/members/" & user
  let r = if remove: api.send("DELETE", token, path, "") else: api.send("PUT", token, path, $(%*{"roles": roles}))
  afterAction(cfg, api, token, r, here, "The roles were not changed", "the roles of " & user, (if remove: "DELETE" else: "PUT"), path)

proc teamsPage(cfg: UiConfig; api: CoreApi; token, slug: string): UiResponse =
  let base = "/api/v1/organizations/" & slug & "/teams"
  let r = api.get(token, base)
  if r.status != asOk: return explained(cfg, api, token, r, "the teams of " & slug, "GET", base)
  var rows: seq[TeamRow]
  for t in r.body{"teams"}.getElems:
    if not isDirName(t{"name"}.getStr): continue
    var row = TeamRow(name: t["name"].getStr, description: t{"description"}.getStr)
    if t{"ldap"}.isKind(JObject): row.ldap = t["ldap"]{"group_dn"}.getStr & (if t["ldap"]{"directory"}.getStr.len > 0: " (" & t["ldap"]{"directory"}.getStr & ")" else: "")
    for m in t{"members"}.getElems:
      if isAccountName(m{"user"}.getStr): row.members.add TeamMemberRow(user: m["user"].getStr, source: (if m{"source"}.getStr.len == 0: "by hand" else: "from the directory"))
    var roles: seq[string]
    for x in t{"roles"}.getElems: roles.add x{"role"}.getStr & " (" & x{"scope"}.getStr & ")"
    row.roles = roles.join(", ")
    rows.add row
  let canEdit = can("access.write", slug, "")
  page(200, renderTeams(cfg.base, slug, cfg.base & "/orgs/" & slug & "/teams", rows, (if canEdit: api.roleNamesOf(token) else: @[]), canEdit))

proc teamsAction(cfg: UiConfig; api: CoreApi; req: UiRequest; token, slug: string; rest: seq[string]): UiResponse =
  ## the forms of the Teams page
  let base = "/api/v1/organizations/" & slug & "/teams"
  let back = cfg.base & "/orgs/" & slug & "/teams"
  let f = req.form
  if rest.len == 0:
    let name = f.getOrDefault("name")
    let dn = f.getOrDefault("group_dn")
    let directory = f.getOrDefault("directory")
    if not isDirName(name) or dn.len > 500 or (directory.len > 0 and not isDirName(directory)): return messagePage(cfg, 400, true, "Not made", "A team is named by lowercase letters, digits, - and _.", "", back, "Back")
    var body = %*{"description": f.getOrDefault("description")[0 ..< min(300, f.getOrDefault("description").len)]}
    if dn.len > 0: body["ldap"] = %*{"group_dn": dn, "directory": directory}
    let r = api.send("PUT", token, base & "/" & name, $body)
    return afterAction(cfg, api, token, r, back, "The team was not made", "make the team " & name, "PUT", base & "/" & name)
  if rest.len >= 2 and isDirName(rest[0]):
    let name = rest[0]
    if rest == @[name, "delete"]:
      let r = api.send("DELETE", token, base & "/" & name, "")
      return afterAction(cfg, api, token, r, back, "The team was not deleted", "delete the team " & name, "DELETE", base & "/" & name)
    if rest == @[name, "members"] or rest == @[name, "members", "remove"]:
      let user = f.getOrDefault("user")
      if not isAccountName(user) or user.startsWith("team:"): return messagePage(cfg, 400, true, "Not saved", "Name the person: an account that exists.", "", back, "Back")
      let remove = rest.len == 3
      let r = api.send(if remove: "DELETE" else: "PUT", token, base & "/" & name & "/members/" & user, "")
      return afterAction(cfg, api, token, r, back, "The member was not changed", "change the members of " & name, (if remove: "DELETE" else: "PUT"), base & "/" & name & "/members/" & user)
    if rest == @[name, "roles"]:
      var roles: seq[string]
      for x in req.formAll("role"):
        if isRoleName(x): roles.add x
      let path = "/api/v1/organizations/" & slug & "/members/team:" & name
      let r = api.send("PUT", token, path, $(%*{"roles": roles}))
      return afterAction(cfg, api, token, r, back, "The roles were not changed", "the roles of the team " & name, "PUT", path)
  messagePage(cfg, 404, true, "Not found", "There is no such page.", "", cfg.base & "/orgs", "Organisations")

proc ldapPage(cfg: UiConfig; api: CoreApi; token, slug: string): UiResponse =
  let base = "/api/v1/organizations/" & slug & "/ldap"
  let r = api.get(token, base)
  if r.status != asOk: return explained(cfg, api, token, r, "the directories of " & slug, "GET", base)
  var dirs: seq[DirRow]
  for d in r.body{"directories"}.getElems:
    var w: seq[string]
    for x in d{"warnings"}.getElems: w.add x.getStr
    if isDirName(d{"name"}.getStr):
      let at = d{"last_sync_at"}.getBiggestInt(0)
      dirs.add DirRow(name: d["name"].getStr, url: d{"url"}.getStr, warnings: w.join(" "), priority: int(d{"priority"}.getBiggestInt(0)),
                      autoCreate: d{"auto_create"}.getBool, enabled: d{"enabled"}.getBool(true), startTls: d{"start_tls"}.getBool,
                      lastSync: (if at > 0: timeText($at) & " - " & d{"last_sync_result"}.getStr else: "never"))
  var maps: seq[MapRow]
  for m in r.body{"mappings"}.getElems:
    if isId(m{"id"}.getStr): maps.add MapRow(id: m["id"].getStr, directory: m{"directory"}.getStr, groupDn: m{"group_dn"}.getStr, role: m{"role"}.getStr)
  var accounts: seq[AccountRow]
  for a in r.body{"accounts"}.getElems:
    var roles: seq[string]
    for x in a{"roles_from_directory"}.getElems: roles.add x.getStr
    if isAccountName(a{"account"}.getStr):
      accounts.add AccountRow(account: a["account"].getStr, directory: a{"directory"}.getStr, dn: a{"dn"}.getStr, roles: roles.join(", "), off: a{"switched_off"}.getBool)
  let canMap = can("ldap.map", slug, "")
  page(200, renderLdap(cfg.base, slug, cfg.base & "/orgs/" & slug & "/ldap", dirs, maps, accounts, (if canMap: api.roleNamesOf(token) else: @[]), canMap, can("ldap.write", "", "")))

proc ldapAction(cfg: UiConfig; api: CoreApi; req: UiRequest; token, slug: string; rest: seq[string]): UiResponse =
  ## the forms of the Directory page: add or remove a group that gives a role, make or remove an account, sync a directory, check one
  let base = "/api/v1/organizations/" & slug & "/ldap"
  let back = cfg.base & "/orgs/" & slug & "/ldap"
  let f = req.form
  if rest == @["mappings"]:
    let dn = f.getOrDefault("group_dn")
    let directory = f.getOrDefault("directory")
    if dn.len < 3 or dn.len > 500 or not isRoleName(f.getOrDefault("role")) or (directory.len > 0 and not isDirName(directory)):
      return messagePage(cfg, 400, true, "Not saved", "Give the DN of a group and a role.", "", back, "Back")
    let r = api.send("POST", token, base & "/mappings", $(%*{"group_dn": dn, "role": f["role"], "directory": directory}))
    return afterAction(cfg, api, token, r, back, "The group was not added", "map a group", "POST", base & "/mappings")
  if rest.len == 3 and rest[0] == "mappings" and isId(rest[1]) and rest[2] == "delete":
    let r = api.send("DELETE", token, base & "/mappings/" & rest[1], "")
    return afterAction(cfg, api, token, r, back, "The group was not removed", "remove a group", "DELETE", base & "/mappings/" & rest[1])
  if rest == @["accounts"]:
    let login = f.getOrDefault("login")
    let directory = f.getOrDefault("directory")
    if not isLogin(login) or (directory.len > 0 and not isDirName(directory)): return messagePage(cfg, 400, true, "Not made", "Give the login of a person the directory knows.", "", back, "Back")
    let r = api.send("PUT", token, base & "/accounts/" & login, $(%*{"directory": directory}))
    return afterAction(cfg, api, token, r, back, "The account was not made", "make the account of " & login, "PUT", base & "/accounts/" & login)
  if rest == @["accounts", "remove"]:
    let account = f.getOrDefault("login")
    let at = account.find('@')
    let login = if at > 0: account[0 ..< at] else: account
    if not isLogin(login): return messagePage(cfg, 400, true, "Not removed", "Name the account.", "", back, "Back")
    let r = api.send("DELETE", token, base & "/accounts/" & login, "")
    return afterAction(cfg, api, token, r, back, "The account was not removed", "remove the account of " & login, "DELETE", base & "/accounts/" & login)
  if rest.len == 3 and rest[0] == "servers" and isDirName(rest[1]) and rest[2] == "sync":
    let r = api.send("POST", token, base & "/servers/" & rest[1] & ":sync", "{}")
    return afterAction(cfg, api, token, r, back, "The sync did not run", "sync " & rest[1], "POST", base & "/servers/" & rest[1] & ":sync")
  if rest == @["check"]:
    let directory = f.getOrDefault("directory")
    let user = f.getOrDefault("user")
    if not isDirName(directory) or (user.len > 0 and not isLogin(user)): return messagePage(cfg, 400, true, "Not checked", "Choose a directory and write a login or leave it empty.", "", back, "Back")
    let r = api.send("POST", token, base & "/servers/" & directory & ":check", $(%*{"user": user}))
    if r.status != asOk: return afterAction(cfg, api, token, r, back, "The check did not run", "check " & directory, "POST", base & "/servers/" & directory & ":check")
    var lines: seq[string]
    lines.add (if r.body{"connected"}.getBool: "connected and bound" else: "not connected: " & r.body{"error"}.getStr)
    let person = r.body{"person"}
    if person.isKind(JObject):
      if person{"found"}.getBool:
        var gs, rs: seq[string]
        for g in person{"groups"}.getElems: gs.add g.getStr
        for x in person{"roles"}.getElems: rs.add x.getStr
        lines.add "found " & person{"dn"}.getStr & " (account " & person{"account"}.getStr & "); groups: " & (if gs.len > 0: gs.join("; ") else: "none") & "; roles here: " & (if rs.len > 0: rs.join(", ") else: "none")
      else:
        lines.add "the person was not found" & (if person{"problem"}.getStr.len > 0: ": " & person{"problem"}.getStr else: "")
    return messagePage(cfg, 200, true, "Check of " & directory, "Nothing was changed.", lines.join(" | "), back, "Back to the directory")
  messagePage(cfg, 404, true, "Not found", "There is no such page.", "", cfg.base & "/orgs", "Organisations")

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

func isCursor(s: string): bool =
  ## "<step>.<attempt>.<line>": three numbers (it goes to the core)
  let p = s.split('.')
  if p.len != 3: return false
  for x in p:
    if x.len == 0 or x.len > 12 or not x.allCharsInSet({'0' .. '9'}): return false
  true

proc runLogPage(cfg: UiConfig; api: CoreApi; token, id: string; query: Table[string, string]): UiResponse =
  ## The log of the whole run (DAT-007: a window, never the whole log; D-77): the lines of all its steps in one request, in the order of step, attempt and line, each starting with the label of its step
  ## (`14/0003`, the job's id and the step's, which the core keeps in two fields). The last lines of the run, or the window before or after a cursor the core gave.
  var path = "/api/v1/runs/" & id & "/log?limit=" & $runLogWindow
  let until = query.getOrDefault("until")
  let from0 = query.getOrDefault("from")
  var moved = false
  if from0.len > 0 and isCursor(from0):
    path.add "&from=" & from0
    moved = true
  elif until.len > 0 and isCursor(until):
    path.add "&until=" & until
    moved = true
  let r = api.get(token, path)
  if r.status != asOk: return failed(cfg, r, "log of run " & id)
  var lines: seq[RunLogLine]
  for l in r.body{"lines"}.getElems:
    let step = l{"step"}.getInt(0)
    let label = if l{"job_id"}.getStr.len > 0 and l{"step_id"}.getStr.len > 0: l["job_id"].getStr & "/" & l["step_id"].getStr else: $step
    lines.add RunLogLine(step: step, ln: l{"ln"}.getInt(0), label: label, text: plainText(l{"text"}.getStr))
  let here = cfg.base & "/runs/" & id & "/log"
  var earlier, later: string
  if r.body{"earlier"}.isKind(JString) and isCursor(r.body["earlier"].getStr): earlier = here & "?until=" & r.body["earlier"].getStr
  if r.body{"later"}.isKind(JString) and isCursor(r.body["later"].getStr): later = here & "?from=" & r.body["later"].getStr
  page(200, renderRunLog(cfg.base, id, r.body{"run_state"}.getStr, lines, earlier, later, (if moved: here else: "")))

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
  api.setMenu(token)
  let parts = path.strip(chars = {'/'}).split('/')
  if req.meth == "POST" and parts.len == 3 and parts[0] == "runs" and isId(parts[1]) and parts[2] in ["abort", "retry", "approve", "reject"]:
    return runAction(cfg, api, req, token, parts[1], parts[2])
  if req.meth == "POST":
    # the forms of the access pages: a POST from this host, then the thing is asked of the core with the token of the user
    let isAccessPost = parts == @["new-role"] or (parts.len in [2, 3] and parts[0] == "roles") or (parts.len >= 3 and parts[0] == "orgs" and (parts[2] == "ldap" or parts[2] == "teams" or "members" in parts))
    if isAccessPost:
      if not sameOrigin(req): return messagePage(cfg, 403, true, "Refused", "The form was not sent from this site.")
      if parts == @["new-role"]: return saveRole(cfg, api, req, token, "")
      if parts.len == 2 and parts[1].isRoleName: return saveRole(cfg, api, req, token, parts[1])
      if parts.len == 3 and parts[0] == "roles" and parts[1].isRoleName and parts[2] == "delete": return deleteRole(cfg, api, token, parts[1])
      if parts.len >= 4 and parts[0] == "orgs" and isSlug(parts[1]) and parts[2] == "ldap": return ldapAction(cfg, api, req, token, parts[1], parts[3 .. ^1])
      if parts.len >= 3 and parts[0] == "orgs" and isSlug(parts[1]) and parts[2] == "teams": return teamsAction(cfg, api, req, token, parts[1], parts[3 .. ^1])
      if parts.len >= 4 and parts[^2] == "members" and parts[^1] in ["set", "remove"]:
        let t = targetOf(parts, parts.len - 2)
        if t.ok: return setMember(cfg, api, req, token, t, parts[^1] == "remove")
      return messagePage(cfg, 404, true, "Not found", "There is no such page.", "", cfg.base & "/orgs", "Organisations")
  if req.meth != "GET":
    result = messagePage(cfg, 405, true, "Method not allowed", "GET.")
    result.headers.add ("Allow", "GET")
    return
  if path == "/" or path == "": return redirect(cfg.base & "/orgs")
  if parts == @["roles"]: return rolesPage(cfg, api, token)
  if parts == @["new-role"]: return rolePage(cfg, api, token, "", true)
  if parts.len == 2 and parts[0] == "roles" and parts[1].isRoleName: return rolePage(cfg, api, token, parts[1], false)
  if parts.len >= 3 and parts[0] == "orgs" and parts[^1] == "members":
    let t = targetOf(parts, parts.len - 1)
    if t.ok: return membersPage(cfg, api, token, t)
  if parts.len == 3 and parts[0] == "orgs" and isSlug(parts[1]) and parts[2] == "ldap": return ldapPage(cfg, api, token, parts[1])
  if parts.len == 3 and parts[0] == "orgs" and isSlug(parts[1]) and parts[2] == "teams": return teamsPage(cfg, api, token, parts[1])
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
    return loginPage(cfg, api, 200, "", "", query.getOrDefault("next"), orgOfCookie(req.cookie))
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
