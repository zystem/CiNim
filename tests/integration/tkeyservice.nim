## D-64: the secrets store of the core starts and works with its master key in a key service (hsmgate, a software token): the path of production, `vaultsetup.tryActivate` with the
## settings in the environment (CINIM_KEYSERVICE_*), the check text of the vault, the data key of a tenant, a secret put and read, and a database that was sealed by another key refused for
## good. Needs CINIM_RQLITE_URL and HSMGATE_BIN=<path of the hsmgate binary> (skipped without either).
import std/[unittest, os, osproc, strutils, net, times, json]
import common/rqlite
import core/[schema, vaultsetup, secretvault]

let url = getEnv("CINIM_RQLITE_URL")
let bin = getEnv("HSMGATE_BIN")
const port = 18943
let dir = getTempDir() / "tkeyservice"
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

proc startService(keyHex: string): bool =
  writeFile(dir / "m1.key", keyHex & "\n")
  setFilePermissions(dir / "m1.key", {fpUserRead, fpUserWrite})
  server = startProcess(bin, args = ["serve", "-config", dir / "hsmgate.yaml"], options = {poStdErrToStdOut, poUsePath})
  waitPort()

proc stopService() =
  if server != nil:
    server.terminate()
    discard server.waitForExit(2000)
    server.close()
    server = nil

let ready = url.len > 0 and bin.len > 0 and fileExists(bin)

suite "the secrets store with its master key in a key service (D-64)":
  test "setup":
    if not ready: skip()
    else:
      removeDir dir
      createDir dir
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
      var c = newRq(url)
      migrate(c)
      discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'kek_check'"], ["DELETE FROM org_keys WHERE tenant_id = 'acme-ks'"]])
      setDekCacheSeconds(0.0)                          # every call goes to the service: nothing is remembered from an earlier one
      putEnv("CINIM_KEYSERVICE_URL", "http://127.0.0.1:" & $port)
      putEnv("CINIM_KEYSERVICE_KEY_NAME", "cinim-shard")
      check startService("33".repeat(32))

  test "the store starts: the check text is sealed through the service, and a secret is put and read back for a tenant":
    if not ready: skip()
    else:
      let r = tryActivate(url, "unused-certs")
      check r.ready
      let k = vaultKek()
      check k.ready and k.kek.id.startsWith("transit:cinim-shard@")
      var c = newRq(url)
      let p = putSecret(c, k.kek, "acme-ks", "TOKEN", "hunter2-from-the-card", 1)
      check p.ok
      let g = getSecrets(c, k.kek, "acme-ks", @["TOKEN"])
      check g.ok and g.values == @[("TOKEN", "hunter2-from-the-card")]

  test "the service restarted with the same key: the same database opens (the key's identity is the key, not the process)":
    if not ready: skip()
    else:
      stopService()
      check startService("33".repeat(32))
      check tryActivate(url, "unused-certs").ready
      var c = newRq(url)
      check getSecrets(c, vaultKek().kek, "acme-ks", @["TOKEN"]).values == @[("TOKEN", "hunter2-from-the-card")]

  test "a service with another key than the one that sealed this database is refused for good, with the reason":
    if not ready: skip()
    else:
      stopService()
      check startService("44".repeat(32))
      let r = tryActivate(url, "unused-certs")
      check not r.ready and not r.retry and "is not the one that sealed" in r.error

  test "no service at all: the store waits (may pass), it does not give up":
    if not ready: skip()
    else:
      stopService()
      let r = tryActivate(url, "unused-certs")
      check not r.ready and r.retry

  test "teardown":
    stopService()
    if ready:
      var c = newRq(url)
      discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'kek_check'"], ["DELETE FROM org_keys WHERE tenant_id = 'acme-ks'"], ["DELETE FROM step_secrets WHERE tenant_id = 'acme-ks'"]])
    delEnv("CINIM_KEYSERVICE_URL")
    delEnv("CINIM_KEYSERVICE_KEY_NAME")
