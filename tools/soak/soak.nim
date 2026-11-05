## Soak harness (NFR-013). One process, worker threads under steady load:
##   grpc   gRPC with mutual TLS and Protobuf (the counters and the CSV columns are still called zmq_*), half of the requests on fresh connections (A.12)
##   lua    sandbox create, journaled run, "kill" and replay, destroy
##   rqlite optional (SOAK_RQLITE_URL): CAS updates and reads
## The main thread samples RSS and Nim heap into a CSV and, at the end, checks RSS growth
## after warm-up against SOAK_MAX_GROWTH_PCT (NFR-013: 2%).
## Build: nim c -d:release tools/soak/soak.nim  (add -d:sanitize + asan flags for LSan). A static nghttp2 in /opt/nghttp2 (or -d:nghttp2Prefix); the keys: tools/grpc/gen_tls.sh build/soak-certs.
import std/[os, strutils, atomics, times, options, json]
import protobuf_serialization
import protobuf_serialization/files/type_generator
import common/[corechannel, memstats, rqlite]
import core/grpcserve
import executor/[sandbox, journal, replay]
import ../../tests/unit/support/fixture

import_proto3 "../../proto/vectors.proto"

let port = parseInt(getEnv("SOAK_PORT", "19700"))
let certs = getEnv("SOAK_CERTS", getCurrentDir() / "build" / "soak-certs")
  ## `<certs>/tls/*` (tools/grpc/gen_tls.sh) - the same mutual TLS the real core and shims use. The keys are read when the process starts and cached (common/corechannel.nim `clientTls`), not at every
  ## connection: a soak run is meant to survive for days, and anything that makes the key files briefly unavailable (another process touching the working directory, an editor save, a
  ## `git checkout`) must not crash the whole run.
const soakMethod = "/cicd.Soak/Echo"

var stop: Atomic[bool]
var serverReady: Atomic[bool]
var joined: Atomic[bool]     # set once every worker thread has been joined; see the watchdog below
var zmqOk, zmqFail, luaOk, luaFail, rqOk, rqFail: Atomic[int]      # the names of the counters are those of the columns of the CSV, which older runs also have (zmq_ok is the gRPC channel)

proc echo(ctx: var ServerContext; body: seq[byte]): seq[byte] {.nimcall, gcsafe, raises: [CatchableError].} =
  ## the server: a message that starts with "pb:" is a Protobuf `Inner` whose n is returned plus one, anything else comes back as it came
  let text = toStr(body)
  if not text.startsWith("pb:"): return body
  let m = Protobuf.decode(cast[seq[byte]](text[3 .. ^1]), Inner)
  let enc = Protobuf.encode(Inner(name: m.name, n: m.n + 1))
  var reply = "pb:"
  for c in enc: reply.add char(c)
  toBytes(reply)

proc serverLoop() {.thread.} =
  {.cast(gcsafe).}:
    let srv = startShimServer(port, certs, soakMethod, echo)
    serverReady.store(true)
    while not stop.load: sleep 200
    srv.stop(graceMs = 1000)

proc dial(): CoreChannel =
  dialCore("tcp://127.0.0.1:" & $port, certs)

proc roundTrip(conn: CoreChannel; n: int): bool =
  let enc = Protobuf.encode(Inner(name: "step-" & $n, n: int32(n mod 1000)))
  var msg = "pb:"
  for b in enc: msg.add char(b)
  let (avail, body) = conn.exchange(soakMethod, msg, 5000)
  if not avail or not body.startsWith("pb:"): return false
  Protobuf.decode(cast[seq[byte]](body[3 .. ^1]), Inner).n == int32(n mod 1000) + 1

proc zmqClientBody(churn: bool)

proc zmqClient(churn: bool) {.thread.} =
  {.cast(gcsafe).}: zmqClientBody(churn)

proc zmqClientBody(churn: bool) =
  while not serverReady.load: sleep 20
  var n = 0
  if churn:
    while not stop.load:      # a fresh connection per request
      let s = dial()
      if roundTrip(s, n): zmqOk.atomicInc
      elif not stop.load: zmqFail.atomicInc
      s.close()
      inc n
      sleep 5
  else:
    var s = dial()
    while not stop.load:      # one long connection, but redial on any failure: a channel that
      if roundTrip(s, n):     # goes bad must not spin (or block) forever on the same handle,
        zmqOk.atomicInc        # which once left a soak run stuck for 18+ hours
      else:                   #
        if not stop.load: zmqFail.atomicInc
        s.close()
        s = dial()
      inc n
      sleep 2
    s.close()

proc luaWorker() {.thread.} =
  var round = 0
  while not stop.load:
    {.cast(gcsafe).}:
      var sb = newSandbox(memLimit = 16 * 1024 * 1024)
      var j = Journal()
      let r1 = sb.execute(j, scriptSrc, fakeHost)
      # "kill": drop the sandbox, keep the journal, replay in a new one
      var sb2 = newSandbox(memLimit = 16 * 1024 * 1024)
      var j2 = j
      var calls = 0
      let counting: HostCallProc = proc(seq: int; kind, payload: string): Option[string] =
        inc calls
        fakeHost(seq, kind, payload)
      let r2 = sb2.execute(j2, scriptSrc, counting)
      if r1.code == "ok" and r2.code == "ok" and calls == 0 and r1.value == r2.value:
        luaOk.atomicInc
      else: luaFail.atomicInc
      # a runaway script must end with a limit code, not grow the process
      var sb3 = newSandbox(memLimit = 4 * 1024 * 1024, instrLimit = 200_000)
      let r3 = sb3.run("local t = {} for i = 1, 1e9 do t[i] = ('x'):rep(100) end")
      if r3.code notin ["memory_limit", "instruction_limit"]: luaFail.atomicInc
    inc round
    sleep 20

proc rqWorker(url: string) {.thread.} =
  var c: RqClient
  {.cast(gcsafe).}:
    c = newRq(url, 5000)
    try:
      discard c.execute(%*[["CREATE TABLE IF NOT EXISTS soak (id INTEGER PRIMARY KEY, n INTEGER)"],
                           ["INSERT OR IGNORE INTO soak (id, n) VALUES (1, 0)"]])
    except CatchableError: discard
  while not stop.load:
    {.cast(gcsafe).}:
      try:
        discard c.execute(%*[["UPDATE soak SET n = n + 1 WHERE id = 1"]])
        discard c.query(%*[["SELECT n FROM soak WHERE id = 1"]])
        rqOk.atomicInc
      except CatchableError:
        rqFail.atomicInc
        c = newRq(url, 5000)
    sleep 50

when defined(sanitize):
  proc lsanCheck(): cint {.importc: "__lsan_do_recoverable_leak_check".}
  ## Only catches leaks in code ASan's allocator takeover covers process-wide (our Nim/C code, and any
  ## heap traffic the C libraries (nghttp2, BearSSL) do through the same malloc/free, even though they are not compiled
  ## with -fsanitize=address) - it cannot find memory corruption *inside* their own uninstrumented
  ## code. The same caveat applies to any uninstrumented native library.

proc exitProc(code: cint) {.importc: "_exit", header: "<unistd.h>".}
  ## Bypasses Nim's normal teardown (which would itself wait on threads); only for the watchdog.

proc watchdogBody(graceSeconds: int) {.thread.} =
  ## Safety net for shutdown: `stop.store(true)` should make every worker thread exit its loop
  ## within a couple of seconds, but a wedged socket or a stuck join must not be able to hang the whole
  ## run silently for hours the way one once did (a stuck client thread blocked the hourly
  ## LSan loop for good). If the joins in main() have not all completed within `graceSeconds` of stop being
  ## requested, force-exit so the caller (run72.sh) sees a clear non-zero exit and moves on instead of
  ## hanging indefinitely.
  for _ in 0 ..< graceSeconds:
    if joined.load: return
    sleep 1000
  if not joined.load:
    stderr.writeLine "SOAK WATCHDOG: shutdown did not finish within " & $graceSeconds & "s, forcing exit"
    stderr.flushFile()
    exitProc(4)

proc main() =
  let seconds = parseInt(getEnv("SOAK_SECONDS", "60"))
  let sampleEvery = parseInt(getEnv("SOAK_SAMPLE_SECONDS", "10"))
  let warmup = parseInt(getEnv("SOAK_WARMUP_SECONDS", $max(seconds div 10, 5)))
  let maxGrowth = parseFloat(getEnv("SOAK_MAX_GROWTH_PCT", "2"))
  let csv = getEnv("SOAK_CSV", "soak.csv")
  let rq = getEnv("SOAK_RQLITE_URL")
  # SOAK_ROLE splits the process to see which side owns a memory trend: "server" = only the REP loop, "client" = only the
  # request threads (against a server started elsewhere on SOAK_PORT), "both" (default) = as before
  let role = getEnv("SOAK_ROLE", "both")
  var srv: Thread[void]
  var clients: array[8, Thread[bool]]
  var lw: Thread[void]
  var rw: Thread[string]
  if role != "client": createThread(srv, serverLoop) else: serverReady.store(true)
  var nc = 0
  if role != "server":
    for ch in getEnv("SOAK_ZMQ", "ccp"):
      createThread(clients[nc], zmqClient, ch == 'c')
      inc nc
      sleep 300
  let luaOn = getEnv("SOAK_LUA", "1") == "1"
  if luaOn: createThread(lw, luaWorker)
  if rq.len > 0: createThread(rw, rqWorker, rq)
  let f = open(csv, fmWrite)
  f.writeLine "t,rss,nim_occupied,zmq_ok,zmq_fail,lua_ok,lua_fail,rq_ok,rq_fail"
  let t0 = epochTime()
  var warmRss = 0
  var lastRss = 0
  var maxRss = 0
  while epochTime() - t0 < seconds.float:
    sleep sampleEvery * 1000
    let t = int(epochTime() - t0)
    lastRss = rssBytes()
    when defined(sanitize):
      if t mod 3600 < sampleEvery and t > 0:   # hourly leak check without stopping the run
        if lsanCheck() != 0: echo "SOAK LEAK reported at t=", t
    if t >= warmup:
      if warmRss == 0: warmRss = lastRss
      maxRss = max(maxRss, lastRss)
    f.writeLine [$t, $lastRss, $getOccupiedMem(), $zmqOk.load, $zmqFail.load, $luaOk.load,
                 $luaFail.load, $rqOk.load, $rqFail.load].join(",")
    f.flushFile()
  stop.store(true)
  var watchdog: Thread[int]
  createThread(watchdog, watchdogBody, parseInt(getEnv("SOAK_SHUTDOWN_GRACE_SECONDS", "120")))
  if role != "client": joinThread(srv)
  for i in 0 ..< nc: joinThread(clients[i])
  if luaOn: joinThread(lw)
  if rq.len > 0: joinThread(rw)
  joined.store(true)         # tell the watchdog the joins above finished cleanly
  joinThread(watchdog)
  f.close()
  let growth = if warmRss > 0: (lastRss - warmRss).float * 100 / warmRss.float else: 0.0
  echo "SOAK warm_rss=", warmRss, " last_rss=", lastRss, " max_rss=", maxRss,
       " growth_pct=", formatFloat(growth, ffDecimal, 2),
       " zmq=", zmqOk.load, "/", zmqFail.load, " lua=", luaOk.load, "/", luaFail.load,
       " rq=", rqOk.load, "/", rqFail.load
  if zmqFail.load > 0 or luaFail.load > 0 or growth > maxGrowth:
    echo "SOAK FAIL"
    quit 1
  echo "SOAK OK"

main()
