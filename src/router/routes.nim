## The router's HTTP surface (SHD-006) as a pure function: a request goes in, a response comes out, so every route and every
## refusal is unit-tested without a socket (tests/unit/trouter.nim). main.nim only adapts GuildenStern to it.
##   POST <base>/list      a core registers its organisations (shared key)
##   GET  <base>/list      the organisations of all cores as JSON (shared key)
##   GET  <base>/          the page with the organisations and the availability chart (public unless listOrganizations is off)
##   GET  <base>/metrics   Prometheus text, public (it names cores, never organisations); can be turned off
##   GET  <base>/healthz   liveness
import std/[json, strutils]
import registry, render

type
  Config* = object
    key*: string
    basePath*: string          ## normalised: "" for "/", otherwise "/some/path" without the trailing slash
    listOrganizations*: bool   ## router.listOrganizations: false turns the page off, /list stays for the cores
    metrics*: bool             ## router.metrics: false turns /metrics off (404)

  Request* = object
    meth*, path*, auth*, body*: string   ## auth is the value of the Authorization header

  Response* = object
    code*: int
    contentType*, body*: string

func normalizeBase*(b: string): string =
  ## "/" and "" mean no base path; "/some/path/" becomes "/some/path"
  var s = b.strip
  if not s.startsWith("/"): s = "/" & s
  s = s.strip(chars = {'/'})
  if s.len == 0: "" else: "/" & s

func constantTimeEqual*(a, b: string): bool =
  ## the length is public, the content is compared without an early exit
  if a.len != b.len: return false
  var diff = 0
  for i in 0 ..< a.len:
    diff = diff or (ord(a[i]) xor ord(b[i]))
  diff == 0

func bearer*(auth: string): string =
  let a = auth.strip
  if a.len > 7 and a[0 ..< 7].toLowerAscii == "bearer ": a[7 .. ^1].strip else: ""

func problem(code: int; kind, detail: string): Response =
  Response(code: code, contentType: "application/problem+json",
           body: $(%*{"type": "about:blank", "status": code, "code": kind, "detail": detail}))

proc authorised(cfg: Config; req: Request): bool =
  cfg.key.len > 0 and constantTimeEqual(bearer(req.auth), cfg.key)

proc parseOrgs(j: JsonNode; orgs: var seq[OrgEntry]): string =
  if j.kind != JObject or not j.hasKey("organizations") or j["organizations"].kind != JArray:
    return "a JSON object with `core` and an `organizations` array is required"
  for o in j["organizations"]:
    if o.kind != JObject or not o.hasKey("slug") or o["slug"].kind != JString:
      return "every organisation needs a string `slug`"
    for k in ["name", "url"]:
      if o.hasKey(k) and o[k].kind != JString: return "`" & k & "` must be a string"
    orgs.add OrgEntry(slug: o["slug"].getStr, name: o{"name"}.getStr, url: o{"url"}.getStr)

proc handle*(r: var Registry; cfg: Config; req: Request; now: int64): Response =
  let path = req.path.split('?')[0]
  if path.len < cfg.basePath.len or path[0 ..< cfg.basePath.len] != cfg.basePath:
    return problem(404, "not_found", "no such route")
  let rest = path[cfg.basePath.len .. ^1].strip(leading = false, trailing = true, chars = {'/'})
  case rest
  of "":
    if req.meth != "GET": return problem(405, "method_not_allowed", "GET")
    if not cfg.listOrganizations: return problem(404, "not_found", "the page is turned off")
    Response(code: 200, contentType: "text/html; charset=utf-8", body: renderPage(r, now))
  of "/healthz":
    Response(code: 200, contentType: "text/plain", body: "ok\n")
  of "/list":
    if not authorised(cfg, req):
      return problem(401, "unauthorized", "the shared key is missing or wrong")
    case req.meth
    of "GET":
      Response(code: 200, contentType: "application/json", body: listJson(r, now))
    of "POST":
      let j = try: parseJson(req.body) except JsonParsingError: nil
      if j == nil or j.kind != JObject or not j.hasKey("core") or j["core"].kind != JString:
        return problem(400, "invalid_request", "a JSON object with `core` and an `organizations` array is required")
      var orgs: seq[OrgEntry]
      let bad = parseOrgs(j, orgs)
      if bad.len > 0: return problem(400, "invalid_request", bad)
      let err = r.post(j["core"].getStr, orgs, now)
      if err.len > 0: return problem(400, "invalid_request", err)
      Response(code: 204, contentType: "", body: "")
    else:
      problem(405, "method_not_allowed", "GET or POST")
  of "/metrics":
    if not cfg.metrics: return problem(404, "not_found", "metrics are turned off")
    if req.meth != "GET": return problem(405, "method_not_allowed", "GET")
    Response(code: 200, contentType: "text/plain; version=0.0.4; charset=utf-8", body: renderMetrics(r, now))
  else:
    problem(404, "not_found", "no such route")
