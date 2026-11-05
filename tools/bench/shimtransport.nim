## Measures the shim's channel to the core on a loopback with the code the shim uses: gRPC with mutual TLS (`common/corechannel`, nimgrpc). The server only echoes: what is measured is the
## transport and nothing the core does with a message. (It compared this with ZeroMQ REQ/REP with CURVE, the transport before; the numbers are in docs/shim-grpc.md.)
##
##   shimtransport server grpc PORT KEYS        (stops, and prints its own numbers, on a request "QUIT")
##   shimtransport client grpc PORT KEYS        (the series: first request on a new channel, latency, throughput; then the client's own numbers)
##   shimtransport bulk   grpc PORT KEYS N SIZE (N requests of SIZE bytes on one channel; prints one line, for several clients at once)
##   shimtransport hold   grpc PORT KEYS N SECS (N channels, each used once and kept open for SECS seconds)
##
## KEYS holds tls/* (tools/grpc/gen_tls.sh).
import std/[os, strutils, algorithm, monotimes, times, atomics]
import ../../src/core/grpcserve

var quitting: Atomic[bool]

proc status(): tuple[rssKb, hwmKb, threads: int] =
  for line in lines("/proc/self/status"):
    if line.startsWith("VmRSS:"): result.rssKb = parseInt(line.splitWhitespace[1])
    elif line.startsWith("VmHWM:"): result.hwmKb = parseInt(line.splitWhitespace[1])
    elif line.startsWith("Threads:"): result.threads = parseInt(line.splitWhitespace[1])

proc cpuSeconds(): float =
  ## user + system time of every thread of the process (clock ticks of /proc/self/stat, fields 14 and 15)
  let f = readFile("/proc/self/stat")
  let rest = f[f.rfind(')') + 2 .. ^1].splitWhitespace      # field 3 is rest[0]
  (parseInt(rest[11]) + parseInt(rest[12])).float / 100.0

proc own(label: string) =
  let s = status()
  echo label, " cpu_s=", formatFloat(cpuSeconds(), ffDecimal, 2), " rss_kb=", s.rssKb, " peak_rss_kb=", s.hwmKb, " threads=", s.threads

proc echoHandler(ctx: var ServerContext; req: seq[byte]): seq[byte] {.nimcall, gcsafe, raises: [CatchableError].} =
  if req.len == 4 and toStr(req) == "QUIT": quitting.store(true)
  req

proc serverGrpc(port: int; keys: string) =
  let srv = startShimServer(port, keys, logIngestMethod, echoHandler)
  while not quitting.load: sleep 20
  sleep 100
  own("server_grpc")
  srv.stop()

type Call = proc (msg: string): bool

proc withChannel(kind: string; port: int; keys: string; body: proc (call: Call)) =
  let addr0 = "tcp://127.0.0.1:" & $port
  let c = dialCore(addr0, keys)
  defer: c.close()
  proc call(msg: string): bool =
    let (avail, reply) = c.exchange(logIngestMethod, msg, 10000)
    avail and reply.len == msg.len
  body(call)

proc pct(v: var seq[float]; p: float): float =
  v.sort()
  v[min(v.high, int(p * v.len.float))]

proc ms(d: Duration): float = d.inNanoseconds.float / 1e6

proc firstRequest(kind: string; port: int; keys: string): float =
  var ok = false
  let t0 = getMonoTime()
  proc one(call: Call) = ok = call("x".repeat(256))
  withChannel(kind, port, keys, one)
  if not ok: quit "first request failed"
  (getMonoTime() - t0).ms

proc steady(kind: string; port: int; keys: string) =
  proc run(call: Call) =
    for (size, n) in [(256, 3000), (65536, 1000), (900_000, 200)]:
      let msg = 'x'.repeat(size)
      for i in 0 ..< 20: discard call(msg)
      var lat: seq[float]
      let t0 = getMonoTime()
      for i in 0 ..< n:
        let t1 = getMonoTime()
        if not call(msg): quit "request failed at " & $i
        lat.add (getMonoTime() - t1).ms
      let secs = (getMonoTime() - t0).ms / 1000
      echo "size=", size, " n=", n, " latency_ms median=", formatFloat(pct(lat, 0.5), ffDecimal, 3), " p99=", formatFloat(pct(lat, 0.99), ffDecimal, 3),
           " MB_per_s=", formatFloat(size.float * n.float / 1e6 / secs, ffDecimal, 1)
  withChannel(kind, port, keys, run)

proc series(kind: string; port: int; keys: string) =
  # 1. a new channel and its first request, the cost of what sendStepReport and fetchStepSecrets do each time
  var first: seq[float]
  for i in 0 ..< 40: first.add firstRequest(kind, port, keys)
  echo "first_request_ms median=", formatFloat(pct(first, 0.5), ffDecimal, 2), " p95=", formatFloat(pct(first, 0.95), ffDecimal, 2)
  # 2. latency and throughput on one channel, a request after a request (the shim has one in flight)
  steady(kind, port, keys)
  own("client_" & kind)

proc bulk(kind: string; port: int; keys: string; n, size: int) =
  let msg = 'x'.repeat(size)
  var failed = 0
  let t0 = getMonoTime()
  proc run(call: Call) =
    for i in 0 ..< n:
      if not call(msg): inc failed
  withChannel(kind, port, keys, run)
  echo "bulk n=", n, " size=", size, " failed=", failed, " secs=", formatFloat((getMonoTime() - t0).ms / 1000, ffDecimal, 2)

proc hold(kind: string; port: int; keys: string; n, secs: int) =
  ## n channels, each used once, then kept open for `secs` seconds: what a core carries when n shims are connected
  let addr0 = "tcp://127.0.0.1:" & $port
  var chans: seq[CoreChannel]
  var failed = 0
  for i in 0 ..< n:
    let c = dialCore(addr0, keys)
    if not c.exchange(logIngestMethod, "x".repeat(256), 20000).avail: inc failed
    chans.add c
  echo "held n=", n, " failed=", failed
  sleep secs * 1000
  own("holder_" & kind)

let a = commandLineParams()
if a.len < 4: quit "usage: shimtransport server|client|bulk|hold grpc PORT KEYS [N SIZE]"
case a[0]
of "server":
  serverGrpc(parseInt(a[2]), a[3])
of "client":
  series(a[1], parseInt(a[2]), a[3])
  proc quitCall(call: Call) = discard call("QUIT")
  withChannel(a[1], parseInt(a[2]), a[3], quitCall)
of "bulk": bulk(a[1], parseInt(a[2]), a[3], parseInt(a[4]), parseInt(a[5]))
of "hold": hold(a[1], parseInt(a[2]), a[3], parseInt(a[4]), parseInt(a[5]))
else: quit "unknown mode"
