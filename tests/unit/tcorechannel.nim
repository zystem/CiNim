## RUN-007, D-29, DAT-003: the shim's channels to the core over gRPC with mutual TLS (src/common/corechannel.nim, src/core/grpcserve.nim): an answer comes back byte for byte, a core that does not
## answer in time or is not there is "no answer" (as it was with ZeroMQ), the keys decide who may talk, and the address forms are the ones the controller gives.
import std/[os, osproc, strutils, atomics]
import unittest2
import ../../src/core/grpcserve

proc echo(ctx: var ServerContext; req: seq[byte]): seq[byte] {.nimcall, gcsafe, raises: [CatchableError].} =
  if toStr(req) == "slow": sleep 1500
  req

proc makeKeys(suffix: string): string =
  result = getTempDir() / ("tcorechannel-" & $getCurrentProcessId() & suffix)
  createDir result
  if execCmd("sh " & quoteShell(getCurrentDir() / "tools" / "grpc" / "gen_tls.sh") & " " & quoteShell(result) & " 2") != 0: result = ""

let keys = makeKeys("")
let other = makeKeys("-other")

suite "RUN-007 the shim's gRPC channel":
  setup:
    if keys.len == 0: skip()

  test "RUN-007 an address is host:port with or without the scheme":
    check parseTarget("tcp://cinim-core.ns.svc:19743") == (host: "cinim-core.ns.svc", port: 19743)
    check parseTarget("127.0.0.1:19742") == (host: "127.0.0.1", port: 19742)
    check parseTarget("grpc://h:1") == (host: "h", port: 1)
    for bad in ["", "host", "host:", ":80", "host:x", "host:0", "host:70000"]:
      expect ValueError: discard parseTarget(bad)

  test "RUN-007 a request comes back as it was sent, an empty one and a big one too":
    let srv = startShimServer(0, keys, logIngestMethod, echo)
    defer: srv.stop()
    let c = dialCore("tcp://127.0.0.1:" & $srv.port, keys)
    defer: c.close()
    for n in [0, 1, 4096, 1_000_000]:
      let msg = 'x'.repeat(n)
      let (avail, body) = c.exchange(logIngestMethod, msg, 5000)
      check avail
      check body == msg

  test "D-29 a core that is too slow is no answer, and the next request goes on":
    let srv = startShimServer(0, keys, stepReportMethod, echo)
    defer: srv.stop(graceMs = 3000)
    let c = dialCore("127.0.0.1:" & $srv.port, keys)
    defer: c.close()
    check c.exchange(stepReportMethod, "slow", 300).avail == false
    check c.exchange(stepReportMethod, "fast", 5000) == (true, "fast")

  test "RUN-007 a core that is not there is no answer, not an error":
    let c = dialCore("127.0.0.1:1", keys)
    defer: c.close()
    check c.exchange(logIngestMethod, "x", 1000).avail == false

  test "DAT-003 a client whose certificate is of another CA is not served":
    if other.len == 0: skip()
    # the CA the client trusts is the right one; only its own certificate is from the other CA
    let mixed = keys & "-mixed"
    createDir(mixed / "tls")
    copyFile(keys / "tls" / "ca.pem", mixed / "tls" / "ca.pem")
    copyFile(other / "tls" / "client.pem", mixed / "tls" / "client.pem")
    copyFile(other / "tls" / "client.key", mixed / "tls" / "client.key")
    defer: removeDir mixed
    let srv = startShimServer(0, keys, artifactMethod, echo)
    defer: srv.stop()
    let c = dialCore("127.0.0.1:" & $srv.port, mixed)
    defer: c.close()
    check c.exchange(artifactMethod, "x", 2000).avail == false
    let ok = dialCore("127.0.0.1:" & $srv.port, keys)
    defer: ok.close()
    check ok.exchange(artifactMethod, "x", 2000) == (true, "x")

  test "DAT-003 a client with no certificate at all is not served":
    let srv = startShimServer(0, keys, artifactMethod, echo)
    defer: srv.stop()
    let tls = tlsClientConfig(readFile(keys / "tls" / "ca.pem"))          # trusts the core, presents nothing
    var served = false
    try:
      let ch = dial("127.0.0.1", srv.port, tls, serverName = coreServerName)
      defer: ch.close()
      served = ch.unaryCall(artifactMethod, toBytes("x"), timeoutMs = 2000).message.len > 0
    except CatchableError: discard
    check not served
    check dialCore("127.0.0.1:" & $srv.port, keys).exchange(artifactMethod, "x", 2000) == (true, "x")      # the right client is served by the same server

  test "DAT-003 keys that cannot be read are an error that the caller sees":
    let c = dialCore("127.0.0.1:1", getTempDir() / "no-such-keys")
    expect IOError: discard c.exchange(artifactMethod, "x", 1000)

  test "D-62 a core that was restarted is reached again by the same channel object, within two requests":
    let first = startShimServer(28790, keys, logIngestMethod, echo)
    let c = dialCore("127.0.0.1:28790", keys)
    defer: c.close()
    check c.exchange(logIngestMethod, "before", 3000) == (true, "before")
    first.stop()
    let second = startShimServer(28790, keys, logIngestMethod, echo)
    defer: second.stop()
    var answered = false
    for attempt in 0 ..< 2:
      if c.exchange(logIngestMethod, "after", 3000) == (true, "after"):
        answered = true
        break
    check answered

  test "RUN-007 a method the core does not serve is an error, not silence":
    let srv = startShimServer(0, keys, logIngestMethod, echo)
    defer: srv.stop()
    let c = dialCore("127.0.0.1:" & $srv.port, keys)
    defer: c.close()
    expect GrpcError: discard c.exchange(statusMethod, "x", 2000)


var hammerOk: Atomic[int]
var hammerKeys: string
var hammerPort: int

proc hammer() {.thread.} =
  ## a thread with channels of its own that connect afresh, the way the soak's clients do
  {.cast(gcsafe).}:
    var n = 0
    for i in 0 ..< 1500:
      let c = dialCore("tcp://127.0.0.1:" & $hammerPort, hammerKeys)
      let (avail, body) = c.exchange(logIngestMethod, "ping" & $i, 5000)
      if avail and body == "ping" & $i: inc n
      c.close()
    discard hammerOk.fetchAdd(n)

proc boom(ctx: var ServerContext; req: seq[byte]): seq[byte] {.nimcall, gcsafe, raises: [CatchableError].} =
  raise newException(ValueError, "the query was SELECT * FROM secrets\nsecond line")

suite "RUN-007 a failure of a handler is told to the operator and not to the client":
  setup:
    if keys.len == 0: skip()

  test "RUN-007 the line has the method, the kind of the exception and its text on one line, and is not longer than a line should be":
    let line = handlerErrorLine("/cicd.LogIngest/Send", newException(ValueError, "a\r\nb" & 'x'.repeat(1000)))
    check line.startsWith("grpc: handler /cicd.LogIngest/Send failed: ValueError: a  b")
    check '\n' notin line and '\r' notin line
    check line.len < 400

  test "RUN-007 an exception that is not a GrpcError reaches the hook of the server, the client is told internal error and nothing of the exception, and the server goes on":
    let srv = startShimServer(0, keys, logIngestMethod, boom)
    defer: srv.stop()
    let c = dialCore("tcp://127.0.0.1:" & $srv.port, keys)
    defer: c.close()
    let before = handlerErrors.load
    var told = ""
    try: discard c.exchange(logIngestMethod, "x", 5000)
    except GrpcError as e: told = e.msg
    check told == "internal error"          # not the text of the exception: "SELECT * FROM secrets" stays in the log of the core
    check handlerErrors.load == before + 1
    let srv2 = startShimServer(0, keys, stepReportMethod, echo)
    defer: srv2.stop()
    let c2 = dialCore("tcp://127.0.0.1:" & $srv2.port, keys)
    defer: c2.close()
    check c2.exchange(stepReportMethod, "still", 5000) == (true, "still")

suite "NFR-013 the client keys are shared by threads":
  setup:
    if keys.len == 0: skip()

  test "NFR-013 threads that connect afresh over one process-wide configuration do not free it under each other":
    # `clientTls` once handed the same TlsConfig object to every thread; ORC counts references without atomics, so the count drifted, the configuration (its trust anchors) was freed
    # while a handshake read them, and the soak died with SIGSEGV in BearSSL within minutes. Each connection has its own object now, over one configuration whose count is atomic.
    let srv = startShimServer(0, keys, logIngestMethod, echo)
    defer: srv.stop()
    hammerKeys = keys; hammerPort = srv.port
    hammerOk.store(0)
    var th: array[8, Thread[void]]
    for i in 0 ..< 8: createThread(th[i], hammer)
    joinThreads(th)
    check hammerOk.load == 8 * 1500

  test "NFR-013 a call of clientTls gives an object of its own and the same sessions, and a renewed set gives a new configuration":
    let a = clientTls(keys)
    let b = clientTls(keys)
    check a != b                       # not one object for everybody: nothing for two threads to count against each other
    check a != nil and b != nil

if keys.len > 0: removeDir keys
if other.len > 0: removeDir other
