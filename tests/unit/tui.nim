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

proc ok(body: JsonNode): ApiResult = ApiResult(status: asOk, code: 200, body: body)

proc fakeCore(): CoreApi =
  result.login = proc (user, password: string): ApiResult {.gcsafe.} =
    {.cast(gcsafe).}:
      if down: return ApiResult(status: asUnavailable, message: "the core does not answer")
      if password == "throttled": return ApiResult(status: asRefused, code: 429, message: "retry after 30 s")
      if user == "new" and password == "right-password-1234": return ok(%*{"token": "tok-new", "user": "new", "roles": ["admin"], "expires_at": 1800000000, "password_change_required": true})
      if user == "ann" and password == "right-password-1234": return ok(%*{"token": "tok-ann", "user": "ann", "roles": ["ro"], "expires_at": 1800000000, "password_change_required": false})
      ApiResult(status: asUnauthorized, code: 401, message: "bad_credentials")
  result.get = proc (token, path: string): ApiResult {.gcsafe.} =
    {.cast(gcsafe).}:
      calls.add token & " " & path
      if down: return ApiResult(status: asUnavailable, message: "the core does not answer")
      if token != "tok-ann": return ApiResult(status: asUnauthorized, code: 401, message: "bad token")
      if path in routes: ok(routes[path]) else: ApiResult(status: asNotFound, code: 404, message: "no such route")

let cfg = UiConfig(base: base, secureCookie: false)
let cfgSecure = UiConfig(base: base, secureCookie: true)

proc req(meth, path: string; query = ""; cookie = ""; form: Table[string, string] = initTable[string, string](); origin = ""; host = "ui.example"): UiRequest =
  UiRequest(meth: meth, path: path, query: query, cookie: cookie, form: form, origin: origin, host: host)

proc header(r: UiResponse; name: string): string =
  for (k, v) in r.headers:
    if k.toLowerAscii == name.toLowerAscii: return v

let session = "cinim_ui=tok-ann"

proc reset() =
  calls = @[]
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
      {"id": "s1_b", "organization": "acme", "group": "", "state": "FAILED", "created_at": "1792484469", "updated_at": "1792484999", "failure": {"code": "step_failed", "message": "step 1 exited with 2"}, "source": {"repository": "https://x/r.git", "commit": "e13ccc152d942eadb260c37b1b77e61dbfab4b80"}},
      {"id": "s1_a", "organization": "acme", "group": "", "state": "SUCCEEDED", "created_at": "1792484000", "updated_at": "1792484100"}], "next": "s1_a"}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", cookie = session))
    check r.status == 200
    check r.body.find("s1_b") < r.body.find("s1_a")                # the order of the core
    check "href=\"/ui/runs/s1_b\"" in r.body and "href=\"/ui/runs/s1_a\"" in r.body
    check "step_failed" in r.body and "step 1 exited with 2" in r.body and "e13ccc1" in r.body
    check "href=\"/ui/orgs/acme/runs?before=s1_a\"" in r.body       # the older runs
    check "2026-10-20 08:21:09" in r.body                           # a time a person reads (UTC), not epoch seconds
  test "the state filter goes to the core, is kept in the link to the older runs, and a state that is not a word is ignored":
    routes["/api/v1/runs?organization=acme&state=FAILED&limit=50"] = %*{"runs": [], "next": "s1_z"}
    let r = handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", query = "state=FAILED", cookie = session))
    check r.status == 200 and "href=\"/ui/orgs/acme/runs?state=FAILED&amp;before=s1_z\"" in r.body
    routes["/api/v1/runs?organization=acme&limit=50"] = %*{"runs": [], "next": nil}
    check handle(cfg, fakeCore(), req("GET", "/ui/orgs/acme/runs", query = "state=FAILED%27%20OR%201%3D1", cookie = session)).status == 200
    check calls[^1] == "tok-ann /api/v1/runs?organization=acme&limit=50"
  test "the list shows the last six characters of a long run id, the whole id is the link and its title; a short id stays whole":
    routes["/api/v1/runs?organization=acme&limit=50"] = %*{"runs": [{"id": "s1_01a15949-68a3-7db0-acd7-fb1c7c2e6f86", "state": "SUCCEEDED"}, {"id": "s1_a", "state": "FAILED"}]}
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
    routes["/api/v1/runs/s1_b"] = %*{"id": "s1_b", "organization": "acme", "group": "g/x", "state": "FAILED", "created_at": "1792484469", "updated_at": "1792484999",
      "failure": {"code": "step_failed", "message": hostile}, "source": {"repository": "https://x/r.git", "commit": "e13ccc152d942eadb260c37b1b77e61dbfab4b80", "path": ".ci/pipeline.lua"},
      "params": {"DEPLOY": "false"}, "wait_reason": "",
      "steps": [{"seq": 0, "attempt": 1, "state": "SUCCEEDED", "exit_code": 0, "termination": "ok", "pod_reason": "", "pod_message": "", "pod_diag": nil},
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
  test "the first window starts at line 0, has no way back, and a finished log has no way on":
    routes["/api/v1/runs/s1_b/steps/0/log?from=0&limit=200"] = %*{"run_id": "s1_b", "step_seq": 0, "from": 0, "lines": ["only line"], "next": 1, "step_state": "SUCCEEDED", "complete": true, "lines_total": 1}
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
