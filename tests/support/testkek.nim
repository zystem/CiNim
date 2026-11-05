## A master key for the tests that need one and have no key service: HMAC-SHA256 of a fixed text under a string the test gives, held in memory, wrapping and unwrapping as the real ones do
## (the production key is always a key service, core/transitclient.nim: there is no key in a file and none derived from a file, D-106). Not for anything but a test.
import crunchy
import ../../src/common/sodiumaead
import ../../src/core/[kekprovider, secretvault]

const derivedKekId* = "test-derived"

proc derivedKek*(secret: string): KekProvider =
  let d = hmacSha256(secret, "cinim/secrets/kek/v1")
  var k = newSeq[byte](keyBytes)
  for i in 0 ..< keyBytes: k[i] = d[i]
  KekProvider(id: derivedKekId,
    wrap: proc (plain: seq[byte]; aad: string): WrapResult {.gcsafe.} =
      var t = newString(plain.len)
      if plain.len > 0: copyMem(addr t[0], unsafeAddr plain[0], plain.len)
      (true, false, "", seal(k, t, aad)),
    unwrap: proc (wrapped: string; aad: string): UnwrapResult {.gcsafe.} =
      let u = unseal(k, wrapped, aad)
      if not u.ok: return refused("the key is not the one that wrapped this")
      result.ok = true
      for ch in u.plain: result.plain.add byte(ch))
