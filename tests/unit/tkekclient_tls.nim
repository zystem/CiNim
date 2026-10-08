## The mutual TLS to the key service (core/kekclient.nim, https): the core trusts exactly the key service's certificate, and the key service accepts exactly the core's.
## The emulator (kekd/emulator.nim) speaks plain HTTP; tools/kekd-emu/tls-front.py puts the TLS in front of it the way the real service will have it.
## Needs python3 with `cryptography` and OpenSSL for the client (-d:ssl in tkekclient_tls.nim.cfg); the tests are skipped when python3 is not there.
import std/[unittest, os, osproc, strutils, streams]
import ../../src/core/[kekclient, kekprovider]
import ../../src/kekd/emulator

const
  plainPort = 18795
  tlsPort = 18796
  wrongPort = 18797
let dir = getTempDir() / "kekd-tls-test"
var fronts: seq[Process]
var havePython = false

proc front(port: int; cert, key: string): Process =
  startProcess("python3", args = ["tools/kekd-emu/tls-front.py", "--listen", $port, "--backend", $plainPort, "--cert", dir / cert, "--key", dir / key,
                                  "--client-cert", dir / "core.crt"], options = {poStdErrToStdout, poUsePath})

func cfgFor(port: int; ca, cert, key: string): KekdConfig =
  KekdConfig(url: "https://127.0.0.1:" & $port, ca: ca, cert: cert, key: key, timeoutMs: 3000)

suite "mutual TLS to the key service":
  test "setup: certificates, the emulator, the TLS fronts":
    havePython = execCmd("python3 -c 'import cryptography' 2>/dev/null") == 0
    if not havePython: skip()
    else:
      removeDir(dir)
      check execCmd("python3 tools/kekd-emu/certs.py " & quoteShell(dir) & " >/dev/null") == 0
      startEmulator(plainPort)
      fronts.add front(tlsPort, "server.crt", "server.key")
      fronts.add front(wrongPort, "wrong-server.crt", "wrong-server.key")
      sleep 1500

  test "the core's certificate and the pinned service certificate: it works":
    if not havePython: skip()
    else:
      let k = httpKek(cfgFor(tlsPort, dir / "server.crt", dir / "core.crt", dir / "core.key"))
      check k.ok and k.kek.id.startsWith("kekd:")
      var dek = newSeq[byte](32)
      for i in 0 ..< 32: dek[i] = byte(i)
      let w = k.kek.wrap(dek, "cinim/dek/v1|t1")
      check w.ok
      check k.kek.unwrap(w.wrapped, "cinim/dek/v1|t1").plain == dek

  test "another client certificate (the same name, another key) is refused by the service":
    if not havePython: skip()
    else:
      let k = httpKek(cfgFor(tlsPort, dir / "server.crt", dir / "other.crt", dir / "other.key"))
      check not k.ok and k.retry                       # no answer: the handshake was refused

  test "an expired certificate of the right key is refused":
    if not havePython: skip()
    else:
      check not httpKek(cfgFor(tlsPort, dir / "server.crt", dir / "expired.crt", dir / "expired.key")).ok

  test "no client certificate at all is refused":
    if not havePython: skip()
    else:
      check not httpKek(cfgFor(tlsPort, dir / "server.crt", "", "")).ok

  test "a service that shows another certificate for the same address is refused by the core":
    if not havePython: skip()
    else:
      let k = httpKek(cfgFor(wrongPort, dir / "server.crt", dir / "core.crt", dir / "core.key"))
      check not k.ok

  test "a core that trusts nobody (no CA given) refuses even the right service":
    if not havePython: skip()
    else:
      check not httpKek(cfgFor(tlsPort, "", dir / "core.crt", dir / "core.key")).ok

  test "teardown":
    for p in fronts:
      p.terminate()
      p.close()
    stopEmulator()
