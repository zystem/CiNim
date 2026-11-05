## RUN-007, D-29, DAT-003: the shim's channels to the core over gRPC with mutual TLS (src/common/corechannel.nim, src/core/grpcserve.nim): an answer comes back byte for byte, a core that does not
## answer in time or is not there is "no answer" (as it was with ZeroMQ), the keys decide who may talk, and the address forms are the ones the controller gives.
import std/[os, osproc, strutils]
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

if keys.len > 0: removeDir keys
if other.len > 0: removeDir other
