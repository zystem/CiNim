## The client of the key service (core/kekclient.nim) against the emulator (kekd/emulator.nim): the same protocol the service next to the card will speak.
import std/[unittest, os, strutils]
import ../../src/core/[kekclient, kekprovider, secretvault]
import ../../src/common/sodiumaead
import ../../src/kekd/emulator

const port = 18791
let cfg = KekdConfig(url: "http://127.0.0.1:" & $port, timeoutMs: 1500)

proc key(b: byte): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 32: result[i] = b

suite "a key on another machine":
  test "setup: the emulator starts":
    startEmulator(port, key(0x21))
    sleep 300
    check kekdInfo(cfg).ok

  test "the provider names the key by the service's fingerprint, and wraps and unwraps a data key":
    let k = httpKek(cfg)
    check k.ok and k.kek.id.startsWith("kekd:") and k.kek.id.len > 10
    let dek = key(0x77)
    let w = k.kek.wrap(dek, "cinim/dek/v1|t1")
    check w.ok and w.wrapped.startsWith("emu1.") and "7777" notin w.wrapped
    let u = k.kek.unwrap(w.wrapped, "cinim/dek/v1|t1")
    check u.ok and u.plain == dek
  test "a data key wrapped for one place does not open for another":
    let k = httpKek(cfg).kek
    let w = k.wrap(key(0x55), "cinim/dek/v1|t1")
    let u = k.unwrap(w.wrapped, "cinim/dek/v1|t2")
    check not u.ok and not u.retry               # damaged: final
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

  test "a slow service is waited for up to the timeout, then it is a failure that may pass":
    let k = httpKek(cfg).kek
    let w = k.wrap(key(0x32), "a")
    setFault(fSlow, 400)
    check k.unwrap(w.wrapped, "a").ok
    setFault(fSlow, 3000)
    let u = k.unwrap(w.wrapped, "a")
    check not u.ok and u.retry
    setFault(fNone)

  test "another card put in: what the old one wrapped is refused for good, and the new key id differs":
    let before = httpKek(cfg)
    let w = before.kek.wrap(key(0x41), "a")
    discard before                                  # the service is rekeyed below
    let idBefore = before.kek.id
    emulator.newRandomKey()
    let after = httpKek(cfg)
    check after.ok and after.kek.id != idBefore
    let u = after.kek.unwrap(w.wrapped, "a")
    check not u.ok and not u.retry and "wrong_key" in u.error

  test "a service that is not there: the provider cannot even be made, and the failure may pass":
    let nobody = KekdConfig(url: "http://127.0.0.1:1", timeoutMs: 500)
    let k = httpKek(nobody)
    check not k.ok and k.retry

  test "teardown":
    stopEmulator()
