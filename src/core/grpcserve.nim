## The core's side of the shim's channels over gRPC (nim-grpc) with mutual TLS, in place of the ZeroMQ REP + CURVE servers. One server per channel and per port, as before (19742 report, 19743
## log, 19744 artifacts, 19746 state), one method on each, taking the bytes of the same protobuf message and answering with the bytes of the same reply: the handlers (`answerLogBatch` and the
## others) did not change.
##
## What the ZeroMQ REP socket did for free is done here by a lock: one request at a time on a channel, so the state a handler uses (the database connection of the thread, the collector) is
## still touched by one request at a time. nim-grpc runs every call on a worker thread of its own; `maxWorkers` is small because the rest would only wait on the lock.
## The files: `<certs>/tls/core.pem`, `core.key` (the certificate must carry the DNS name `cinim-core`, which the shims check) and `ca.pem` (what the shims' certificate must chain to).
import std/os
import nimgrpc
import ../common/corechannel
export nimgrpc, corechannel

proc toBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toStr*(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

proc startShimServer*(port: int; certs, meth: string; handler: UnaryHandler): GrpcServer =
  ## listening on all addresses; the caller stops it with `stop` when the core ends
  let tls = tlsServerConfig(readFile(certs / "tls" / "core.pem"), readFile(certs / "tls" / "core.key"), clientCaPem = readFile(certs / "tls" / "ca.pem"))
  result = newGrpcServer(port = port, address = "0.0.0.0", maxWorkers = 4, tls = tls)
  result.addUnary(meth, handler)
  result.start()
