## CURVE-secured ZeroMQ REQ/REP helpers on top of the `zmq` package (the zystem/nim-zmq fork, branch `cinim`, see cinim.nimble;
## D-24). Keys are Z85 text files from tools/zmq/gen_curve_keys.sh: certs/curve/core.{pub,key} is
## the REP server identity (ControllerAttach, ExecutorChannel, LogIngest, StepReport); certs/curve/client.{pub,key} is the shared
## identity of the clients (job-controller, executor-service, shim). Clients load only the server's *public* key.
##
## The zmq package loads libzmq with dlopen at run time, so building needs nothing beyond the nimble dependency; running needs a
## libzmq.so with CURVE on the loader path (tools/zmq/build_deps.sh, or the distro package) - or a static build
## (tools/shim/build_static.sh) that links it in.
import std/[os, strutils]
import zmq
export zmq

type CurveKeypair* = tuple[publicKey, secretKey: string]

proc loadKeypair*(certs, name: string): CurveKeypair =
  (readFile(certs / "curve" / name & ".pub").strip, readFile(certs / "curve" / name & ".key").strip)

proc loadPublicKey*(certs, name: string): string =
  ## Clients only ever need the *server's* public key (CURVE_SERVERKEY) - never its secret key, which
  ## must not leave the core host (and is deliberately not mounted into step Pods).
  readFile(certs / "curve" / name & ".pub").strip

proc listenRep*(port: int; secretKey: string; recvTimeoutMs = 200): ZConnection =
  doAssert hasCurve(), "libzmq was not built with CURVE (libsodium) support"
  result = listen("tcp://0.0.0.0:" & $port, REP) do (s: ZSocket) -> void:
    s.setCurveServer(secretKey)
  result.socket.setsockopt(RCVTIMEO, recvTimeoutMs.cint)

proc connectReq*(address, serverPublicKey: string; client: CurveKeypair;
                  recvTimeoutMs, sendTimeoutMs: int): ZConnection =
  doAssert hasCurve(), "libzmq was not built with CURVE (libsodium) support"
  result = connect(address, REQ) do (s: ZSocket) -> void:
    s.setCurveClient(serverPublicKey, client.publicKey, client.secretKey)
    # A strict REQ that timed out waiting for a reply is stuck (EFSM on the next send). RELAXED lets the
    # caller simply send again; CORRELATE makes the late reply of the abandoned request be dropped instead
    # of being mistaken for the new one. Needs nim-zmq#58: a bare `1` used to be rejected with EINVAL.
    s.setsockopt(REQ_RELAXED, 1)
    s.setsockopt(REQ_CORRELATE, 1)
  result.socket.setsockopt(RCVTIMEO, recvTimeoutMs.cint)
  result.socket.setsockopt(SNDTIMEO, sendTimeoutMs.cint)
