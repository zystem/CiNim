## The mutual TLS between the core and the key service (docs/hardware-key.md): hsmgate terminates TLS 1.3 itself and wants a client certificate of its CA, and the core trusts exactly
## the CA of the service's certificate. Against the real hsmgate with a software token (HSMGATE_BIN=<path>; skipped without it), certificates made by tests/support/mkcerts.sh
## (needs the openssl command). Built with -d:ssl (thsmgate_tls.nim.cfg).
import std/[unittest, os, osproc, strutils, net, times]
import ../../src/core/[transitclient, kekprovider]
import ../support/connectproxy

const port = 18942
let bin = getEnv("HSMGATE_BIN")
let dir = getTempDir() / "thsmgate-tls"
var server: Process
var ready = false

proc waitPort(): bool =
  let until = epochTime() + 8
  while epochTime() < until:
    try:
      let s = newSocket()
      s.connect("127.0.0.1", Port(port), 300)
      s.close()
      return true
    except CatchableError: sleep 100
  false

func cfgFor(ca, cert, key: string): TransitConfig =
  TransitConfig(url: "https://127.0.0.1:" & $port, keyName: "cinim-shard", ca: ca, cert: cert, key: key, timeoutMs: 3000)

suite "mutual TLS to the key service (hsmgate)":
  test "setup: certificates and the service":
    if bin.len == 0 or not fileExists(bin) or execCmd("openssl version >/dev/null 2>&1") != 0: skip()
    else:
      removeDir dir
      check execCmd("tests/support/mkcerts.sh " & quoteShell(dir)) == 0
      writeFile(dir / "m1.key", "22".repeat(32) & "\n")
      setFilePermissions(dir / "m1.key", {fpUserRead, fpUserWrite})
      writeFile(dir / "hsmgate.yaml", """
listen: 127.0.0.1:""" & $port & """

tls: {cert: """ & dir / "server.crt" & """, key: """ & dir / "server.key" & """, client_ca: """ & dir / "clients-ca.crt" & """}
audit: {file: """ & dir / "audit.log" & """}
tokens:
  - {name: soft, type: soft, keys: {m1: """ & dir / "m1.key" & """}}
keys:
  cinim-shard:
    versions: [{token: soft, label: m1}]
    aad: {mode: context, allow: ["cinim/dek/v1|"]}
clients:
  - name: cinim-core
    identity: {cn: core}
    keys:
      cinim-shard: {ops: [encrypt, decrypt]}
""")
      server = startProcess(bin, args = ["serve", "-config", dir / "hsmgate.yaml"], options = {poStdErrToStdOut, poUsePath})
      ready = waitPort()
      check ready

  test "the core's certificate and the pinned service certificate: it works":
    if not ready: skip()
    else:
      let k = httpKek(cfgFor(dir / "server-ca.crt", dir / "core.crt", dir / "core.key"))
      require k.ok
      var dek = newSeq[byte](32)
      for i in 0 ..< 32: dek[i] = byte(i)
      let w = k.kek.wrap(dek, "cinim/dek/v1|t1")
      check w.ok
      check k.kek.unwrap(w.wrapped, "cinim/dek/v1|t1").plain == dek

  test "a client certificate of a CA that the service does not trust is refused in the handshake":
    if not ready: skip()
    else:
      let k = httpKek(cfgFor(dir / "server-ca.crt", dir / "rogue.crt", dir / "rogue.key"))
      check not k.ok and k.retry                       # no answer: the handshake was refused

  test "a certificate of the right CA with a name that the policy does not know is refused as a client, for good":
    if not ready: skip()
    else:
      let k = httpKek(cfgFor(dir / "server-ca.crt", dir / "stranger.crt", dir / "stranger.key"))
      check not k.ok and not k.retry and "permission denied" in k.error

  test "no client certificate at all is refused":
    if not ready: skip()
    else:
      check not httpKek(cfgFor(dir / "server-ca.crt", "", "")).ok

  test "a service whose certificate is not of the CA the core trusts is refused by the core":
    if not ready: skip()
    else:
      check not httpKek(cfgFor(dir / "rogue-ca.crt", dir / "core.crt", dir / "core.key")).ok

  test "a core that trusts nobody (no CA given) refuses even the right service":
    if not ready: skip()
    else:
      check not httpKek(cfgFor("", dir / "core.crt", dir / "core.key")).ok

  test "through an HTTP proxy (CONNECT), as the cluster reaches the service: the mutual TLS runs from the core to the service, the proxy only carries it":
    if not ready: skip()
    else:
      # HSMGATE_TEST_PROXY=http://host:port runs the same against a real proxy (tinyproxy, with ConnectPort 18942), and skips what only the stand-in can say
      let real = getEnv("HSMGATE_TEST_PROXY")
      if real.len == 0:
        startProxy(port + 10)
        sleep 200
      var cfg = cfgFor(dir / "server-ca.crt", dir / "core.crt", dir / "core.key")
      cfg.proxy = if real.len > 0: real else: "http://127.0.0.1:" & $(port + 10)
      let k = httpKek(cfg)
      require k.ok
      var dek = newSeq[byte](32)
      for i in 0 ..< 32: dek[i] = byte(i + 7)
      let w = k.kek.wrap(dek, "cinim/dek/v1|via-proxy")
      require w.ok
      check k.kek.unwrap(w.wrapped, "cinim/dek/v1|via-proxy").plain == dek
      if real.len == 0:
        check lastRequestLine() == "CONNECT 127.0.0.1:" & $port & " HTTP/1.1"
        check connects >= 3                             # the three calls went through it, none beside it
      # the proxy cannot make the service trust another client: a rogue certificate is refused through it as well
      var rogue = cfgFor(dir / "server-ca.crt", dir / "rogue.crt", dir / "rogue.key")
      rogue.proxy = cfg.proxy
      check not httpKek(rogue).ok
      # a proxy that refuses: the key service is not reached at all
      if real.len == 0:
        setMode(pmRefuse)
        check not httpKek(cfg).ok
        setMode(pmTunnel)
        stopProxy()

  test "teardown":
    if server != nil:
      server.terminate()
      discard server.waitForExit(2000)
      server.close()
