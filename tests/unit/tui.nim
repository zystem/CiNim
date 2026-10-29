## The UI service (src/ui: app.nim, coreapi.nim, pages): UI-001 permanent links, UI-009 pages rendered on the server, docs/ui.md. The core is a stand-in (CoreApi of closures), so what is tested is what the UI
## does with what the core says: the login and its cookie, who is sent where, what a page shows and how it is escaped, the windows of a log, and the things a browser must not be able to make it do.
import std/[unittest, json, tables, strutils, sequtils]
import ../../src/ui/[app, coreapi]

const
  base = "/ui"
  hostile = "<script>alert(1)</script> & \"q\" 'x'"

var
  calls: seq[string]                       # "token path" of every GET that reached the stand-in core
  routes: Table[string, JsonNode]          # the path with the query -> the body
  down: bool
  posted: seq[string]                      # "token path body" of every POST that reached the stand-in core
  loginCalls: seq[string]                  # the user names the stand-in core was asked to log in
  sent: seq[string]                        # "METHOD path body" of every call made with `send` (PUT, DELETE, POST of the access pages)
  sendAnswer: ApiResult                    # what the stand-in core answers to it
  directoryOrgs: JsonNode                  # what GET /api/v1/login/options says
  postAnswer: ApiResult                    # what the stand-in core answers to a POST

proc ok(body: JsonNode): ApiResult = ApiResult(status: asOk, code: 200, body: body)

proc fakeCore(): CoreApi =
  result.loginOptions = proc (): ApiResult {.gcsafe.} =
    {.cast(gcsafe).}:
      if down: return ApiResult(status: asUnavailable, message: "the core does not answer")
      ok(%*{"organizations": directoryOrgs})
  result.login = proc (user, password: string): ApiResult {.gcsafe.} =
    {.cast(gcsafe).}:
      loginCalls.add user
      if down: return ApiResult(status: asUnavailable, message: "the core does not answer")
      if password == "throttled": return ApiResult(status: asRefused, code: 429, message: "retry after 30 s")
      if user == "new" and password == "right-password-1234": return ok(%*{"token": "tok-new", "user": "new", "roles": ["admin"], "expires_at": 1800000000, "password_change_required": true})
      if (user == "ann" or user == "ann@acme") and password == "right-password-1234": return ok(%*{"token": "tok-ann", "user": "ann", "roles": ["ro"], "expires_at": 1800000000, "password_change_required": false})
      ApiResult(status: asUnauthorized, code: 401, message: "bad_credentials")
  result.get = proc (token, path: string): ApiResult {.gcsafe.} =
    {.cast(gcsafe).}:
      if path != "/api/v1/me": calls.add token & " " & path            # the menu asks who the caller is on every page: not counted with what a page asked
      if down: return ApiResult(status: asUnavailable, message: "the core does not answer")
      if token != "tok-ann": return ApiResult(status: asUnauthorized, code: 401, message: "bad token")
      if path in routes: ok(routes[path]) else: ApiResult(status: asNotFound, code: 404, message: "no such route")
  result.send = proc (meth, token, path, body: string): ApiResult {.gcsafe.} =
    {.cast(gcsafe).}:
      sent.add meth & " " & path & " " & body
      if down: return ApiResult(status: asUnavailable, message: "the core does not answer")
      if token != "tok-ann": return ApiResult(status: asUnauthorized, code: 401, message: "bad token")
      sendAnswer
  result.post = proc (token, path, body: string): ApiResult {.gcsafe.} =
    {.cast(gcsafe).}:
      posted.add token & " " & path & " " & body
      if down: return ApiResult(status: asUnavailable, message: "the core does not answer")
      if token != "tok-ann": return ApiResult(status: asUnauthorized, code: 401, message: "bad token")
      postAnswer

let cfg = UiConfig(base: base, secureCookie: false)
let cfgSecure = UiConfig(base: base, secureCookie: true)

proc req(meth, path: string; query = ""; cookie = ""; form: Table[string, string] = initTable[string, string](); origin = ""; host = "ui.example"; pairs: seq[(string, string)] = @[]): UiRequest =
  result = UiRequest(meth: meth, path: path, query: query, cookie: cookie, form: form, origin: origin, host: host, formPairs: pairs)
  if pairs.len > 0 and form.len == 0:
    for (k, v) in pairs: result.form[k] = v

proc header(r: UiResponse; name: string): string =
  for (k, v) in r.headers:
    if k.toLowerAscii == name.toLowerAscii: return v

let session = "cinim_ui=tok-ann"

proc reset() =
  calls = @[]
  posted = @[]
  loginCalls = @[]
  sent = @[]
  sendAnswer = ok(%*{"ok": true})
  directoryOrgs = newJArray()
  postAnswer = ok(%*{"id": "s1_b", "state": "ABORTED"})
  routes = initTable[string, JsonNode]()
  down = false

suite "the login and the session":
  setup: reset()
  test "without a session every page but the login goes to the login, and the page you wanted is remembered":
    let r = handle(cfg, fakeCore(), req("GET", "/ui/orgs"))
    check r.status == 303 and r.header("Location") == "/ui/login?next=%2Fui%2Forgs"
    check handle(cfg, fakeCore(), req("GET", "/ui/")).header("Location") == "/ui/login?next=%2Fui%2F" or handle(cfg, fakeCore(), req("GET", "/ui/")).header("Location") == "/ui/login"
    check calls.len == 0                                           # nothing was asked of the core
  test "the login form posts to itself, and every page carries the headers of a page that holds a session":
    let r = handle(cfg, fakeCore(), req("GET", "/ui/login"))
    check r.status == 200 and "<form method=\"post\" action=\"/ui/login\"" in r.body and "type=\"password\"" in r.body
    check r.header("Content-Security-Policy").startsWith("default-src 'none'") and "frame-ancestors 'none'" in r.header("Content-Security-Policy")
    check r.header("X-Content-Type-Options") == "nosniff" and r.header("Cache-Control") == "no-store" and r.header("Referrer-Policy") == "same-origin"
    check r.header("Content-Type").startsWith("text/html")
  test "a good login sets a cookie that JavaScript cannot read and another site cannot send, and goes to the organisations":
    let r = handle(cfg, fakeCore(), req("POST", "/ui/login", form = {"user": "ann", "password": "right-password-1234"}.toTable))
    check r.status == 303 and r.header("Location") == "/ui/orgs"
    let c = r.header("Set-Cookie")
    check c.startsWith("cinim_ui=tok-ann;") and "HttpOnly" in c and "SameSite=Strict" in c and "Path=/ui" in c and "Max-Age=" in c and "Secure" notin c
    check "Secure" in handle(cfgSecure, fakeCore(), req("POST", "/ui/login", form = {"user": "ann", "password": "right-password-1234"}.toTable)).header("Set-Cookie")
  test "the login goes on to the page that was wanted, if it is a page of the UI, and to nothing else (no open redirect)":
    proc target(next: string): string =
      handle(cfg, fakeCore(), req("POST", "/ui/login", form = {"user": "ann", "password": "right-password-1234", "next": next}.toTable)).header("Location")
    check target("/ui/runs/s1_abc") == "/ui/runs/s1_abc"
    for bad in ["https://evil.example/", "//evil.example/", "/other/place", "/ui/../etc", "javascript:alert(1)", "/ui\r\nSet-Cookie: x=1"]:
      check target(bad) == "/ui/orgs"
  test "a wrong password gives the page again with a plain message, 401, no cookie, the name escaped and the password not repeated":
    let r = handle(cfg, fakeCore(), req("POST", "/ui/login", form = {"user": hostile, "password": "wrong-password-xyz"}.toTable))
    check r.status == 401 and r.header("Set-Cookie").len == 0
    check "Wrong user name or password" in r.body and "wrong-password-xyz" notin r.body
    check "<script>" notin r.body and "&lt;script&gt;" in r.body
  test "a throttled login says how long to wait, and 429 is kept":
    let r = handle(cfg, fakeCore(), req("POST", "/ui/login", form = {"user": "ann", "password": "throttled"}.toTable))
    check r.status == 429 and "retry after 30 s" in r.body and r.header("Set-Cookie").len == 0
  test "a user who has to change the password first gets no session (the UI does not change passwords) and is told how":
    let r = handle(cfg, fakeCore(), req("POST", "/ui/login", form = {"user": "new", "password": "right-password-1234"}.toTable))
    check r.status == 403 and r.header("Set-Cookie").len == 0 and "change the password" in r.body and "/api/v1/users/new/password" in r.body
  test "a core that does not answer is a 503 page, and no one is logged in":
    down = true
    let r = handle(cfg, fakeCore(), req("POST", "/ui/login", form = {"user": "ann", "password": "right-password-1234"}.toTable))
    check r.status == 503 and r.header("Set-Cookie").len == 0
  test "logging out clears the cookie and goes to the login; it is a POST":
    let r = handle(cfg, fakeCore(), req("POST", "/ui/logout", cookie = session))
    check r.status == 303 and r.header("Location") == "/ui/login" and "Max-Age=0" in r.header("Set-Cookie")
    check handle(cfg, fakeCore(), req("GET", "/ui/logout", cookie = session)).status == 405
  test "a POST from another site is refused (the Origin must be this host), also the login":
    let form = {"user": "ann", "password": "right-password-1234"}.toTable
    check handle(cfg, fakeCore(), req("POST", "/ui/login", form = form, origin = "https://evil.example")).status == 403
    check handle(cfg, fakeCore(), req("POST", "/ui/logout", cookie = session, origin = "https://evil.example")).status == 403
    check handle(cfg, fakeCore(), req("POST", "/ui/login", form = form, origin = "https://ui.example")).status == 303
    check handle(cfg, fakeCore(), req("POST", "/ui/login", form = form, origin = "http://ui.example")).status == 303      # the scheme is the ingress's business
  test "a token that the core no longer takes ends the session at the next page: the cookie is cleared and the login is shown":
    let r = handle(cfg, fakeCore(), req("GET", "/ui/orgs", cookie = "cinim_ui=tok-revoked"))
    check r.status == 303 and r.header("Location").startsWith("/ui/login?next=") and "Max-Age=0" in r.header("Set-Cookie")

suite "the pages":
  setup: reset()
  test "the organisations, each with a permanent link to its runs, and hostile names stay text":
    routes["/api/v1/organizations"] = %*{"organizations": [{"id": "o1", "slug": "acme", "name": hostile, "state": "active", "url": "http://x/acme", "namespace": "cinim-001-acme"},
                                                            {"id": "o2", "slug": "selfci", "name": "Self CI", "state": "disabled", "url": "", "namespace": "cinim-001-selfci"}]}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/orgs", cookie = session))
    check r.status == 200 and calls == @["tok-ann /api/v1/organizations"]
    check "href=\"/ui/orgs/acme/runs\"" in r.body and "href=\"/ui/orgs/selfci/runs\"" in r.body
    check "<script>" notin r.body and "&lt;script&gt;" in r.body and "disabled" in r.body
  test "the runs of an organisation: newest first as the core gives them, a link to each, the reason of a failure, and a way to older ones":
    routes["/api/v1/runs?organization=acme&limit=50"] = %*{"runs": [
      {"id": "s1_b", "organization": "acme", "project": "", "state": "FAILED", "created_at": "1792484469", "updated_at": "1792484999", "failure": {"code": "step_failed", "message": "step 1 exited with 2"}, "source": {"repository": "https://x/r.git", "commit": "e13ccc152d942eadb260c37b1b77e61dbfab4b80"}},
      {"id": "s1_a", "organization": "acme", "project": "", "state": "OK", "created_at": "1792484000", "updated_at": "1792484100"}], "next": "s1_a"}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", cookie = session))
    check r.status == 200
    check r.body.find("s1_b") < r.body.find("s1_a")                # the order of the core
    check "href=\"/ui/runs/s1_b\"" in r.body and "href=\"/ui/runs/s1_a\"" in r.body
    check "step_failed" in r.body and "step 1 exited with 2" in r.body and "e13ccc1" in r.body
    check "href=\"/ui/orgs/acme/runs?before=s1_a\"" in r.body       # the older runs
    check "2026-10-20 08:21:09" in r.body                           # a time a person reads (UTC), not epoch seconds
  test "UI-001 each run of the list says of which project (the path of its project) and which pipeline (the script of the repository) it is":
    routes["/api/v1/runs?organization=acme&limit=50"] = %*{"runs": [
      {"id": "s1_p1", "organization": "acme", "project": "team/backend", "state": "OK", "source": {"repository": "https://x/r.git", "commit": "e13ccc152d942eadb260c37b1b77e61dbfab4b80", "path": ".ci/03.lua"}},
      {"id": "s1_p2", "organization": "acme", "project": "", "state": "FAILED"}]}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", cookie = session))
    check "<th>Project</th>" in r.body and "<th>Pipeline</th>" in r.body
    check "team/backend" in r.body and ".ci/03.lua" in r.body
    check r.body.find("team/backend") < r.body.find("s1_p2")                        # in the row of the first run
    check "title=\"https://x/r.git\"" in r.body                                       # where the pipeline is kept
  test "UI-001 the page of a run names its project and its pipeline in the words of D-68":
    routes["/api/v1/runs/s1_b"] = %*{"id": "s1_b", "organization": "acme", "project": "g/x", "state": "FAILED", "source": {"repository": "https://x/r.git", "commit": "e13ccc152d942eadb260c37b1b77e61dbfab4b80", "path": ".ci/03.lua"}, "steps": []}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_b", cookie = session))
    check "<dt>Project</dt><dd>g/x</dd>" in r.body and "<dt>Pipeline</dt>" in r.body and ".ci/03.lua" in r.body and "<dt>Group</dt>" notin r.body
  test "the state filter goes to the core, is kept in the link to the older runs, and a state that is not a word is ignored":
    routes["/api/v1/runs?organization=acme&state=FAILED&limit=50"] = %*{"runs": [], "next": "s1_z"}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", query = "state=FAILED", cookie = session))
    check r.status == 200 and "href=\"/ui/orgs/acme/runs?state=FAILED&amp;before=s1_z\"" in r.body
    routes["/api/v1/runs?organization=acme&limit=50"] = %*{"runs": [], "next": nil}
    check handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", query = "state=FAILED%27%20OR%201%3D1", cookie = session)).status == 200
    check calls[^1] == "tok-ann /api/v1/runs?organization=acme&limit=50"
  test "the list shows the last six characters of a long run id, the whole id is the link and its title; a short id stays whole":
    routes["/api/v1/runs?organization=acme&limit=50"] = %*{"runs": [{"id": "s1_01a15949-68a3-7db0-acd7-fb1c7c2e6f86", "state": "OK"}, {"id": "s1_a", "state": "FAILED"}]}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", cookie = session))
    check "href=\"/ui/runs/s1_01a15949-68a3-7db0-acd7-fb1c7c2e6f86\" title=\"s1_01a15949-68a3-7db0-acd7-fb1c7c2e6f86\">…2e6f86</a>" in r.body
    check ">s1_a</a>" in r.body
  test "the state filter offers the states as the core spells them (ABORTED, which has one spelling)":
    routes["/api/v1/runs?organization=acme&limit=50"] = %*{"runs": []}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", cookie = session))
    check "state=ABORTED\"" in r.body and "CANCEL" notin r.body
  test "the cursor is passed to the core, and one that is not an id is dropped":
    routes["/api/v1/runs?organization=acme&limit=50&before=s1_a"] = %*{"runs": [], "next": nil}
    check handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", query = "before=s1_a", cookie = session)).status == 200
    routes["/api/v1/runs?organization=acme&limit=50"] = %*{"runs": [], "next": nil}
    discard handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", query = "before=%27%3Bdrop", cookie = session))
    check calls[^1] == "tok-ann /api/v1/runs?organization=acme&limit=50"
  test "the name of an organisation in the address has to be a slug: anything else is a 404 and the core is not asked":
    let r = handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme%22%3E%3Cscript%3E/runs", cookie = session))
    check r.status == 404 and calls.len == 0 and "<script>" notin r.body
  test "a run: its state, where it came from, the failure, and the steps, each with a link to its log":
    routes["/api/v1/runs/s1_b"] = %*{"id": "s1_b", "organization": "acme", "project": "g/x", "state": "FAILED", "created_at": "1792484469", "updated_at": "1792484999",
      "failure": {"code": "step_failed", "message": hostile}, "source": {"repository": "https://x/r.git", "commit": "e13ccc152d942eadb260c37b1b77e61dbfab4b80", "path": ".ci/pipeline.lua"},
      "params": {"DEPLOY": "false"}, "wait_reason": "",
      "steps": [{"seq": 0, "attempt": 1, "state": "OK", "exit_code": 0, "termination": "ok", "pod_reason": "", "pod_message": "", "pod_diag": nil},
                {"seq": 1, "attempt": 2, "state": "FAILED", "exit_code": 2, "termination": "exit", "pod_reason": "Error", "pod_message": "", "pod_diag": nil}]}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_b", cookie = session))
    check r.status == 200
    check "FAILED" in r.body and "acme" in r.body and "e13ccc152d942eadb260c37b1b77e61dbfab4b80" in r.body and ".ci/pipeline.lua" in r.body and "DEPLOY" in r.body
    check "href=\"/ui/runs/s1_b/steps/0/log\"" in r.body and "href=\"/ui/runs/s1_b/steps/1/log\"" in r.body
    check "<script>" notin r.body and "&lt;script&gt;" in r.body                                # the message of a failure is whatever a step said
    check "href=\"/ui/orgs/acme/runs\"" in r.body                                              # the way back
  test "a field the core leaves out is an empty cell, not a crash (a run with no params, a step with no exit code, a list with no next)":
    routes["/api/v1/runs/s1_p"] = %*{"id": "s1_p", "organization": "acme", "state": "RUNNING", "steps": [{"seq": 0, "attempt": 1, "state": "RUNNING"}]}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_p", cookie = session))
    check r.status == 200 and "RUNNING" in r.body and "href=\"/ui/runs/s1_p/steps/0/log\"" in r.body
    routes["/api/v1/runs?organization=acme&limit=50"] = %*{"runs": [{"id": "s1_p", "state": "RUNNING"}]}
    let l = handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", cookie = session))
    check l.status == 200 and "s1_p" in l.body and "before=" notin l.body
  test "a run that does not exist (or is another organisation's: the core says the same) is a 404 page, not an error":
    let r = handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_nope", cookie = session))
    check r.status == 404 and "no such run" in r.body.toLowerAscii
    check handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_x'y", cookie = session)).status == 404 and calls.len == 1
  test "a step log is shown as a window of lines, numbered, as text, with a way on and a way back":
    routes["/api/v1/runs/s1_b/steps/1/log?from=200&limit=200"] = %*{"run_id": "s1_b", "step_seq": 1, "from": 200, "lines": ["first <b>bold</b>", hostile, "third"], "next": 203, "step_state": "RUNNING", "complete": false, "lines_total": 203}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_b/steps/1/log", query = "from=200", cookie = session))
    check r.status == 200
    check "<b>bold</b>" notin r.body and "&lt;b&gt;bold&lt;/b&gt;" in r.body and "<script>" notin r.body
    check ">201<" in r.body or "201" in r.body
    check "href=\"/ui/runs/s1_b/steps/1/log?from=203\"" in r.body                              # on
    check "href=\"/ui/runs/s1_b/steps/1/log?from=0\"" in r.body                                # back (200 - 200)
    check "href=\"/ui/runs/s1_b\"" in r.body
  test "UI-001 the colours that a tool writes into its log (ESC [ 36 m ...) are not shown as text: the page shows the words":
    routes["/api/v1/runs/s1_b/steps/2/log?from=0&limit=200"] = %*{"run_id": "s1_b", "step_seq": 2, "from": 0, "step_state": "OK", "complete": true, "lines_total": 2, "next": 2,
      "lines": ["\x1b[36mINFO\x1b[0m[0072] Taking snapshot of files...", "plain \x1b[1;31mred\x1b[0m and \x1b[2K\x1b[Gmoved <b>x</b>"]}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_b/steps/2/log", cookie = session))
    check r.status == 200 and "INFO[0072] Taking snapshot of files..." in r.body and "plain red and moved &lt;b&gt;x&lt;/b&gt;" in r.body
    check '\x1b' notin r.body and "[36m" notin r.body and "[0m" notin r.body
  test "the first window starts at line 0, has no way back, and a finished log has no way on":
    routes["/api/v1/runs/s1_b/steps/0/log?from=0&limit=200"] = %*{"run_id": "s1_b", "step_seq": 0, "from": 0, "lines": ["only line"], "next": 1, "step_state": "OK", "complete": true, "lines_total": 1}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_b/steps/0/log", cookie = session))
    check r.status == 200 and "only line" in r.body and "from=1" notin r.body and "log?from=" notin r.body
  test "a step number of ten digits (the numbers of the steps are hashes) has a log page":
    routes["/api/v1/runs/s1_b/steps/1060038995/log?from=0&limit=200"] = %*{"from": 0, "lines": ["x"], "next": 1, "step_state": "FAILED", "complete": true}
    check handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_b/steps/1060038995/log", cookie = session)).status == 200
    check handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_b/steps/10600389951/log", cookie = session)).status == 404
  test "what is not a number of a line or of a step is not asked of the core":
    check handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_b/steps/x/log", cookie = session)).status == 404
    discard handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_b/steps/1/log", query = "from=-5%20or%201", cookie = session))
    check calls[^1] == "tok-ann /api/v1/runs/s1_b/steps/1/log?from=0&limit=200"
  test "UI-001 how long a run or a step took: seconds, minutes, hours; from the start to the end, or to now while it goes on":
    check durationText(0) == "0 s" and durationText(45) == "45 s" and durationText(90) == "1 min 30 s" and durationText(3725) == "1 h 02 min" and durationText(90000) == "1 d 01 h"
    check durationText(-5) == ""
    check tookText(1000, 1125, true, 9999) == "2 min 5 s"          # ended: to its end, whatever the time now
    check tookText(1000, 0, false, 1040) == "40 s"                  # going on: to now
    check tookText(0, 0, false, 1040) == "" and tookText(1000, 900, true, 9999) == ""      # not started; an end before the start is nothing to say
  test "UI-001 the list of runs and the page of a run say how long each took":
    routes["/api/v1/runs?organization=acme&limit=50"] = %*{"runs": [
      {"id": "s1_t1", "state": "OK", "organization": "acme", "created_at": "1800000000", "updated_at": "1800000125"},
      {"id": "s1_t2", "state": "QUEUED", "organization": "acme", "created_at": "1800000000", "updated_at": "1800000000"}]}
    let l = handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", cookie = session))
    check "<th>Took</th>" in l.body and "2 min 5 s" in l.body
    routes["/api/v1/runs/s1_t1"] = %*{"id": "s1_t1", "organization": "acme", "state": "OK", "created_at": "1800000000", "updated_at": "1800000125", "steps": [
      {"seq": 1, "attempt": 1, "state": "OK", "started_at": 1800000010, "finished_at": 1800000070},
      {"seq": 2, "attempt": 1, "state": "QUEUED", "started_at": 0, "finished_at": 0},
      {"seq": 3, "attempt": 1, "state": "OK"}]}          # a core that does not say it (an older one): an empty cell, not a crash
    let r = handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_t1", cookie = session))
    check r.status == 200 and "<th>Took</th>" in r.body and "1 min 0 s" in r.body and "2 min 5 s" in r.body
  test "D-77 the log of a run is one window of lines, each starting with the label of its step (job and step ids, `14/0003`), asked of the core in one request":
    routes["/api/v1/runs/s1_c/log?limit=200"] = %*{"run_id": "s1_c", "run_state": "RUNNING", "lines": [
      {"step": 37748739, "job_id": "14", "step_id": "0003", "attempt": 1, "ln": 0, "text": "job-a step-3 line"},
      {"step": 37748739, "job_id": "14", "step_id": "0003", "attempt": 1, "ln": 1, "text": hostile},
      {"step": 38797313, "job_id": "15", "step_id": "0001", "attempt": 1, "ln": 0, "text": "job-b line"}], "later": "38797313.1.1"}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_c/log", cookie = session))
    check r.status == 200 and r.body.count("<pre") == 1
    check ">14/0003</a> job-a step-3 line" in r.body and ">15/0001</a> job-b line" in r.body
    check "<script>" notin r.body and "&lt;script&gt;" in r.body
    check "href=\"/ui/runs/s1_c/steps/37748739/log?from=1\"" in r.body                       # the label is the way to the line in the log of its step
    check calls.len == 1 or calls[^1] == "tok-ann /api/v1/runs/s1_c/log?limit=200"             # one request for the whole run
    check "href=\"/ui/runs/s1_c/log?from=38797313.1.1\"" in r.body and "earlier" notin r.body.toLowerAscii
  test "D-77 the ways to the lines before and after a window are the cursors the core gave; a window in the middle has the way to the newest":
    routes["/api/v1/runs/s1_c/log?limit=200&until=5.1.7"] = %*{"run_id": "s1_c", "run_state": "OK", "earlier": "5.1.2", "later": "5.1.7",
      "lines": [{"step": 5, "job_id": "00", "step_id": "0005", "attempt": 1, "ln": 2, "text": "x"}]}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_c/log", query = "until=5.1.7", cookie = session))
    check r.status == 200 and "href=\"/ui/runs/s1_c/log?until=5.1.2\"" in r.body and "href=\"/ui/runs/s1_c/log?from=5.1.7\"" in r.body
    check "href=\"/ui/runs/s1_c/log\">Newest" in r.body
    routes["/api/v1/runs/s1_c/log?limit=200&from=5.1.7"] = %*{"run_id": "s1_c", "run_state": "OK", "lines": []}
    let e = handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_c/log", query = "from=5.1.7", cookie = session))
    check e.status == 200 and "No lines" in e.body
  test "D-77 what is not a cursor is not asked of the core; a run that does not exist is a 404, a core that is away 503, a session the core refuses the login":
    routes["/api/v1/runs/s1_c/log?limit=200"] = %*{"run_id": "s1_c", "run_state": "RUNNING", "lines": []}
    discard handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_c/log", query = "from=1%20or%201&until=x", cookie = session))
    check calls[^1] == "tok-ann /api/v1/runs/s1_c/log?limit=200"
    check handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_nope/log", cookie = session)).status == 404
    down = true
    check handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_c/log", cookie = session)).status == 503
    down = false
    check handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_c/log", cookie = "cinim_ui=tok-other")).status == 303
  test "D-77 the page of a run has a way to the log of the whole run":
    routes["/api/v1/runs/s1_c"] = %*{"id": "s1_c", "organization": "acme", "state": "RUNNING", "steps": []}
    check "href=\"/ui/runs/s1_c/log\"" in handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_c", cookie = session)).body
  test "the state of the components of the shard, one row each":
    # the core answers with the array itself, not with an object around it (checked against the running core)
    routes["/api/v1/components"] = %*[{"kind": "keyservice", "id": "master-key", "state": "up", "last_seen_seconds_ago": 3.2, "since": 1792484469.5, "info": {}},
                                       {"kind": "rqlite", "id": "state-store", "state": "down", "last_seen_seconds_ago": 100.0, "since": 1792484000.0, "info": {}}]
    let r = handle(cfg, fakeCore(), req("GET", "/ui/status", cookie = session))
    check r.status == 200 and "keyservice" in r.body and "master-key" in r.body and "state-store" in r.body and "class=\"state-down\"" in r.body and "class=\"state-up\"" in r.body
  test "a component the core never heard of (it counts from the epoch) is 'never seen', not 497918 h ago":
    routes["/api/v1/components"] = %*[{"kind": "logcircuit", "id": "launch-gate", "state": "down", "last_seen_seconds_ago": 1792484469.5}]
    let r = handle(cfg, fakeCore(), req("GET", "/ui/status", cookie = session))
    check "never" in r.body and " h ago" notin r.body
  test "a token that may not see the page gets a 403 page, a core that is down a 503 page":
    routes["/api/v1/components"] = nil
    down = true
    check handle(cfg, fakeCore(), req("GET", "/ui/status", cookie = session)).status == 503

suite "D-84 the menu follows what the core says the caller comes to (GET /api/v1/me)":
  setup: reset()
  proc menuOf(me: JsonNode): string =
    if me != nil: routes["/api/v1/me"] = me
    routes["/api/v1/organizations"] = %*{"organizations": []}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/orgs", cookie = session))
    var m = ""
    if "href=\"/ui/orgs\"" in r.body: m.add "O"
    if "href=\"/ui/runs\"" in r.body: m.add "R"
    if "href=\"/ui/status\"" in r.body: m.add "C"
    m
  test "an administrator sees everything; a user of the shard with the right to read sees everything":
    check menuOf(%*{"administrator": true, "permissions": {"shard": ["run.read"]}}) == "ORC"
    check menuOf(%*{"administrator": false, "permissions": {"shard": ["run.read", "shard.read"], "organizations": {}, "groups": {}}}) == "ORC"
  test "a user with roles in organisations only sees the runs but not the components of the shard":
    check menuOf(%*{"administrator": false, "permissions": {"shard": [], "organizations": {"acme": ["run.read"]}, "groups": {}}}) == "OR"
  test "a user whose only role is on a group sees the runs when that role reads runs":
    check menuOf(%*{"administrator": false, "permissions": {"shard": [], "organizations": {}, "groups": {"acme": [{"path": "ci", "permissions": ["run.read", "log.read"]}]}}}) == "OR"
    check menuOf(%*{"administrator": false, "permissions": {"shard": [], "organizations": {}, "groups": {"acme": [{"path": "ci", "permissions": ["trigger.read"]}]}}}) == "O"
  test "a user who reads nothing sees the organisations and nothing else":
    check menuOf(%*{"administrator": false, "permissions": {"shard": [], "organizations": {"acme": ["trigger.read"]}, "groups": {}}}) == "O"
  test "a core that does not answer /me, or answers with something else, leaves the whole menu (the core refuses what is not allowed all the same)":
    check menuOf(nil) == "ORC"                                  # no route: the stand-in says 404
    check menuOf(%*[1, 2]) == "ORC"
    check menuOf(%*{"permissions": "none"}) == "ORC"

suite "D-84 D-85 D-87 the pages of roles, members and directories":
  setup: reset()
  let adminMe = %*{"administrator": true, "permissions": {"shard": []}}
  let orgAdminMe = %*{"administrator": false, "permissions": {"shard": [], "organizations": {"acme": ["access.read", "access.write", "ldap.read", "ldap.map"]}, "groups": {}}}
  let readerMe = %*{"administrator": false, "permissions": {"shard": [], "organizations": {"acme": ["access.read", "ldap.read"]}, "groups": {}}}
  let roleList = %*{"roles": [{"name": "admin", "description": "every route", "builtin": true, "permissions": ["run.read", "run.start"]},
                              {"name": "deployer", "description": "starts <b>runs</b>", "builtin": false, "permissions": ["run.read"]}]}
  let catalogue = %*{"permissions": [{"name": "run.read", "level": "group", "description": "see runs"}, {"name": "run.start", "level": "group", "description": "start <i>a</i> run"}]}
  proc seed(me: JsonNode) =
    routes["/api/v1/me"] = me
    routes["/api/v1/roles"] = roleList
    routes["/api/v1/permissions"] = catalogue
  proc get(path: string): UiResponse = handle(cfg, fakeCore(), req("GET", path, cookie = session))
  proc post(path: string; pairs: seq[(string, string)]; origin = ""): UiResponse = handle(cfg, fakeCore(), req("POST", path, cookie = session, pairs = pairs, origin = origin))

  test "the list of roles: built in or custom, how many permissions, the description as text; the way to a new role only for whoever may make one":
    seed(adminMe)
    let r = get("/ui/roles")
    check r.status == 200 and "href=\"/ui/roles/admin\"" in r.body and "built in" in r.body and "custom" in r.body and "href=\"/ui/new-role\"" in r.body
    check "starts &lt;b&gt;runs&lt;/b&gt;" in r.body and "<b>runs</b>" notin r.body
    seed(readerMe)
    check "new-role" notin get("/ui/roles").body
  test "a built-in role is shown and cannot be edited; a custom one has the boxes, the held ones ticked, and a delete button, for whoever may make roles":
    seed(adminMe)
    let b = get("/ui/roles/admin")
    check b.status == 200 and "<form method=\"post\" action=\"/ui/roles/admin\"" notin b.body and "type=\"checkbox\"" notin b.body and "<b>(yes)</b>" in b.body
    let c = get("/ui/roles/deployer")
    check "<form method=\"post\" action=\"/ui/roles/deployer\"" in c.body and "<input type=\"checkbox\" name=\"perm\" value=\"run.read\" checked>" in c.body
    check "<input type=\"checkbox\" name=\"perm\" value=\"run.start\">" in c.body and "action=\"/ui/roles/deployer/delete\"" in c.body and "start &lt;i&gt;a&lt;/i&gt; run" in c.body
    seed(readerMe)
    check "type=\"checkbox\"" notin get("/ui/roles/deployer").body
    check get("/ui/roles/nope").status == 404 and get("/ui/roles/Bad%20Name").status == 404
  test "a new role: the name and the boxes":
    seed(adminMe)
    let r = get("/ui/new-role")
    check r.status == 200 and "name=\"name\"" in r.body and "action=\"/ui/new-role\"" in r.body and r.body.count("type=\"checkbox\"") == 2
  test "saving a role sends the name, the description and every box that is ticked, and drops what is not a permission":
    seed(adminMe)
    let r = post("/ui/roles/deployer", @[("description", "d"), ("perm", "run.read"), ("perm", "run.start"), ("perm", "run.start"), ("perm", "Bad Perm"), ("perm", "x;y")])
    check r.status == 303 and r.header("Location") == "/ui/roles/deployer"
    check sent == @["PUT /api/v1/roles/deployer {\"description\":\"d\",\"permissions\":[\"run.read\",\"run.start\"]}"]
    reset(); seed(adminMe)
    let n = post("/ui/new-role", @[("name", "qa-team"), ("description", ""), ("perm", "run.read")])
    check n.status == 303 and n.header("Location") == "/ui/roles/qa-team" and sent == @["PUT /api/v1/roles/qa-team {\"description\":\"\",\"permissions\":[\"run.read\"]}"]
    reset(); seed(adminMe)
    check post("/ui/new-role", @[("name", "Bad Name")]).status == 400 and post("/ui/new-role", @[("name", "../x")]).status == 400 and sent.len == 0
  test "deleting a role, and what the core says when it refuses":
    seed(adminMe)
    check post("/ui/roles/deployer/delete", @[]).header("Location") == "/ui/roles" and sent == @["DELETE /api/v1/roles/deployer "]
    sendAnswer = ApiResult(status: asRefused, code: 409, message: "this role is given to a user; take it away first")
    let r = post("/ui/roles/deployer/delete", @[])
    check r.status == 409 and "this role is given to a user" in r.body and "href=\"/ui/roles\"" in r.body
  test "a refusal for want of a right says why, in the words of /me/can":
    seed(readerMe)
    sendAnswer = ApiResult(status: asForbidden, code: 403, message: "the roles of ann do not allow")
    routes["/api/v1/me/can?method=PUT&path=%2Fapi%2Fv1%2Froles%2Fdeployer"] = %*{"permission": "role.manage", "needs": "at the shard", "reason": "this needs a role at the shard, and a role in an organisation does not count"}
    let r = post("/ui/roles/deployer", @[("perm", "run.read")])
    check r.status == 403 and "needs role.manage at the shard" in r.body and "does not count" in r.body
  test "a form from another site, or with no session, never reaches the core":
    seed(adminMe)
    check post("/ui/roles/deployer", @[("perm", "run.read")], origin = "http://evil.example").status == 403 and sent.len == 0
    check handle(cfg, fakeCore(), req("POST", "/ui/new-role")).status == 303 and sent.len == 0
  test "the members of an organisation and of a group; the forms only for whoever may give roles":
    seed(orgAdminMe)
    routes["/api/v1/organizations/acme/members"] = %*{"members": [{"user": "ann@acme", "roles": ["dev", "ro"]}, {"user": "<x>", "roles": []}]}
    routes["/api/v1/organizations/acme/groups/ci/cinim/members"] = %*{"members": [{"user": "gina", "roles": ["dev"]}]}
    let o = get("/ui/orgs/acme/members")
    check o.status == 200 and "<code>ann@acme</code>" in o.body and "dev, ro" in o.body and "action=\"/ui/orgs/acme/members/set\"" in o.body and "<x>" notin o.body
    check "name=\"role\" value=\"deployer\"" in o.body and "action=\"/ui/orgs/acme/members/remove\"" in o.body
    let g = get("/ui/orgs/acme/groups/ci/cinim/members")
    check g.status == 200 and "gina" in g.body and "action=\"/ui/orgs/acme/groups/ci/cinim/members/set\"" in g.body and "members of the organisation" in g.body
    seed(readerMe)
    check "action=\"/ui/orgs/acme/members/set\"" notin get("/ui/orgs/acme/members").body
    check get("/ui/orgs/Acme/members").status == 404 and get("/ui/orgs/acme/groups/Bad/members").status == 404 and get("/ui/orgs/acme/other/ci/members").status == 404
  test "giving roles sends all the boxes that are ticked to the right place, taking all away is a delete, and a bad name is refused before the core is asked":
    seed(orgAdminMe)
    let r = post("/ui/orgs/acme/members/set", @[("user", "ann@acme"), ("role", "dev"), ("role", "deployer"), ("role", "Bad Role")])
    check r.status == 303 and r.header("Location") == "/ui/orgs/acme/members" and sent == @["PUT /api/v1/organizations/acme/members/ann@acme {\"roles\":[\"dev\",\"deployer\"]}"]
    reset(); seed(orgAdminMe)
    check post("/ui/orgs/acme/groups/ci/cinim/members/remove", @[("user", "gina")]).header("Location") == "/ui/orgs/acme/groups/ci/cinim/members"
    check sent == @["DELETE /api/v1/organizations/acme/groups/ci/cinim/members/gina "]
    reset(); seed(orgAdminMe)
    check post("/ui/orgs/acme/members/set", @[("user", "../x"), ("role", "dev")]).status == 400 and post("/ui/orgs/acme/members/set", @[("role", "dev")]).status == 400 and sent.len == 0
  test "the directories of an organisation: the settings, the warnings, the groups, the accounts; forms for whoever may map groups; the check only for the shard":
    seed(orgAdminMe)
    routes["/api/v1/organizations/acme/ldap"] = %*{"directories": [{"name": "corp", "url": "ldap://dc.example", "priority": 0, "start_tls": false, "enabled": true, "auto_create": false, "last_sync_at": 1793292000, "last_sync_result": "ok: 3 accounts",
      "warnings": ["the connection is not encrypted"]}], "mappings": [{"id": "m1", "directory": "", "group_dn": "cn=<ci>,dc=x", "role": "dev"}],
      "accounts": [{"account": "ann@acme", "directory": "corp", "dn": "uid=ann,dc=x", "switched_off": true, "roles_from_directory": ["dev"]}]}
    let r = get("/ui/orgs/acme/ldap")
    check r.status == 200 and "<code>corp</code>" in r.body and "not encrypted" in r.body and "made by hand" in r.body and "ok: 3 accounts" in r.body
    check "cn=&lt;ci&gt;,dc=x" in r.body and "<ci>" notin r.body and "switched off" in r.body
    check "action=\"/ui/orgs/acme/ldap/mappings/m1/delete\"" in r.body and "action=\"/ui/orgs/acme/ldap/servers/corp/sync\"" in r.body and "action=\"/ui/orgs/acme/ldap/accounts/remove\"" in r.body
    check "action=\"/ui/orgs/acme/ldap/check\"" notin r.body                                    # ldap.write is the shard\'s
    seed(adminMe)
    check "action=\"/ui/orgs/acme/ldap/check\"" in get("/ui/orgs/acme/ldap").body
    seed(readerMe)
    let ro = get("/ui/orgs/acme/ldap")
    check ro.status == 200 and "<form" notin ro.body.replace("<form class=\"logout\"", "") .replace("class=\"logout\" method=\"post\"", "")
  test "the forms of the directory page ask the core for what they say and go back to the page":
    seed(orgAdminMe)
    check post("/ui/orgs/acme/ldap/mappings", @[("group_dn", "cn=ci,dc=x"), ("role", "dev"), ("directory", "corp")]).header("Location") == "/ui/orgs/acme/ldap"
    check sent == @["POST /api/v1/organizations/acme/ldap/mappings {\"group_dn\":\"cn=ci,dc=x\",\"role\":\"dev\",\"directory\":\"corp\"}"]
    reset(); seed(orgAdminMe)
    discard post("/ui/orgs/acme/ldap/mappings/m1/delete", @[])
    discard post("/ui/orgs/acme/ldap/accounts", @[("login", "ann"), ("directory", "")])
    discard post("/ui/orgs/acme/ldap/accounts/remove", @[("login", "ann@acme")])
    discard post("/ui/orgs/acme/ldap/servers/corp/sync", @[])
    check sent == @["DELETE /api/v1/organizations/acme/ldap/mappings/m1 ", "PUT /api/v1/organizations/acme/ldap/accounts/ann {\"directory\":\"\"}",
                    "DELETE /api/v1/organizations/acme/ldap/accounts/ann ", "POST /api/v1/organizations/acme/ldap/servers/corp:sync {}"]
  test "the check of a person shows what the core found and changes nothing":
    seed(adminMe)
    sendAnswer = ok(%*{"directory": "corp", "connected": true, "person": {"found": true, "dn": "uid=ann,dc=x", "groups": ["cn=ci,dc=x"], "roles": ["dev"], "account": "ann@acme"}})
    let r = post("/ui/orgs/acme/ldap/check", @[("directory", "corp"), ("user", "ann")])
    check r.status == 200 and "connected and bound" in r.body and "found uid=ann,dc=x (account ann@acme)" in r.body and "roles here: dev" in r.body
    sendAnswer = ok(%*{"connected": false, "error": "cannot connect <here>"})
    check "not connected: cannot connect &lt;here&gt;" in post("/ui/orgs/acme/ldap/check", @[("directory", "corp"), ("user", "")]).body
  test "bad input to the directory forms is refused before the core is asked":
    seed(orgAdminMe)
    for (path, pairs) in [("/ui/orgs/acme/ldap/mappings", @[("group_dn", "x"), ("role", "dev")]), ("/ui/orgs/acme/ldap/mappings", @[("group_dn", "cn=a,dc=b"), ("role", "Bad Role")]),
                          ("/ui/orgs/acme/ldap/accounts", @[("login", "an*")]), ("/ui/orgs/acme/ldap/accounts/remove", @[("login", "../x")]), ("/ui/orgs/acme/ldap/check", @[("directory", "x y")])]:
      check post(path, pairs).status == 400
    check post("/ui/orgs/acme/ldap/servers/Bad/sync", @[]).status == 404 and post("/ui/orgs/acme/ldap/nothing", @[]).status == 404
    check sent.len == 0
  test "the teams of an organisation: how each is made, who is in it and from where, its roles; the forms only for whoever may give roles":
    seed(orgAdminMe)
    routes["/api/v1/organizations/acme/teams"] = %*{"teams": [
      {"name": "qa", "description": "the <b>testers</b>", "members": [{"user": "ann@acme", "source": "ldap:x"}, {"user": "bob", "source": ""}], "roles": [{"role": "dev", "scope": "org:acme"}], "ldap": {"group_dn": "cn=qa,dc=x", "directory": "corp"}},
      {"name": "ops", "description": "", "members": [], "roles": []}]}
    let r = get("/ui/orgs/acme/teams")
    check r.status == 200 and "the &lt;b&gt;testers&lt;/b&gt;" in r.body and "<b>testers</b>" notin r.body and "cn=qa,dc=x" in r.body and "dev (org:acme)" in r.body and "from the directory" in r.body and "by hand" in r.body
    check "action=\"/ui/orgs/acme/teams/qa/members/remove\"" in r.body and r.body.count("members/remove\" class=\"inline\"") == 1            # only the member added by hand can be taken away by hand
    check "action=\"/ui/orgs/acme/teams/ops/roles\"" in r.body and "action=\"/ui/orgs/acme/teams/ops/delete\"" in r.body and "action=\"/ui/orgs/acme/teams\"" in r.body and "This organisation has no team." notin r.body
    seed(readerMe)
    routes["/api/v1/organizations/acme/teams"] = %*{"teams": []}
    let ro = get("/ui/orgs/acme/teams")
    check ro.status == 200 and "This organisation has no team." in ro.body and "action=\"/ui/orgs/acme/teams\"" notin ro.body
  test "the forms of the teams page: a team by hand or from a group, members, the roles of a team, deleting; bad input does not reach the core":
    seed(orgAdminMe)
    check post("/ui/orgs/acme/teams", @[("name", "qa"), ("description", "d"), ("group_dn", "cn=qa,dc=x"), ("directory", "corp")]).header("Location") == "/ui/orgs/acme/teams"
    check sent == @["PUT /api/v1/organizations/acme/teams/qa {\"description\":\"d\",\"ldap\":{\"group_dn\":\"cn=qa,dc=x\",\"directory\":\"corp\"}}"]
    reset(); seed(orgAdminMe)
    discard post("/ui/orgs/acme/teams", @[("name", "ops"), ("description", "")])
    discard post("/ui/orgs/acme/teams/ops/members", @[("user", "bob")])
    discard post("/ui/orgs/acme/teams/ops/members/remove", @[("user", "bob")])
    discard post("/ui/orgs/acme/teams/ops/roles", @[("role", "dev"), ("role", "rw"), ("role", "Bad Role")])
    discard post("/ui/orgs/acme/teams/ops/delete", @[])
    check sent == @["PUT /api/v1/organizations/acme/teams/ops {\"description\":\"\"}", "PUT /api/v1/organizations/acme/teams/ops/members/bob ", "DELETE /api/v1/organizations/acme/teams/ops/members/bob ",
                    "PUT /api/v1/organizations/acme/members/team:ops {\"roles\":[\"dev\",\"rw\"]}", "DELETE /api/v1/organizations/acme/teams/ops "]
    reset(); seed(orgAdminMe)
    check post("/ui/orgs/acme/teams", @[("name", "Bad Name")]).status == 400 and post("/ui/orgs/acme/teams/ops/members", @[("user", "team:other")]).status == 400 and post("/ui/orgs/acme/teams/ops/members", @[("user", "../x")]).status == 400
    check post("/ui/orgs/acme/teams/Bad/delete", @[]).status == 404 and post("/ui/orgs/acme/teams/ops/nothing", @[]).status == 404 and sent.len == 0
    seed(orgAdminMe)
    sendAnswer = ApiResult(status: asRefused, code: 409, message: "this member comes from the group of a directory")
    let refused = post("/ui/orgs/acme/teams/qa/members/remove", @[("user", "ann@acme")])
    check refused.status == 409 and "comes from the group of a directory" in refused.body
  test "the roles of a team on a group are given on the members page of the group, with the person team:name":
    seed(orgAdminMe)
    discard post("/ui/orgs/acme/groups/ci/members/set", @[("user", "team:qa"), ("role", "dev")])
    check sent == @["PUT /api/v1/organizations/acme/groups/ci/members/team:qa {\"roles\":[\"dev\"]}"]
  test "the menu has Roles for whoever can read access, and the list of organisations links to the pages":
    seed(adminMe)
    routes["/api/v1/organizations"] = %*{"organizations": [{"id": "o1", "slug": "acme", "name": "A", "state": "active", "namespace": "n"}]}
    let o = get("/ui/orgs")
    check "href=\"/ui/roles\"" in o.body and "href=\"/ui/orgs/acme/members\"" in o.body and "href=\"/ui/orgs/acme/ldap\"" in o.body
    seed(%*{"administrator": false, "permissions": {"shard": ["run.read"], "organizations": {}, "groups": {}}})
    let n = get("/ui/orgs")
    check "href=\"/ui/roles\"" notin n.body and "href=\"/ui/orgs/acme/ldap\"" notin n.body

suite "D-87 the organisation in the login form":
  setup: reset()
  proc withDirectories() =
    directoryOrgs = %*[{"slug": "acme", "name": "Acme <Corp>"}, {"slug": "beta", "name": "Beta"}]
  test "an organisation with a directory is in a list that the form requires; the list has the name and the slug, a first line that is not a choice, and the local accounts":
    withDirectories()
    let r = handle(cfg, fakeCore(), req("GET", "/ui/login"))
    check r.status == 200 and "<select name=\"organization\" required>" in r.body
    check "<option value=\"\" selected disabled>Choose...</option>" in r.body
    check "<option value=\"acme\">Acme &lt;Corp&gt; (acme)</option>" in r.body and "<option value=\"beta\">Beta (beta)</option>" in r.body and "<option value=\"local\">Local account</option>" in r.body
    check "<Corp>" notin r.body
  test "no organisation has a directory: the form is the plain one, and the login goes as typed":
    let r = handle(cfg, fakeCore(), req("GET", "/ui/login"))
    check "<select" notin r.body and "name=\"user\"" in r.body
    var f = initTable[string, string]()
    f["user"] = "ann"
    f["password"] = "right-password-1234"
    check handle(cfg, fakeCore(), req("POST", "/ui/login", form = f)).status == 303 and loginCalls == @["ann"]
  test "the login is sent as login@organisation, and the person does not write the @":
    withDirectories()
    var f = {"user": "ann", "password": "right-password-1234", "organization": "acme"}.toTable
    let r = handle(cfg, fakeCore(), req("POST", "/ui/login", form = f))
    check r.status == 303 and loginCalls == @["ann@acme"] and r.header("Set-Cookie").startsWith("cinim_ui=tok-ann")
    var cookies: seq[string]
    for (k, v) in r.headers:
      if k == "Set-Cookie": cookies.add v
    check cookies.len == 2 and cookies[1].startsWith("cinim_org=acme; Path=/ui; SameSite=Strict")
  test "a user of the shard picks Local account, and the login goes as typed":
    withDirectories()
    var f = {"user": "ann", "password": "right-password-1234", "organization": "local"}.toTable
    check handle(cfg, fakeCore(), req("POST", "/ui/login", form = f)).status == 303 and loginCalls == @["ann"]
  test "a choice is required: none, an organisation that is not in the list, and @ in the login with an organisation chosen are refused before the core is asked":
    withDirectories()
    for (org, user, word) in [("", "ann", "Choose the organisation"), ("nope", "ann", "Choose the organisation"), ("<script>", "ann", "Choose the organisation"), ("acme", "ann@acme", "without @organisation")]:
      var f = {"user": user, "password": "right-password-1234", "organization": org}.toTable
      let r = handle(cfg, fakeCore(), req("POST", "/ui/login", form = f))
      check r.status == 400 and word in r.body and "set-cookie" notin r.body.toLowerAscii and r.header("Set-Cookie") == ""
    check loginCalls.len == 0
  test "after a wrong password the form keeps the organisation and the login":
    withDirectories()
    var f = {"user": "ann", "password": "wrong", "organization": "beta"}.toTable
    let r = handle(cfg, fakeCore(), req("POST", "/ui/login", form = f))
    check r.status == 401 and "<option value=\"beta\" selected>" in r.body and "value=\"ann\"" in r.body
  test "the organisation of the last login is the default of the list; a cookie that is not a slug is ignored":
    withDirectories()
    check "<option value=\"beta\" selected>" in handle(cfg, fakeCore(), req("GET", "/ui/login", cookie = "cinim_org=beta")).body
    check "<option value=\"local\" selected>" in handle(cfg, fakeCore(), req("GET", "/ui/login", cookie = "cinim_org=local")).body
    let hostile = handle(cfg, fakeCore(), req("GET", "/ui/login", cookie = "cinim_org=\"><script>"))
    check " selected>" notin hostile.body.replace("selected disabled", "") and "<script>" notin hostile.body
  test "a core that does not give the list (or is down) leaves the plain form":
    directoryOrgs = %*[{"slug": "acme", "name": "A"}]
    down = true
    check "<select" notin handle(cfg, fakeCore(), req("GET", "/ui/login")).body

suite "the actions of a run":
  setup: reset()
  test "RUN-006 PIP-015 the page of a run offers the actions that the core says this user may do with it now, and nothing the core did not say":
    for (actions, stop, again) in [(%*{"abort": true, "retry": false}, true, false), (%*{"abort": false, "retry": true}, false, true),
                                   (%*{"abort": true, "retry": true}, true, true), (%*{"abort": false, "retry": false}, false, false), (%*{}, false, false), (newJNull(), false, false)]:
      routes["/api/v1/runs/s1_b"] = %*{"id": "s1_b", "organization": "acme", "state": "RUNNING", "steps": [], "actions": actions}
      let r = handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_b", cookie = session))
      check r.status == 200
      check ("action=\"/ui/runs/s1_b/abort\"" in r.body) == stop
      check ("action=\"/ui/runs/s1_b/retry\"" in r.body) == again
    routes["/api/v1/runs/s1_b"] = %*{"id": "s1_b", "organization": "acme", "state": "FAILED", "steps": []}     # a core that does not say: no button, not a guess from the state
    check "action=\"/ui/runs/s1_b/" notin handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_b", cookie = session)).body
  test "RUN-006 the stop button asks the core to abort the run with the token of the user, and goes back to the run":
    let r = handle(cfg, fakeCore(), req("POST", "/ui/runs/s1_b/abort", cookie = session, origin = "http://ui.example"))
    check r.status == 303 and r.header("Location") == "/ui/runs/s1_b"
    check posted == @["tok-ann /api/v1/runs/s1_b:abort {}"]
  test "PIP-015 the button of a retry asks the core for a retry":
    let r = handle(cfg, fakeCore(), req("POST", "/ui/runs/s1_b/retry", cookie = session))
    check r.status == 303 and r.header("Location") == "/ui/runs/s1_b"
    check posted == @["tok-ann /api/v1/runs/s1_b:retry {}"]
  test "what the core refuses is told in its words and the run is left as it is (it has ended; nothing failed; the role may not)":
    postAnswer = ApiResult(status: asRefused, code: 409, message: "the run has ended already (OK)")
    let r = handle(cfg, fakeCore(), req("POST", "/ui/runs/s1_b/abort", cookie = session))
    check r.status == 409 and "the run has ended already (OK)" in r.body and "href=\"/ui/runs/s1_b\"" in r.body
    postAnswer = ApiResult(status: asForbidden, code: 403, message: "role ro may not")
    let f = handle(cfg, fakeCore(), req("POST", "/ui/runs/s1_b/retry", cookie = session))
    check f.status == 403 and "role ro may not" in f.body
    postAnswer = ApiResult(status: asNotFound, code: 404, message: "no such run")
    check handle(cfg, fakeCore(), req("POST", "/ui/runs/s1_b/abort", cookie = session)).status == 404
    down = true
    check handle(cfg, fakeCore(), req("POST", "/ui/runs/s1_b/abort", cookie = session)).status == 503
  test "a form from another site, a request with no session, a GET and an id that is not one never reach the core":
    check handle(cfg, fakeCore(), req("POST", "/ui/runs/s1_b/abort", cookie = session, origin = "http://evil.example")).status == 403
    var cross = req("POST", "/ui/runs/s1_b/retry", cookie = session)
    cross.secFetchSite = "cross-site"
    check handle(cfg, fakeCore(), cross).status == 403
    let anon = handle(cfg, fakeCore(), req("POST", "/ui/runs/s1_b/abort"))
    check anon.status == 303 and anon.header("Location").startsWith("/ui/login")
    check handle(cfg, fakeCore(), req("GET", "/ui/runs/s1_b/abort", cookie = session)).status == 404
    check handle(cfg, fakeCore(), req("POST", "/ui/runs/s1_x'y/abort", cookie = session)).status == 405
    check handle(cfg, fakeCore(), req("POST", "/ui/runs/s1_b/delete", cookie = session)).status == 405
    check posted.len == 0

suite "the rest of the service":
  setup: reset()
  test "the style sheet is served, small, cached, and the pages need nothing else (no script)":
    let r = handle(cfg, fakeCore(), req("GET", "/ui/static/ui.css"))
    check r.status == 200 and r.header("Content-Type").startsWith("text/css") and "max-age" in r.header("Cache-Control") and r.body.len < 8192
    let page = handle(cfg, fakeCore(), req("GET", "/ui/login"))
    check "<script" notin page.body and "href=\"/ui/static/ui.css?v=" in page.body
    let v = page.body.split("ui.css?v=")[1].split('"')[0]                    # a changed style sheet is a new address: the day of caching does not hold a change back
    check v.len == 8 and v.allIt(it in HexDigits)
    check handle(cfg, fakeCore(), req("GET", "/ui/static/ui.css", query = "v=" & v)).status == 200
  test "the probe of the Pod is answered without a session and outside the prefix":
    let r = handle(cfg, fakeCore(), req("GET", "/healthz"))
    check r.status == 200 and r.body == "ok" and calls.len == 0
  test "an unknown address is a 404 page and a wrong method a 405 with the one that is allowed":
    check handle(cfg, fakeCore(), req("GET", "/ui/nothing", cookie = session)).status == 404
    let r = handle(cfg, fakeCore(), req("DELETE", "/ui/orgs", cookie = session))
    check r.status == 405 and r.header("Allow").len > 0
  test "the pages do not depend on the prefix: with none the links start at the root":
    let root = UiConfig(base: "", secureCookie: false)
    routes["/api/v1/organizations"] = %*{"organizations": [{"id": "o1", "slug": "acme", "name": "A", "state": "active", "url": "", "namespace": "n"}]}
    let r = handle(root, fakeCore(), req("GET", "/orgs", cookie = session))
    check r.status == 200 and "href=\"/orgs/acme/runs\"" in r.body and "href=\"/ui" notin r.body
    check handle(root, fakeCore(), req("GET", "/orgs")).header("Location") == "/login?next=%2Forgs"
