## A port that something already listens on belongs to another process: a leftover of an earlier run, a scratch server, a forgotten helper. A test that starts its own server on it either gets
## "address in use" that nobody looks at (`discard server.start(...)`) or binds beside the old one, and is answered by the old one, whose state and schema are those of another day. Such a test
## fails or passes for no reason of its own, and it costs hours to find. So every test that starts something on a port it chose asks first, and stops with the port named.
import std/[net, nativesockets]

proc portIsFree*(port: int; udp = false): bool =
  ## whether this machine can bind the port now (an address in TIME_WAIT is free, as for a server that restarts; a listener is not)
  let s = if udp: newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP) else: newSocket()
  try:
    s.setSockOpt(OptReuseAddr, true)
    s.bindAddr(Port(port), "127.0.0.1")
    result = true
  except OSError:
    result = false
  finally:
    s.close()

proc requireFreePort*(port: int; what: string; udp = false) =
  ## stops the test binary, with the port and the way to find what holds it, when the port is in use
  if not portIsFree(port, udp):
    echo "  [FAILED] ", what, ": the port ", port, (if udp: "/udp" else: "/tcp"), " is in use (an earlier run, a scratch server, a forgotten process): the test would talk to that instead of its own; ss -ltnup | grep ", port
    quit 1

proc requireFreePorts*(what: string; ports: openArray[int]; udp = false) =
  for p in ports: requireFreePort(p, what, udp)
