## The core's side of the router (SHD-006, D-39): every minute it POSTs the list of its organisations to the router under the shared
## key and GETs the list of all organisations, which feeds the organisation switcher; it finds a slug that another core also holds
## (checked when an organisation is created, and as an alert when the duplicate appears later). Everything that decides something is
## pure and takes the transport as a parameter, so the tests run it against the router's own `handle` without a socket.
import std/[json, httpclient, locks, os, strutils, times, atomics]

type
  RouterConfig* = object
    url*: string            ## the router's base URL with the base path, no trailing slash: https://ci.example.com/some/path
    key*: string            ## the shared key
    coreId*: string         ## how this core introduces itself (by default the shard name)
    publicBase*: string     ## https://<domain><basePath> without a trailing slash: the URL of an organisation is <publicBase>/<slug>/
    intervalSec*: int

  OwnOrg* = object
    slug*, name*: string

  RemoteOrg* = object
    slug*, name*, url*, core*: string

  RouterView* = object      ## what the core last learned from the router
    configured*: bool
    reachable*: bool        ## the last sync succeeded
    items*: seq[RemoteOrg]  ## the last list received (kept while the router is unreachable)
    fetchedAt*, registeredAt*: int64
    lastError*: string

  Transport* = proc (meth, url, key, body: string): tuple[code: int, body: string] {.closure.}

  Alert* = object
    code*, slug*, otherCore*: string

func orgUrl*(publicBase, slug: string): string =
  if publicBase.len == 0: "" else: publicBase & "/" & slug & "/"

func registrationBody*(cfg: RouterConfig; orgs: seq[OwnOrg]): string =
  var arr = newJArray()
  for o in orgs: arr.add %*{"slug": o.slug, "name": o.name, "url": orgUrl(cfg.publicBase, o.slug)}
  $(%*{"core": cfg.coreId, "organizations": arr})

proc parseList*(body: string): seq[RemoteOrg] =
  let j = parseJson(body)
  for o in j["organizations"]:
    result.add RemoteOrg(slug: o["slug"].getStr, name: o{"name"}.getStr, url: o{"url"}.getStr, core: o{"core"}.getStr)

func conflictWith*(items: seq[RemoteOrg]; coreId, slug: string): string =
  ## the other core that already holds the slug, "" when none does (SHD-001: checked when an organisation is created)
  for i in items:
    if i.slug == slug and i.core != coreId: return i.core

func alerts*(items: seq[RemoteOrg]; coreId: string; ownSlugs: seq[string]): seq[Alert] =
  ## a duplicate that appeared later, for instance because the router was unreachable when the organisation was created: shown in
  ## the UI, nothing is changed automatically
  for s in ownSlugs:
    let other = conflictWith(items, coreId, s)
    if other.len > 0: result.add Alert(code: "duplicate_slug", slug: s, otherCore: other)

proc syncOnce*(cfg: RouterConfig; tr: Transport; orgs: seq[OwnOrg]; now: int64; view: var RouterView) =
  ## one round: register, then read the list. A failure keeps the last list and records why.
  view.configured = true
  try:
    let post = tr("POST", cfg.url & "/list", cfg.key, registrationBody(cfg, orgs))
    if post.code != 204 and post.code != 200:
      view.reachable = false
      view.lastError = "register: HTTP " & $post.code & " " & post.body.substr(0, 120)
      return
    view.registeredAt = now
    let get = tr("GET", cfg.url & "/list", cfg.key, "")
    if get.code != 200:
      view.reachable = false
      view.lastError = "list: HTTP " & $get.code
      return
    view.items = parseList(get.body)
    view.fetchedAt = now
    view.reachable = true
    view.lastError = ""
  except CatchableError as e:
    view.reachable = false
    view.lastError = e.msg.substr(0, 160)

func switcher*(view: RouterView; own: seq[OwnOrg]; publicBase: string): seq[RemoteOrg] =
  ## the entries of the organisation drop-down: the router's last list when there is one, otherwise only this core's own organisations
  if view.items.len > 0: return view.items
  for o in own: result.add RemoteOrg(slug: o.slug, name: o.name, url: orgUrl(publicBase, o.slug))

func urlSupported*(url: string): string =
  ## "" when this build can talk to the router's URL; TLS needs a build with -d:ssl
  if url.toLowerAscii.startsWith("https://") and not defined(ssl):
    return "this build has no TLS support (build with -d:ssl) and the router URL is https"
  if not (url.toLowerAscii.startsWith("https://") or url.toLowerAscii.startsWith("http://")):
    return "the router URL must start with http:// or https://"
  ""

proc httpTransport*(meth, url, key, body: string): tuple[code: int, body: string] =
  var c = newHttpClient(timeout = 5000)
  defer: c.close()
  c.headers = newHttpHeaders({"Authorization": "Bearer " & key, "Content-Type": "application/json"})
  let r = c.request(url, httpMethod = (if meth == "POST": HttpPost else: HttpGet), body = body)
  (r.code.int, r.body)

# ------------------------------------------------------------------ the shared view and the loop

var
  lock: Lock
  shared {.guard: lock.}: RouterView
  sharedCfg {.guard: lock.}: RouterConfig

initLock(lock)

proc configure*(cfg: RouterConfig) =
  {.cast(gcsafe).}:
    withLock lock:
      sharedCfg = cfg
      shared = RouterView(configured: cfg.url.len > 0)

proc currentView*(): RouterView =
  {.cast(gcsafe).}:
    withLock lock: result = shared

proc currentConfig*(): RouterConfig =
  {.cast(gcsafe).}:
    withLock lock: result = sharedCfg

proc recordView*(v: RouterView) =
  {.cast(gcsafe).}:
    withLock lock: shared = v

proc serveRouterClient*(readOrgs: proc (): seq[OwnOrg] {.gcsafe.}; stop: ptr Atomic[bool]) {.thread.} =
  {.cast(gcsafe).}:
    let cfg = currentConfig()
    var waited = cfg.intervalSec * 10          # the first round at once
    var reported = ""                          # the last problem written to the log: a router that stays down is said once, not every round
    while not stop[].load:
      if waited >= cfg.intervalSec * 10:
        waited = 0
        var v = currentView()
        try:
          syncOnce(cfg, httpTransport, readOrgs(), getTime().toUnix, v)
        except CatchableError as e:
          v.reachable = false
          v.lastError = e.msg.substr(0, 160)
        recordView(v)
        let problem = if v.reachable: "" else: v.lastError.replace('\n', ' ')
        if problem != reported:
          if problem.len > 0: stderr.writeLine "core: router: " & problem & " (said once; the core keeps the last list and tries again every " & $cfg.intervalSec & " s)"
          else: stderr.writeLine "core: router: reachable again"
          reported = problem
      sleep 100
      inc waited
