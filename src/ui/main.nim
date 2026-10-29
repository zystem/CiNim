## `cinim-ui`: the UI service (docs/ui.md). It listens on plain HTTP (the Ingress carries the TLS), keeps nothing, and asks the core for everything with the token of the user, which the
## browser keeps in a cookie. Settings (the environment):
##   CINIM_UI_CORE_URL     the core's API, http://host:port (default http://cinim-core:80, the Service of the chart)
##   CINIM_UI_PORT         18100
##   CINIM_UI_BASE         the prefix of the UI in the address, "/ui" (a path that begins with a slash, or "" for the root)
##   CINIM_UI_COOKIE_SECURE  "on" when the UI is reached over HTTPS: the cookie then says Secure
##   CINIM_UI_TIMEOUT_MS   how long a call to the core may take (10000)
##   CINIM_UI_THREADS      threads of the server (4)
import std/[os, strutils, tables, uri, atomics, posix]
import ../common/httpsrv
import app, coreapi

var
  cfg: UiConfig
  api: CoreApi

func headerOf(raw, name: string): string =
  ## a header of the raw request: only the head is looked at, the name is case-insensitive
  let headEnd = raw.find("\r\n\r\n")
  let head = if headEnd >= 0: raw[0 ..< headEnd] else: raw
  for line in head.split("\r\n"):
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].strip.toLowerAscii == name.toLowerAscii: return line[colon + 1 .. ^1].strip

proc onRequest() {.gcsafe, nimcall, raises: [].} =
  {.cast(gcsafe).}:
    try:
      let target = getUri()
      let q = target.find('?')
      var req = UiRequest(meth: getMethod(), path: (if q >= 0: target[0 ..< q] else: target), query: (if q >= 0: target[q + 1 .. ^1] else: ""))
      let raw = getRequest()
      req.cookie = headerOf(raw, "cookie")
      req.host = headerOf(raw, "host")
      req.origin = headerOf(raw, "origin")
      req.secFetchSite = headerOf(raw, "sec-fetch-site")
      if req.meth == "POST":
        for k, v in decodeQuery(getBody()):
          req.form[k] = v
          req.formPairs.add (k, v)
      let r = handle(cfg, api, req)
      var headers: seq[string]
      for (k, v) in r.headers: headers.add k & ": " & v
      reply(HttpCode(r.status), r.body, headers)
    except Exception as e:
      reply(Http500, "internal error")

var stopFlag: Atomic[bool]
proc onSignal(sig: cint) {.noconv.} = stopFlag.store(true)

when isMainModule:
  let port = try: parseInt(getEnv("CINIM_UI_PORT", "18100")) except ValueError: 18100
  let base = getEnv("CINIM_UI_BASE", "/ui").strip(leading = false, trailing = true, chars = {'/'})
  if base.len > 0 and (base[0] != '/' or base.len > 60):
    stderr.writeLine "cinim-ui: CINIM_UI_BASE must be a path that begins with a slash (or empty): " & base
    quit 2
  cfg = UiConfig(base: base, secureCookie: getEnv("CINIM_UI_COOKIE_SECURE").toLowerAscii in ["on", "true", "1"])
  api = httpCoreApi(getEnv("CINIM_UI_CORE_URL", "http://cinim-core:80"), (try: parseInt(getEnv("CINIM_UI_TIMEOUT_MS", "10000")) except ValueError: 10000))
  let s = newService(onRequest)
  discard s.start(port, uint(max(2, (try: parseInt(getEnv("CINIM_UI_THREADS", "4")) except ValueError: 4))))
  echo "cinim-ui: listening on ", port, ", the prefix is '", base, "', the core is ", getEnv("CINIM_UI_CORE_URL", "http://cinim-core:80")
  signal(SIGINT, onSignal)
  signal(SIGTERM, onSignal)
  while not stopFlag.load: sleep 200
  shutdown()
