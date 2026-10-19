## The core's client of the key service (core/transitclient.nim) against the real service, hsmgate (github.com/zystem/hsmgate), with a software token: the two speak the same Transit
## dialect, the contexts of the core's data keys are accepted, others are refused, and the service's own words about "may pass" are read right. Skipped when the binary is not
## there: HSMGATE_BIN=<path> (`go build -o ... ./cmd/hsmgate` in the hsmgate repository).
import std/[unittest, os, osproc, strutils, net, times]
import ../../src/core/[transitclient, kekprovider, secretvault]

const port = 18941
let bin = getEnv("HSMGATE_BIN")
let dir = getTempDir() / "thsmgate"
var server: Process

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

func cfgOf(keyName = "cinim-shard"): TransitConfig =
  TransitConfig(url: "http://127.0.0.1:" & $port, keyName: keyName, timeoutMs: 3000)

suite "the real key service (hsmgate), a software token":
  test "setup: the service starts":
    if bin.len == 0 or not fileExists(bin): skip()
    else:
      removeDir dir
      createDir dir
      writeFile(dir / "m1.key", "11".repeat(32) & "\n")
      setFilePermissions(dir / "m1.key", {fpUserRead, fpUserWrite})        # the service refuses a key file that others can read
      writeFile(dir / "hsmgate.yaml", """
listen: 127.0.0.1:""" & $port & """

insecure_loopback_client: cinim-core
audit: {file: """ & dir / "audit.log" & """}
tokens:
  - {name: soft, type: soft, keys: {m1: """ & dir / "m1.key" & """}}
keys:
  cinim-shard:
    versions: [{token: soft, label: m1}]
    aad: {mode: context, allow: ["cinim/dek/v1|", "cinim/kek-check/v1"]}
clients:
  - name: cinim-core
    identity: {cn: cinim-core}
    keys:
      cinim-shard: {ops: [encrypt, decrypt, rewrap]}
""")
      server = startProcess(bin, args = ["serve", "-config", dir / "hsmgate.yaml"], options = {poStdErrToStdOut, poUsePath})
      require waitPort()

  test "the provider names the key, and wraps and unwraps a data key with the contexts of the core":
    if bin.len == 0 or not fileExists(bin): skip()
    else:
      let k = httpKek(cfgOf())
      require k.ok
      check k.kek.id.startsWith("transit:cinim-shard@")
      var dek = newSeq[byte](32)
      for i in 0 ..< 32: dek[i] = byte(i * 5 + 1)
      let w = k.kek.wrap(dek, "cinim/dek/v1|t1")
      check w.ok and w.wrapped.startsWith("vault:v1:")
      let u = k.kek.unwrap(w.wrapped, "cinim/dek/v1|t1")
      check u.ok and u.plain == dek
      # the check text of the vault (secretvault.nim: checkAad) goes through the same door
      let c = k.kek.wrap(@[1'u8, 2, 3], "cinim/kek-check/v1")
      check c.ok and k.kek.unwrap(c.wrapped, "cinim/kek-check/v1").plain == @[1'u8, 2, 3]

  test "a context of another tenant does not open it, and that is final; a context that is not a data key's is refused for good":
    if bin.len == 0 or not fileExists(bin): skip()
    else:
      let made = httpKek(cfgOf())
      require made.ok
      let k = made.kek
      let w = k.wrap(@[9'u8, 9, 9, 9], "cinim/dek/v1|t1")
      let u = k.unwrap(w.wrapped, "cinim/dek/v1|t2")
      check not u.ok and not u.retry
      let notDek = k.wrap(@[9'u8], "something else")
      check not notDek.ok and not notDek.retry and "context" in notDek.error

  test "a key that is not granted is refused for good":
    if bin.len == 0 or not fileExists(bin): skip()
    else:
      let k = httpKek(cfgOf("other"))
      check not k.ok and not k.retry and "permission denied" in k.error

  test "the audit names the client and the context, and holds no key and no ciphertext":
    if bin.len == 0 or not fileExists(bin): skip()
    else:
      sleep 300
      let log = readFile(dir / "audit.log")
      check "cinim-core" in log and "cinim/dek/v1|t1" in log
      check "vault:v1:" notin log

  test "teardown":
    if server != nil:
      server.terminate()
      discard server.waitForExit(2000)
      server.close()
