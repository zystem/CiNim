## D-105: the keys of the channels are read again when they change (a certificate renewed by cert-manager): the clients take up the new files at their next connection (`clientTls`), the core looks
## at its files (`checkCerts`) and starts its servers again with the new ones (`startReloading`/`refresh`). A set that cannot be used is told and the old one stays.
import std/[unittest, os, osproc, strutils, atomics]
import ../../src/core/[grpcserve, certwatch]
import ../support/testcerts
import ../support/freeport

proc echoHandler(ctx: var ServerContext; req: seq[byte]): seq[byte] {.nimcall, gcsafe, raises: [CatchableError].} = req

proc makeSet(suffix: string): string =
  ## a whole set of keys of its own (its own CA)
  result = getTempDir() / ("tcertwatch-" & $getCurrentProcessId() & suffix)
  createDir result
  if execCmd("sh " & quoteShell(getCurrentDir() / "tools" / "grpc" / "gen_tls.sh") & " " & quoteShell(result) & " 2 >/dev/null 2>&1") != 0: result = ""

proc copySet(fromDir, toDir: string) =
  for name in ["ca.pem", "core.pem", "core.key", "client.pem", "client.key"]:
    copyFile(fromDir / "tls" / name, toDir / "tls" / name)

let a = makeSet("-a")
let b = makeSet("-b")

suite "D-105 renewed keys are taken up":
  setup:
    if a.len == 0 or b.len == 0: skip()

  test "the files are looked at no oftener than asked, and a change that can be used raises the generation":
    let live = makeSet("-live")
    defer: removeDir live
    copySet(a, live)
    var w: CertWatch
    let g0 = certGeneration.load
    check not w.checkCerts(live, 60.0, now = 1000.0)             # the first look only learns what is there
    check not w.checkCerts(live, 60.0, now = 1010.0)             # too soon
    copySet(b, live)
    check not w.checkCerts(live, 60.0, now = 1020.0)             # changed, but not time to look yet
    check certGeneration.load == g0
    check w.checkCerts(live, 60.0, now = 1100.0)
    check certGeneration.load == g0 + 1
    check not w.checkCerts(live, 60.0, now = 1200.0)             # nothing new
    check certGeneration.load == g0 + 1

  test "a set that cannot be used is told once and not taken; the next good one is":
    let live = makeSet("-live2")
    defer: removeDir live
    copySet(a, live)
    var w: CertWatch
    let g0 = certGeneration.load
    discard w.checkCerts(live, 1.0, now = 1000.0)
    writeFile(live / "tls" / "core.pem", "not a certificate")
    check not w.checkCerts(live, 1.0, now = 1010.0)
    check not w.checkCerts(live, 1.0, now = 1020.0)
    check certGeneration.load == g0
    copySet(b, live)
    check w.checkCerts(live, 1.0, now = 1030.0)
    check certGeneration.load == g0 + 1

  test "0 seconds is never":
    let live = makeSet("-live3")
    defer: removeDir live
    copySet(a, live)
    var w: CertWatch
    check not w.checkCerts(live, 0.0, now = 1000.0)
    copySet(b, live)
    check not w.checkCerts(live, 0.0, now = 5000.0)

  test "a server started again with the new files serves a client that read the new files, and no more the one that has the old":
    let live = makeSet("-live4")
    defer: removeDir live
    copySet(a, live)
    const port = 28795                                            # the port is the same after the restart, as the core's are
    requireFreePort(port, "tcertwatch")
    var srv = startReloading(port, live, logIngestMethod, echoHandler)
    defer: srv.stop()
    let oldClient = dialCore("127.0.0.1:" & $port, live)
    defer: oldClient.close()
    check oldClient.exchange(logIngestMethod, "one", 3000) == (true, "one")
    check not srv.refresh()                                       # nothing changed
    # the renewal: new files, and the generation raised by checkCerts
    sleep 20
    copySet(b, live)
    certGeneration.atomicInc
    check srv.refresh()
    # a client made after the change reads the new client pair and CA (clientTls sees that the files differ)
    let fresh = dialCore("127.0.0.1:" & $port, live)
    defer: fresh.close()
    var served = false
    for attempt in 0 ..< 3:
      if fresh.exchange(logIngestMethod, "two", 3000) == (true, "two"):
        served = true
        break
    check served
    # the connection that was up before is closed by the restart; made again it has the new files too
    var again = false
    for attempt in 0 ..< 3:
      if oldClient.exchange(logIngestMethod, "three", 3000) == (true, "three"):
        again = true
        break
    check again

if a.len > 0: removeDir a
if b.len > 0: removeDir b
