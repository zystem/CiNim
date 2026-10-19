## The core's client of the key service (core/transitclient.nim) against a stand-in for a Transit service (tests/support/transitemu.nim): what the core asks, how it reads
## the answers, and what it takes for "may pass" and "final". The real service is tried by thsmgate.nim.
import std/[unittest, os, strutils]
import ../../src/core/[transitclient, kekprovider, secretvault]
import ../../src/common/sodiumaead
import ../support/transitemu

const port = 18791
let cfg = TransitConfig(url: "http://127.0.0.1:" & $port, keyName: "cinim-shard", timeoutMs: 1500)

proc key(b: byte): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 32: result[i] = b

suite "a key on another machine (Transit)":
  test "setup: the stand-in starts":
    startEmulator(port, key(0x21))
    sleep 300
    check transitInfo(cfg).ok

  test "the provider names the key by the service's name and fingerprint, and wraps and unwraps a data key":
    let k = httpKek(cfg)
    check k.ok and k.kek.id.startsWith("transit:cinim-shard@") and k.kek.id.len > 25
    let dek = key(0x77)
    let w = k.kek.wrap(dek, "cinim/dek/v1|t1")
    check w.ok and w.wrapped.startsWith("vault:v1:") and "7777" notin w.wrapped
    let u = k.kek.unwrap(w.wrapped, "cinim/dek/v1|t1")
    check u.ok and u.plain == dek
  test "a data key wrapped for one place does not open for another (the context is the additional data), and that is final":
    let k = httpKek(cfg).kek
    let w = k.wrap(key(0x55), "cinim/dek/v1|t1")
    let u = k.unwrap(w.wrapped, "cinim/dek/v1|t2")
    check not u.ok and not u.retry
  test "the vault's own checks work through the provider (a data key wrapped for a tenant, a secret sealed with it)":
    let k = httpKek(cfg).kek
    let dek = randomBytes(32)
    let w = k.wrap(dek, "cinim/dek/v1|t9")
    let opened = k.unwrap(w.wrapped, "cinim/dek/v1|t9")
    check opened.ok
    let sealed = seal(opened.plain, "hunter2-secret-value", "cinim/secret/v1|t9|A|1")
    check unseal(dek, sealed, "cinim/secret/v1|t9|A|1").plain == "hunter2-secret-value"

  test "the service says the token is locked, or busy: the answer is a failure that may pass":
    let k = httpKek(cfg).kek
    let w = k.wrap(key(0x31), "a")
    setFault(fLocked)
    let u = k.unwrap(w.wrapped, "a")
    check not u.ok and u.retry and "locked" in u.error
    setFault(fThrottle)
    check k.unwrap(w.wrapped, "a").retry
    setFault(fDown)
    check k.wrap(key(0x31), "a").retry and not k.wrap(key(0x31), "a").ok
    setFault(fNone)
    check k.unwrap(w.wrapped, "a").ok                 # it passed
  test "a service that does not say whether a failure may pass (Vault, OpenBao): 5xx and 429 may pass, the other 4xx are final":
    let k = httpKek(cfg).kek
    let w = k.wrap(key(0x33), "a")
    setRetryHeader(false)
    setFault(fDown)
    check k.unwrap(w.wrapped, "a").retry
    setFault(fThrottle)
    check k.unwrap(w.wrapped, "a").retry
    setFault(fNone)
    let bad = k.unwrap(w.wrapped, "another context")
    check not bad.ok and not bad.retry                # 400
    setRetryHeader(true)

  test "a slow service is waited for up to the timeout, then it is a failure that may pass":
    let k = httpKek(cfg).kek
    let w = k.wrap(key(0x32), "a")
    setFault(fSlow, 400)
    check k.unwrap(w.wrapped, "a").ok
    setFault(fSlow, 3000)
    let u = k.unwrap(w.wrapped, "a")
    check not u.ok and u.retry
    setFault(fNone)

  test "another card put in: what the old one wrapped is refused for good, and the key's fingerprint differs":
    let before = httpKek(cfg)
    let w = before.kek.wrap(key(0x41), "a")
    let idBefore = before.kek.id
    newRandomKey()
    let after = httpKek(cfg)
    check after.ok and after.kek.id != idBefore
    let u = after.kek.unwrap(w.wrapped, "a")
    check not u.ok and not u.retry and "cannot be opened" in u.error

  test "a key name the service does not grant or know is refused for good (a setting to correct, not a reason to wait)":
    let nobody = TransitConfig(url: cfg.url, keyName: "nope", timeoutMs: 1500)
    let k = httpKek(nobody)
    check not k.ok and not k.retry and "permission denied" in k.error

  test "a token file is sent as X-Vault-Token (for a Vault or an OpenBao; hsmgate ignores it)":
    let f = getTempDir() / "ttransitclient.token"
    writeFile(f, "s.the-token\n")
    let k = httpKek(TransitConfig(url: cfg.url, keyName: "cinim-shard", tokenFile: f, timeoutMs: 1500))
    check k.ok and tokenSeen == "s.the-token"
    removeFile f
    discard httpKek(cfg)
    check tokenSeen == ""

  test "the mount and the name are in the path":
    setKeyNames(@["other-key"])
    let k = httpKek(TransitConfig(url: cfg.url, keyName: "other-key", timeoutMs: 1500))
    check k.ok and k.kek.id.startsWith("transit:other-key@")
    setKeyNames(@["cinim-shard"])

  test "a service that is not there: the provider cannot even be made, and the failure may pass":
    let nobody = TransitConfig(url: "http://127.0.0.1:1", keyName: "cinim-shard", timeoutMs: 500)
    let k = httpKek(nobody)
    check not k.ok and k.retry

  test "teardown":
    stopEmulator()
