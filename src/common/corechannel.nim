## The shim's side of its channels to the core over gRPC (nim-grpc) with mutual TLS, in place of the ZeroMQ REQ/REP + CURVE of `zmqcurve.nim`. The shape of the old call is kept so that the
## code of the shim changes little: `dialCore` (lazy, like a ZeroMQ connect: nothing happens until the first request), `exchange` (one request, one answer, `avail` false when the core
## did not answer in time, as `waitForReceive` said), `close`. The messages are the same protobuf bytes, the method is the name of the channel.
##
## Keys: `<certs>/tls/ca.pem` (what the core's certificate must chain to), `<certs>/tls/client.pem` and `client.key` (the shared identity of the shims, as `curve/client.*` was). The core's
## certificate is checked against the fixed name `cinim-core`, not against the address the shim dials, so one certificate serves every namespace. The core needs the CA to check the shims
## and `tls/core.pem`, `tls/core.key` (`tools/grpc/gen_tls.sh` makes the set).
##
## nim-grpc's `dial` connects at once and blocks in `connect(2)` without a deadline (a core behind a rule that drops packets would hold the shim for minutes), so a connect with a deadline
## is made first as a probe. The probe is a second TCP connection made and closed; the cost is one round trip when a channel is made.
import std/[os, net]
import grpc

const
  coreServerName* = "cinim-core"
  logIngestMethod* = "/cicd.LogIngest/Send"
  stepReportMethod* = "/cicd.StepReport/Report"
  statusMethod* = "/cicd.Status/Report"
  artifactMethod* = "/cicd.ArtifactIngest/Call"
  probeTimeoutMs = 5000

type
  CoreChannel* = ref object
    host: string
    port: int
    certs: string
    tls: TlsConfig
    ch: GrpcChannel
    open: bool

proc parseTarget*(address: string): tuple[host: string, port: int] =
  ## `tcp://host:port`, `grpc://host:port` or `host:port`
  var a = address
  for prefix in ["tcp://", "grpc://"]:
    if a.len > prefix.len and a[0 ..< prefix.len] == prefix: a = a[prefix.len .. ^1]
  var i = a.len - 1
  while i >= 0 and a[i] != ':': dec i
  if i < 1 or i == a.len - 1: raise newException(ValueError, "an address of the core is host:port")
  var port = 0
  for ch in a[i + 1 .. ^1]:
    if ch notin {'0' .. '9'}: raise newException(ValueError, "the port of the core is a number")
    port = port * 10 + (ord(ch) - ord('0'))
  if port < 1 or port > 65535: raise newException(ValueError, "the port of the core is 1 to 65535")
  (a[0 ..< i], port)

proc dialCore*(address, certs: string): CoreChannel =
  let (host, port) = parseTarget(address)
  CoreChannel(host: host, port: port, certs: certs)

proc drop(c: CoreChannel) =
  if c.open:
    try: c.ch.close() except CatchableError: discard
    c.open = false

proc close*(c: CoreChannel) = c.drop()

proc loadKeys(c: CoreChannel) =
  if c.tls == nil:
    c.tls = tlsClientConfig(readFile(c.certs / "tls" / "ca.pem"), readFile(c.certs / "tls" / "client.pem"), readFile(c.certs / "tls" / "client.key"))

proc connectNow(c: CoreChannel) =
  var probe = newSocket(buffered = false)
  try: probe.connect(c.host, Port(c.port), probeTimeoutMs)
  finally: probe.close()
  c.ch = dial(c.host, c.port, c.tls, serverName = coreServerName)
  c.open = true

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

proc exchange*(c: CoreChannel; meth, request: string; timeoutMs: int): tuple[avail: bool, body: string] =
  ## One request and its answer. `avail` false: the core did not answer within `timeoutMs` or could not be reached; the channel is dropped and made again by the next call, as a ZeroMQ
  ## connect that finds nobody keeps trying. A key that cannot be read is raised, as it was by `connectReq`.
  if not c.open:
    c.loadKeys()
    try: c.connectNow()
    except CatchableError: return (false, "")
  try:
    let r = c.ch.unaryCall(meth, toBytes(request), timeoutMs = timeoutMs)
    result = (true, toStr(r.message))
  except GrpcError as e:
    c.drop()
    if e.code in {scUnavailable, scDeadlineExceeded, scCancelled}: result = (false, "")
    else: raise
