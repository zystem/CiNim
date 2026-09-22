import mummy, mummy/routers
import nim_srv_common

proc page(r: Request) = r.respond(200, @[("Content-Type", "text/html; charset=utf-8")], renderPage())
proc err(r: Request) = raise newException(ValueError, "boom")          # mummy turns handler exceptions into 500
proc rss(r: Request) = r.respond(200, @[], $rssKb())
var router: Router
router.get("/page", page)
router.get("/err", err)
router.get("/rss", rss)
let server = newServer(router, workerThreads = 8)
server.serve(Port(18801))
