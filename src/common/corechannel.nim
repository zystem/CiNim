## The shim's side of its channels to the core over gRPC (nim-grpc) with mutual TLS. The shape is that of a ZeroMQ REQ socket, which the shim used before, so that the code of the shim changed little: `dialCore` (lazy: nothing happens until the first request), `exchange` (one request, one answer, `avail` false when the core
## did not answer in time, as `waitForReceive` said), `close`. The messages are the same protobuf bytes, the method is the name of the channel.
##
## Keys: `<certs>/tls/ca.pem` (what the core's certificate must chain to), `<certs>/tls/client.pem` and `client.key` (the shared identity of the shims, as `curve/client.*` was). The core's
## certificate is checked against the fixed name `cinim-core`, not against the address the shim dials, so one certificate serves every namespace. The core needs the CA to check the shims
## and `tls/core.pem`, `tls/core.key` (`tools/grpc/gen_tls.sh` makes the set).
##
## nim-grpc's `dial` connects at once; its `connectTimeoutMs` bounds the TCP connect (a core behind a rule that drops packets would otherwise hold the shim for the system's timeout, minutes).
## Resolving the name is not covered by it.
import std/[os, locks, tables, times]
import nimgrpc

const
  coreServerName* = "cinim-core"
  logIngestMethod* = "/cicd.LogIngest/Send"
  stepReportMethod* = "/cicd.StepReport/Report"
  statusMethod* = "/cicd.Status/Report"
  artifactMethod* = "/cicd.ArtifactIngest/Call"
  connectTimeoutMs = 5000

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

var
  configLock: Lock
  configs {.guard: configLock.}: Table[string, tuple[stamp: string, tls: TlsConfig]]
initLock(configLock)

proc clientKeysStamp*(certs: string): string =
  ## when the client's files were last written and how long they are: it changes when cert-manager (or a person) puts a renewed pair there; a mounted Secret is replaced as a whole, so the time of the
  ## file that the link points to is a new one. "" for a file that is not there.
  for name in ["ca.pem", "client.pem", "client.key"]:
    try:
      let i = getFileInfo(certs / "tls" / name)
      result.add $i.lastWriteTime.toUnix & "." & $i.lastWriteTime.nanosecond & ":" & $i.size & ";"
    except OSError: result.add "-;"

proc clientTls*(certs: string): TlsConfig =
  ## One TlsConfig per directory of keys for the whole process, not one per channel: nim-grpc keeps the TLS session of the last connection in the config and resumes it (for ten minutes) on the
  ## next connection with the same config and server name, which skips the public-key work of the handshake. A channel made for each report or secrets request would otherwise start from scratch.
  ## The keys are `<certs>/tls/{ca.pem,client.pem,client.key}`; an unreadable one is an IOError.
  ## Made again when the files have changed since it was made (`clientKeysStamp`): a process that lives for months and connects again now and then (a controller, a conductor) takes up a renewed pair at
  ## its next connection. A connection that is up keeps what it was made with, which is good until the old certificate ends.
  {.cast(gcsafe).}:
    withLock configLock:
      let stamp = clientKeysStamp(certs)
      if certs notin configs or configs[certs].stamp != stamp:
        configs[certs] = (stamp, tlsClientConfig(readFile(certs / "tls" / "ca.pem"), readFile(certs / "tls" / "client.pem"), readFile(certs / "tls" / "client.key")))
      result = configs[certs].tls

proc serverTls*(certs: string): TlsConfig =
  ## the core's side of the mutual TLS: its certificate, and the CA the clients' certificates must chain to (`<certs>/tls/{core.pem,core.key,ca.pem}`)
  tlsServerConfig(readFile(certs / "tls" / "core.pem"), readFile(certs / "tls" / "core.key"), clientCaPem = readFile(certs / "tls" / "ca.pem"))

proc loadKeys(c: CoreChannel) =
  c.tls = clientTls(c.certs)           # at every connection: the files may have been renewed since the channel was made

proc connectNow(c: CoreChannel) =
  c.ch = dial(c.host, c.port, c.tls, serverName = coreServerName, connectTimeoutMs = connectTimeoutMs)
  c.open = true

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

proc exchange*(c: CoreChannel; meth, request: string; timeoutMs: int): tuple[avail: bool, body: string] =
  ## One request and its answer. `avail` false: the core did not answer within `timeoutMs` or could not be reached; the channel is dropped and made again by the next call. A key that cannot be read is raised, as it was by `connectReq`.
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
