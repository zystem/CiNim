## The store of the step secrets (core/secretvault.nim): XChaCha20-Poly1305, bound to its place, a key that is not the right one opens nothing; the step credential.
import std/[unittest, strutils, os]
import ../../src/core/secretvault
import ../../src/common/sodiumaead
import ../../src/common/ctrlauth

func keyOf(b: byte): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 32: result[i] = b

suite "sealing a value":
  test "what is sealed is opened with the same key and the same place, and the text does not show the value":
    let k = keyOf(0x11)
    let s = seal(k, "hunter2-secret-value", "cinim/secret/v1|t1|REGISTRY_PASSWORD|1")
    check s.startsWith("v2.") and "hunter2" notin s
    let u = unseal(k, s, "cinim/secret/v1|t1|REGISTRY_PASSWORD|1")
    check u.ok and u.plain == "hunter2-secret-value"
  test "a long, multi-line and empty value survive":
    let k = keyOf(0x22)
    for v in ["", "line1\nline2\n-----END KEY-----", "x".repeat(8192)]:
      let u = unseal(k, seal(k, v, "a"), "a")
      check u.ok and u.plain == v
  test "the same value sealed twice gives two texts (a fresh nonce)":
    let k = keyOf(0x33)
    check seal(k, "same", "a") != seal(k, "same", "a")
  test "another key, another place (tenant, name or version), or a changed text opens nothing":
    let k = keyOf(0x44)
    let s = seal(k, "v", "cinim/secret/v1|t1|A|1")
    check not unseal(keyOf(0x45), s, "cinim/secret/v1|t1|A|1").ok
    for other in ["cinim/secret/v1|t2|A|1", "cinim/secret/v1|t1|B|1", "cinim/secret/v1|t1|A|2"]:
      check not unseal(k, s, other).ok
    var flipped = s
    flipped[flipped.len - 3] = (if flipped[flipped.len - 3] == '0': '1' else: '0')
    check not unseal(k, flipped, "cinim/secret/v1|t1|A|1").ok
    check not unseal(k, "v1." & s[3 .. ^1], "cinim/secret/v1|t1|A|1").ok and not unseal(k, "", "a").ok and not unseal(k, "v2.zz", "a").ok

suite "the master key":
  test "a data key is wrapped and unwrapped by a key derived from the core's key; another core key unwraps nothing":
    let a = derivedKek("core-secret-A")
    let b = derivedKek("core-secret-B")
    let dek = keyOf(0x55)
    let w = a.wrap(dek, "cinim/dek/v1|t1")
    check w.ok
    check a.unwrap(w.wrapped, "cinim/dek/v1|t1").ok and a.unwrap(w.wrapped, "cinim/dek/v1|t1").plain == dek
    let wrongKey = b.unwrap(w.wrapped, "cinim/dek/v1|t1")
    check not wrongKey.ok and not wrongKey.retry                 # refused for good: waiting does not help
    check not a.unwrap(w.wrapped, "cinim/dek/v1|t2").ok
  test "a key file holds 64 hex digits and nothing else":
    writeFile(getTempDir() / "kek-good", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff\n")
    writeFile(getTempDir() / "kek-short", "0011")
    writeFile(getTempDir() / "kek-bad", "zz" & "00".repeat(31))
    check fileKek(getTempDir() / "kek-good").ok and fileKek(getTempDir() / "kek-good").kek.id == "file"
    check not fileKek(getTempDir() / "kek-short").ok and not fileKek(getTempDir() / "kek-bad").ok and not fileKek(getTempDir() / "kek-missing").ok

suite "the credential of a step":
  test "it is bound to the run, the step and the attempt, and to the core's key":
    let t = stepToken("master", "s1_run", 0, 1)
    check t == stepToken("master", "s1_run", 0, 1) and t.len == 64
    check t != stepToken("master", "s1_run", 0, 2) and t != stepToken("master", "s1_run", 1, 1)
    check t != stepToken("master", "s1_other", 0, 1) and t != stepToken("other-master", "s1_run", 0, 1)

suite "the algorithm itself":
  test "XChaCha20-Poly1305 gives the known answer of the draft (draft-irtf-cfrg-xchacha, A.3.1)":
    var key, nonce: seq[byte]
    for i in 0 ..< 32: key.add byte(0x80 + i)
    for i in 0 ..< 24: nonce.add byte(0x40 + i)
    let aad = "\x50\x51\x52\x53\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7"
    let plain = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
    let sealed = encrypt(key, nonce, plain, aad)
    var hex = ""
    for b in sealed: hex.add toHex(int(b), 2).toLowerAscii
    check hex == "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b4522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff921f9664c97637da9768812f615c68b13b52ec0875924c1c7987947deafd8780acf49"
    check decrypt(key, nonce, sealed, aad).plain == plain
