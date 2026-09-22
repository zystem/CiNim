import httpbeast, asyncdispatch, options
import nim_srv_common

proc onRequest(req: Request) {.async.} =
  case req.path.get
  of "/page": req.send(Http200, renderPage(), "Content-Type: text/html; charset=utf-8")
  of "/err": raise newException(ValueError, "boom")                    # exception in an async handler
  of "/rss": req.send(Http200, $rssKb())
  else: req.send(Http404)
run(onRequest, initSettings(port = Port(18802), numThreads = 1))
