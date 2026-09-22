## Spike 6: soak harness (NFR-013). One process, worker threads under steady load:
##   nng    mTLS REQ/REP with Protobuf, half of the requests on fresh connections
##   lua    sandbox create, journaled run, "kill" and replay, destroy
##   rqlite optional (SOAK_RQLITE_URL): CAS updates and reads
## The main thread samples RSS and Nim heap into a CSV and, at the end, checks RSS growth
## after warm-up against SOAK_MAX_GROWTH_PCT (NFR-013: 2%).
## Build: nim c -d:release -d:nngPrefix=$NNG_PREFIX tools/soak/soak.nim  (add -d:sanitize + asan flags for LSan)
import std/[os, strutils, atomics, times, options, json]
import protobuf_serialization
import protobuf_serialization/files/type_generator
import common/[nngbind, memstats, rqlite]
import executor/[sandbox, journal, replay]
import ../../tests/unit/support/fixture

import_proto3 "../../proto/m0.proto"

let port = parseInt(getEnv("SOAK_PORT", "19700"))
let certs = getEnv("SOAK_CERTS", getCurrentDir() / "tests" / "certs")
var stop: Atomic[bool]
var serverReady: Atomic[bool]
var nngOk, nngFail, luaOk, luaFail, rqOk, rqFail: Atomic[int]

proc pem(name: string): string = readFile(certs / name)

proc tlsConfig(server: bool; cert, ca: string; hostname = ""): ptr nng_tls_config =
  var c: ptr nng_tls_config
  doAssert nng_tls_config_alloc(addr c, if server: NNG_TLS_MODE_SERVER else: NNG_TLS_MODE_CLIENT) == 0
  doAssert nng_tls_config_ca_chain(c, pem(ca).cstring, nil) == 0
  if cert.len > 0:
    doAssert nng_tls_config_own_cert(c, pem(cert & ".pem").cstring, pem(cert & ".key").cstring, nil) == 0
  doAssert nng_tls_config_auth_mode(c, NNG_TLS_AUTH_MODE_REQUIRED) == 0
  if hostname.len > 0: doAssert nng_tls_config_server_name(c, hostname.cstring) == 0
  c

type Sock = object
  s: nng_socket
proc `=destroy`(x: Sock) = discard nng_close(x.s)
proc `=copy`(a: var Sock; b: Sock) {.error.}

proc serverLoop() {.thread.} =
  var rep: Sock
  doAssert nng_rep0_open(addr rep.s) == 0
  doAssert nng_socket_set_size(rep.s, NNG_OPT_RECVMAXSZ, 4096) == 0
  doAssert nng_socket_set_ms(rep.s, NNG_OPT_RECVTIMEO, 200) == 0
  var l: nng_listener
  doAssert nng_listener_create(addr l, rep.s, cstring("tls+tcp://127.0.0.1:" & $port)) == 0
  var cfg: ptr nng_tls_config
  {.cast(gcsafe).}: cfg = tlsConfig(true, "server", "ca.pem")
  doAssert nng_listener_set_ptr(l, NNG_OPT_TLS_CONFIG, cfg) == 0
  nng_tls_config_free(cfg)
  doAssert nng_listener_start(l, 0) == 0
  serverReady.store(true)
  while not stop.load:
    var msg: ptr nng_msg
    if nng_recvmsg(rep.s, addr msg, 0) != 0: continue
    var body = newString(nng_msg_len(msg))
    if body.len > 0: copyMem(addr body[0], nng_msg_body(msg), body.len)
    nng_msg_free(msg)
    var reply = body
    if body.startsWith("pb:"):
      let m = Protobuf.decode(cast[seq[byte]](body[3 .. ^1]), Inner)
      let enc = Protobuf.encode(Inner(name: m.name, n: m.n + 1))
      reply = "pb:"
      for b in enc: reply.add char(b)
    discard nng_send(rep.s, reply.cstring, reply.len.csize_t, 0)

proc dial(sock: var Sock): bool =
  doAssert nng_req0_open(addr sock.s) == 0
  discard nng_socket_set_ms(sock.s, NNG_OPT_RECVTIMEO, 5000)
  discard nng_socket_set_ms(sock.s, NNG_OPT_SENDTIMEO, 5000)
  var d: nng_dialer
  let rc = nng_dialer_create(addr d, sock.s, cstring("tls+tcp://localhost:" & $port))
  if rc != 0: (stderr.writeLine "dialer_create " & $rc; return false)
  let cfg = tlsConfig(false, "client", "ca.pem", "localhost")
  discard nng_dialer_set_ptr(d, NNG_OPT_TLS_CONFIG, cfg)
  nng_tls_config_free(cfg)
  let rs = nng_dialer_start(d, 0)
  if rs != 0: stderr.writeLine "dialer_start " & $rs & " " & $nng_strerror(rs)
  rs == 0

proc roundTrip(s: nng_socket; n: int): bool =
  let enc = Protobuf.encode(Inner(name: "step-" & $n, n: int32(n mod 1000)))
  var msg = "pb:"
  for b in enc: msg.add char(b)
  if nng_send(s, msg.cstring, msg.len.csize_t, 0) != 0: return false
  var buf: pointer
  var sz: csize_t
  if nng_recv(s, cast[pointer](addr buf), addr sz, NNG_FLAG_ALLOC.cint) != 0: return false
  var body = newString(sz)
  if sz > 0: copyMem(addr body[0], buf, sz)
  nng_free(buf, sz)
  if not body.startsWith("pb:"): return false
  Protobuf.decode(cast[seq[byte]](body[3 .. ^1]), Inner).n == int32(n mod 1000) + 1

proc nngClientBody(churn: bool)

proc nngClient(churn: bool) {.thread.} =
  {.cast(gcsafe).}: nngClientBody(churn)

proc nngClientBody(churn: bool) =
  while not serverReady.load: sleep 20
  var n = 0
  if churn:
    while not stop.load:      # a fresh connection per request
      var s: Sock
      if s.dial() and roundTrip(s.s, n): nngOk.atomicInc
      elif not stop.load: nngFail.atomicInc
      inc n
      sleep 5
  else:
    var s: Sock
    while not s.dial():
      if stop.load: return
      sleep 500
    while not stop.load:      # one long connection
      if roundTrip(s.s, n): nngOk.atomicInc
      elif not stop.load: nngFail.atomicInc
      inc n
      sleep 2

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
      let counting: HostCall = proc(seq: int; kind, payload: string): Option[string] =
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

proc main() =
  let seconds = parseInt(getEnv("SOAK_SECONDS", "60"))
  let sampleEvery = parseInt(getEnv("SOAK_SAMPLE_SECONDS", "10"))
  let warmup = parseInt(getEnv("SOAK_WARMUP_SECONDS", $max(seconds div 10, 5)))
  let maxGrowth = parseFloat(getEnv("SOAK_MAX_GROWTH_PCT", "2"))
  let csv = getEnv("SOAK_CSV", "soak.csv")
  let rq = getEnv("SOAK_RQLITE_URL")
  var srv: Thread[void]
  var clients: array[8, Thread[bool]]
  var lw: Thread[void]
  var rw: Thread[string]
  createThread(srv, serverLoop)
  var nc = 0
  for ch in getEnv("SOAK_NNG", "ccp"):
    createThread(clients[nc], nngClient, ch == 'c')
    inc nc
    sleep 300
  let luaOn = getEnv("SOAK_LUA", "1") == "1"
  if luaOn: createThread(lw, luaWorker)
  if rq.len > 0: createThread(rw, rqWorker, rq)
  let f = open(csv, fmWrite)
  f.writeLine "t,rss,nim_occupied,nng_ok,nng_fail,lua_ok,lua_fail,rq_ok,rq_fail"
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
    f.writeLine [$t, $lastRss, $getOccupiedMem(), $nngOk.load, $nngFail.load, $luaOk.load,
                 $luaFail.load, $rqOk.load, $rqFail.load].join(",")
    f.flushFile()
  stop.store(true)
  joinThread(srv)
  for i in 0 ..< nc: joinThread(clients[i])
  if luaOn: joinThread(lw)
  if rq.len > 0: joinThread(rw)
  f.close()
  let growth = if warmRss > 0: (lastRss - warmRss).float * 100 / warmRss.float else: 0.0
  echo "SOAK warm_rss=", warmRss, " last_rss=", lastRss, " max_rss=", maxRss,
       " growth_pct=", formatFloat(growth, ffDecimal, 2),
       " nng=", nngOk.load, "/", nngFail.load, " lua=", luaOk.load, "/", luaFail.load,
       " rq=", rqOk.load, "/", rqFail.load
  if nngFail.load > 0 or luaFail.load > 0 or growth > maxGrowth:
    echo "SOAK FAIL"
    quit 1
  echo "SOAK OK"

main()
