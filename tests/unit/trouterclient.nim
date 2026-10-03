## SHD-006, D-39: the core's side of the router, run against the router's own request handler (no socket).
import std/[unittest, json, strutils]
import ../../src/core/routerclient
import ../../src/router/[registry, routes]

const t0 = 2_000_000'i64

proc wire(reg: ptr Registry; rcfg: routes.Config; now: ptr int64): Transport =
  ## a transport that hands the request to the router's `handle`
  result = proc (meth, url, key, body: string): tuple[code: int, body: string] =
    let path = url[url.find("/some/path") .. ^1]
    let r = handle(reg[], rcfg, routes.Request(meth: meth, path: path, auth: "Bearer " & key, body: body), now[])
    (r.code, r.body)

suite "SHD-006 the core registers and reads the list":
  let rcfg = routes.Config(key: "k", basePath: "/some/path", listOrganizations: true, metrics: true)
  proc mk(core: string): RouterConfig =
    RouterConfig(url: "https://ci.example.com/some/path", key: "k", coreId: core, publicBase: "https://ci.example.com/some/path", intervalSec: 60)

  test "the registration carries the core, the slugs, the names and the URLs":
    let j = parseJson(registrationBody(mk("001"), @[OwnOrg(slug: "acme", name: "Acme")]))
    check j["core"].getStr == "001" and j["organizations"][0]["url"].getStr == "https://ci.example.com/some/path/acme/"
  test "one sync registers and reads the list, own organisations included":
    var reg = newRegistry()
    var now = t0
    var v: RouterView
    syncOnce(mk("001"), wire(addr reg, rcfg, addr now), @[OwnOrg(slug: "acme", name: "Acme")], now, v)
    check v.reachable and v.items.len == 1 and v.items[0].core == "001" and v.fetchedAt == t0 and v.lastError == ""
  test "the list holds the organisations of the other cores":
    var reg = newRegistry()
    var now = t0
    var v1, v2: RouterView
    syncOnce(mk("001"), wire(addr reg, rcfg, addr now), @[OwnOrg(slug: "acme")], now, v1)
    syncOnce(mk("002"), wire(addr reg, rcfg, addr now), @[OwnOrg(slug: "beta")], now, v2)
    check v2.items.len == 2 and v2.items[0].slug == "acme" and v2.items[1].core == "002"
  test "a duplicate slug of another core is found when an organisation is created":
    var reg = newRegistry()
    var now = t0
    var v1, v2: RouterView
    syncOnce(mk("001"), wire(addr reg, rcfg, addr now), @[OwnOrg(slug: "acme")], now, v1)
    syncOnce(mk("002"), wire(addr reg, rcfg, addr now), @[], now, v2)
    check conflictWith(v2.items, "002", "acme") == "001"
    check conflictWith(v2.items, "001", "acme") == ""        # a core does not conflict with itself
    check conflictWith(v2.items, "002", "free") == ""
  test "a duplicate that appears later is an alert, nothing is changed":
    var reg = newRegistry()
    var now = t0
    var v1, v2: RouterView
    # core 002 created `acme` while the router was unreachable; both cores now register it
    syncOnce(mk("001"), wire(addr reg, rcfg, addr now), @[OwnOrg(slug: "acme")], now, v1)
    syncOnce(mk("002"), wire(addr reg, rcfg, addr now), @[OwnOrg(slug: "acme"), OwnOrg(slug: "mine")], now, v2)
    let a = alerts(v2.items, "002", @["acme", "mine"])
    check a.len == 1 and a[0].code == "duplicate_slug" and a[0].slug == "acme" and a[0].otherCore == "001"
  test "a wrong key is recorded as the reason and the last list is kept":
    var reg = newRegistry()
    var now = t0
    var v: RouterView
    syncOnce(mk("001"), wire(addr reg, rcfg, addr now), @[OwnOrg(slug: "acme")], now, v)
    var bad = mk("001")
    bad.key = "wrong"
    syncOnce(bad, wire(addr reg, rcfg, addr now), @[OwnOrg(slug: "acme")], now + 60, v)
    check not v.reachable and "401" in v.lastError and v.items.len == 1 and v.fetchedAt == t0
  test "an unreachable router keeps the last list; the switcher falls back to the own organisations when there never was one":
    var v: RouterView
    let down: Transport = proc (meth, url, key, body: string): tuple[code: int, body: string] = raise newException(IOError, "connection refused")
    syncOnce(mk("001"), down, @[OwnOrg(slug: "acme", name: "Acme")], t0, v)
    check not v.reachable and "connection refused" in v.lastError
    let s = switcher(v, @[OwnOrg(slug: "acme", name: "Acme")], "https://ci.example.com/some/path")
    check s.len == 1 and s[0].url == "https://ci.example.com/some/path/acme/"
    var withList = v
    withList.items = @[RemoteOrg(slug: "other", core: "002")]
    check switcher(withList, @[OwnOrg(slug: "acme")], "")[0].slug == "other"
  test "a router that answers with garbage is an error, not a crash":
    var v: RouterView
    let junk: Transport = proc (meth, url, key, body: string): tuple[code: int, body: string] = (if meth == "POST": (204, "") else: (200, "not json"))
    syncOnce(mk("001"), junk, @[], t0, v)
    check not v.reachable and v.lastError.len > 0
  test "the router URL must be usable by this build":
    check urlSupported("http://router.cinim.svc/some/path") == ""
    check urlSupported("ftp://x").len > 0
    check (urlSupported("https://x") == "") == defined(ssl)
