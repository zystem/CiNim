## SHD-006, D-39: the router's registry, its HTTP surface and its page (pure, no socket).
import std/[unittest, json, strutils]
import ../../src/router/[registry, routes, render]

const t0 = 1_000_000'i64

func org(slug: string; name = ""; url = ""): OrgEntry = OrgEntry(slug: slug, name: name, url: url)

suite "SHD-006 registry: registration, replacement and expiry":
  test "a POST replaces the whole list of that core and renews its time to live":
    var r = newRegistry(ttl = 300)
    check r.post("001", @[org("acme"), org("beta")], t0) == ""
    check r.list(t0).len == 2
    check r.post("001", @[org("gamma")], t0 + 60) == ""
    check r.list(t0 + 60).len == 1 and r.list(t0 + 60)[0].slug == "gamma"
  test "an entry that is not renewed disappears after the time to live":
    var r = newRegistry(ttl = 300)
    discard r.post("001", @[org("acme")], t0)
    check r.list(t0 + 300).len == 1
    check r.list(t0 + 301).len == 0
  test "two cores that list the same slug both appear, so a core can find the duplicate":
    var r = newRegistry()
    discard r.post("001", @[org("acme")], t0)
    discard r.post("002", @[org("acme")], t0)
    let l = r.list(t0)
    check l.len == 2 and l[0].core == "001" and l[1].core == "002"
  test "the list is sorted by slug":
    var r = newRegistry()
    discard r.post("001", @[org("zeta"), org("alpha")], t0)
    check r.list(t0)[0].slug == "alpha"
  test "invalid input is refused and changes nothing":
    var r = newRegistry()
    discard r.post("001", @[org("acme")], t0)
    check r.post("001", @[org("Bad Slug")], t0 + 1).len > 0
    check r.post("", @[org("x")], t0 + 1).len > 0
    check r.post("001", @[org("a"), org("a")], t0 + 1).len > 0
    check r.post("001", @[org("x", url = "ftp://x")], t0 + 1).len > 0
    check r.post("001", @[org("x", name = repeat("n", 300))], t0 + 1).len > 0
    check r.list(t0 + 1).len == 1 and r.list(t0 + 1)[0].slug == "acme"
  test "the registry is bounded":
    var r = newRegistry()
    var many: seq[OrgEntry]
    for i in 0 .. maxOrgsPerCore: many.add org("o" & $i)
    check r.post("001", many, t0).len > 0
    for i in 0 ..< maxCores: check r.post("c" & $i, @[], t0) == ""
    check r.post("one-more", @[], t0).len > 0

suite "SHD-006 registry: the availability history":
  test "one cell per minute: up while the registration is within the time to live, down after":
    var r = newRegistry(ttl = 120)
    discard r.post("001", @[org("acme")], t0)
    r.tick(t0 + 60)
    r.tick(t0 + 120)
    r.tick(t0 + 180)      # 180 s after the last POST: down
    let s = r.status(t0 + 180)
    check s[0].cells == @[true, true, false] and not s[0].up
  test "the history is bounded and keeps the newest cells":
    var r = newRegistry(ttl = 10, history = 5)
    for i in 1 .. 8:
      discard r.post("001", @[], t0 + int64(i) * 60)
      r.tick(t0 + int64(i) * 60)
    check r.status(t0 + 480)[0].cells.len == 5
  test "a core nobody has heard of for the whole history is forgotten":
    var r = newRegistry(ttl = 10, history = 2)
    discard r.post("001", @[], t0)
    r.tick(t0 + 60)
    check r.status(t0 + 60).len == 1
    r.tick(t0 + 121)
    check r.status(t0 + 121).len == 0
  test "the share of up cells":
    check upShare(@[true, true, false, false]) == 0.5
    check upShare(@[]) == 0.0

suite "SHD-006 HTTP surface":
  let cfg = Config(key: "s3cret", basePath: normalizeBase("/some/path/"), listOrganizations: true, metrics: true)
  proc req(meth, path: string; auth = "Bearer s3cret"; body = ""): Request =
    Request(meth: meth, path: path, auth: auth, body: body)
  const body1 = """{"core":"001","organizations":[{"slug":"acme","name":"Acme","url":"https://c1.example/some/path/acme/"}]}"""

  test "the base path is normalised":
    check normalizeBase("/") == "" and normalizeBase("") == ""
    check normalizeBase("/some/path/") == "/some/path" and normalizeBase("some/path") == "/some/path"
  test "POST then GET /list round-trips; GET needs the key too":
    var r = newRegistry()
    check handle(r, cfg, req("POST", "/some/path/list", body = body1), t0).code == 204
    let g = handle(r, cfg, req("GET", "/some/path/list"), t0 + 1)
    check g.code == 200 and parseJson(g.body)["organizations"][0]["slug"].getStr == "acme"
    check handle(r, cfg, req("GET", "/some/path/list", auth = ""), t0 + 1).code == 401
  test "a missing or wrong key is refused, a right one is case-insensitive about the scheme":
    var r = newRegistry()
    check handle(r, cfg, req("POST", "/some/path/list", auth = "", body = body1), t0).code == 401
    check handle(r, cfg, req("POST", "/some/path/list", auth = "Bearer wrong", body = body1), t0).code == 401
    check handle(r, cfg, req("POST", "/some/path/list", auth = "bearer s3cret", body = body1), t0).code == 204
    check r.list(t0).len == 1
  test "a router without a key refuses everything that needs one":
    var r = newRegistry()
    check handle(r, Config(key: "", basePath: "", listOrganizations: true, metrics: true), req("GET", "/list", auth = "Bearer "), t0).code == 401
  test "bad bodies are 400 problems":
    var r = newRegistry()
    check handle(r, cfg, req("POST", "/some/path/list", body = "not json"), t0).code == 400
    check handle(r, cfg, req("POST", "/some/path/list", body = """{"organizations":[]}"""), t0).code == 400
    check handle(r, cfg, req("POST", "/some/path/list", body = """{"core":"001","organizations":[{"slug":1}]}"""), t0).code == 400
    check handle(r, cfg, req("POST", "/some/path/list", body = """{"core":"001","organizations":[{"slug":"A B"}]}"""), t0).code == 400
  test "paths outside the base path are not ours (the bare domain belongs to the user)":
    var r = newRegistry()
    check handle(r, cfg, req("GET", "/"), t0).code == 404
    check handle(r, cfg, req("GET", "/list"), t0).code == 404
    check handle(r, cfg, req("GET", "/some/pathology"), t0).code == 404
  test "with the empty base path the router owns the bare domain":
    var r = newRegistry()
    let c0 = Config(key: "k", basePath: "", listOrganizations: true, metrics: true)
    check handle(r, c0, req("GET", "/"), t0).code == 200
    check handle(r, c0, req("GET", "/list", auth = "Bearer k"), t0).code == 200
  test "the page is public and can be turned off while /list stays":
    var r = newRegistry()
    check handle(r, cfg, req("GET", "/some/path/", auth = ""), t0).code == 200
    check handle(r, cfg, req("GET", "/some/path", auth = ""), t0).code == 200
    let off = Config(key: "s3cret", basePath: "/some/path", listOrganizations: false, metrics: true)
    check handle(r, off, req("GET", "/some/path/", auth = ""), t0).code == 404
    check handle(r, off, req("GET", "/some/path/list"), t0).code == 200
  test "metrics are public, name the cores and never an organisation":
    var r = newRegistry()
    discard r.post("001", @[org("acme")], t0)
    let m = handle(r, cfg, req("GET", "/some/path/metrics", auth = ""), t0)
    check m.code == 200 and "cinim_router_core_up{core=\"001\"} 1" in m.body and "cinim_router_organizations 1" in m.body
    check "acme" notin m.body
  test "metrics can be turned off, then the route does not exist":
    var r = newRegistry()
    let off = Config(key: "s3cret", basePath: "/some/path", listOrganizations: true, metrics: false)
    check handle(r, off, req("GET", "/some/path/metrics"), t0).code == 404
    check handle(r, off, req("GET", "/some/path/list"), t0).code == 200
  test "methods are checked":
    var r = newRegistry()
    check handle(r, cfg, req("DELETE", "/some/path/list"), t0).code == 405
    check handle(r, cfg, req("POST", "/some/path/"), t0).code == 405
  test "the key is compared without an early exit":
    check constantTimeEqual("abc", "abc") and not constantTimeEqual("abc", "abd") and not constantTimeEqual("abc", "ab")

suite "SHD-006 the page":
  test "hostile names and URLs are escaped":
    var r = newRegistry()
    discard r.post("001", @[org("acme", name = "<script>alert(1)</script>", url = "https://x.example/\"onmouseover=\"")], t0)
    let p = renderPage(r, t0)
    check "<script>alert" notin p and "&lt;script&gt;" in p and "\"onmouseover=\"" notin p
  test "the chart is an SVG with a table alternative, and long runs collapse into few rectangles":
    var r = newRegistry(ttl = 120)
    discard r.post("001", @[org("acme")], t0)
    for i in 1 .. 100:      # 100 up cells in a row
      discard r.post("001", @[org("acme")], t0 + int64(i) * 60)
      r.tick(t0 + int64(i) * 60)
    let p = renderPage(r, t0 + 6000)
    check "<svg" in p and "availability, last 24 hours" in p and "% up over" in p
    check p.count("<rect") < 10
  test "a core that is down is shown as down with the time since it was last seen":
    var r = newRegistry(ttl = 60)
    discard r.post("001", @[org("acme")], t0)
    let p = renderPage(r, t0 + 600)
    check "class=\"down\"" in p and "10 min ago" in p
  test "a core without history says so":
    var r = newRegistry()
    discard r.post("001", @[org("acme")], t0)
    check "no history yet" in renderPage(r, t0)
