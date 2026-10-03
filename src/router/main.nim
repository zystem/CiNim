## Router (SHD-006, D-39): the registry of organisations for the `multi` mode. Cores register their organisations with POST /list under
## a shared key and read the whole list with GET /list; people see a page with the list and the availability of every core. The router
## proxies nothing and never calls Kubernetes. Configuration, all environment variables:
##   ROUTER_KEY            the shared key (required)
##   ROUTER_PORT           8080
##   ROUTER_BASE_PATH      "/" (the `basePath` of the charts)
##   ROUTER_TTL            300 seconds a registration stays valid (router.ttl)
##   ROUTER_LIST_PAGE      "true"; "false" turns the page off (router.listOrganizations)
##   ROUTER_METRICS        "true"; "false" turns /metrics off (router.metrics)
import std/[os, strutils, times, locks, atomics, posix]
import guildenstern/[dispatcher, httpserver]
import ../common/memstats
import registry, routes

var
  lock: Lock
  reg {.guard: lock.}: Registry
  cfg: Config
  stop: Atomic[bool]

initLock(lock)

proc authHeader(): string {.raises: [].} =
  ## the value of the Authorization header from the raw request
  try:
    for line in getRequest().splitLines:
      if line.len > 14 and line[0 ..< 14].toLowerAscii == "authorization:":
        return line[14 .. ^1].strip
  except CatchableError: discard

proc onRequest() {.raises: [], gcsafe.} =
  {.cast(gcsafe).}:
    try:
      let req = Request(meth: getMethod(), path: getUri(), auth: authHeader(), body: (if getMethod() == "POST": getBody() else: ""))
      var resp: Response
      withLock lock:
        resp = handle(reg, cfg, req, getTime().toUnix)
      if resp.code == 204:
        reply(Http204)
      else:
        let hdrs = if resp.contentType.len > 0: @["Content-Type: " & resp.contentType] else: @[]
        reply(HttpCode(resp.code), resp.body, hdrs)
    except CatchableError as e:
      reply(Http500, "{\"code\":\"internal\",\"detail\":" & $(e.msg.len) & "}", ["Content-Type: application/json"])

proc sampler() {.thread.} =
  ## one availability cell per core every minute
  {.cast(gcsafe).}:
    var slept = 0
    while not stop.load:
      sleep 100
      inc slept
      if slept >= 600:
        slept = 0
        withLock lock:
          reg.tick(getTime().toUnix)

proc main() =
  setStdIoUnbuffered()
  cfg.key = getEnv("ROUTER_KEY")
  if cfg.key.len == 0:
    stderr.writeLine "router: ROUTER_KEY is required"
    quit 2
  cfg.basePath = normalizeBase(getEnv("ROUTER_BASE_PATH", "/"))
  cfg.listOrganizations = getEnv("ROUTER_LIST_PAGE", "true") != "false"
  cfg.metrics = getEnv("ROUTER_METRICS", "true") != "false"
  let port = parseInt(getEnv("ROUTER_PORT", "8080"))
  let ttl = parseInt(getEnv("ROUTER_TTL", "300"))
  withLock lock:
    reg = newRegistry(ttl.int64)
  var t: Thread[void]
  createThread(t, sampler)
  let s = newHttpServer(onRequest)
  s.start(port, 8)
  echo "router: listening on ", port, ", base path '", cfg.basePath, "', ttl ", ttl, " s, page ", cfg.listOrganizations, ", rss ", rssBytes()
  proc onSignal(sig: cint) {.noconv.} = stop.store(true)
  signal(SIGTERM, onSignal)
  signal(SIGINT, onSignal)
  while not stop.load: sleep 100
  echo "router: stopping"
  joinThread(t)

main()
