## D-101: RFC 4226 and RFC 6238 test vectors, the window, the use of a code once, base32 and the otpauth address.
import std/[unittest, strutils]
import core/totp

suite "D-101 TOTP":
  test "RFC 2202 HMAC-SHA1 vectors":
    func hex(s: string): string =
      for ch in s: result.add toLowerAscii(strutils.toHex(int(ord(ch)), 2))
    check hex(hmacSha1("\x0b".repeat(20), "Hi There")) == "b617318655057264e28bc0b6fb378c8ef146be00"
    check hex(hmacSha1("Jefe", "what do ya want for nothing?")) == "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79"
    check hex(hmacSha1("\xaa".repeat(80), "Test Using Larger Than Block-Size Key - Hash Key First")) == "aa4ae5e15272d00e95705637ce8a3b55ed402112"
  test "RFC 4226 appendix D: the first ten codes of 12345678901234567890":
    let secret = "12345678901234567890"
    let want = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]
    for i, w in want: check hotp(secret, int64(i)) == w
  test "RFC 6238 appendix B (SHA-1, 8 digits): time 59, 1111111109, 1234567890, 20000000000":
    let secret = "12345678901234567890"
    check hotp(secret, counterAt(59), 8) == "94287082" and hotp(secret, counterAt(1111111109), 8) == "07081804"
    check hotp(secret, counterAt(1234567890), 8) == "89005924" and hotp(secret, counterAt(20000000000'i64), 8) == "65353130"
  test "a code is good for its 30 seconds and the ones next to it, once, and not for another secret":
    let secret = "12345678901234567890"
    let t = 1_800_000_000'i64
    let code = hotp(secret, counterAt(t))
    let ok = verifyTotp(secret, code, t, 0)
    check ok.ok and ok.counter == counterAt(t)
    check not verifyTotp(secret, code, t, ok.counter).ok                      # the same code again
    check verifyTotp(secret, code, t + 30, 0).ok and verifyTotp(secret, code, t - 30, 0).ok and not verifyTotp(secret, code, t + 90, 0).ok
    check not verifyTotp("another-secret-0123456", code, t, 0).ok
    for bad in ["", "12345", "1234567", "12345a", "      "]: check not verifyTotp(secret, bad, t, 0).ok
    let next = verifyTotp(secret, hotp(secret, counterAt(t) + 1), t, ok.counter)          # the following step is a newer counter
    check next.ok and next.counter == ok.counter + 1
  test "base32 (RFC 4648) round trips and ignores spaces, case and padding; the address for an app":
    check base32Encode("foobar") == "MZXW6YTBOI" and base32Decode("MZXW6YTBOI") == "foobar" and base32Decode("mzxw 6ytb-oi==") == "foobar" and base32Decode("not base32!") == ""
    check base32Decode(base32Encode("12345678901234567890")) == "12345678901234567890"
    let s = newSecret()
    check s.len == 20 and base32Decode(base32Encode(s)) == s and newSecret() != s
    let uri = otpauthUri("CiNim shard", "ann@acme", "12345678901234567890")
    check uri == "otpauth://totp/CiNim%20shard:ann%40acme?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=CiNim%20shard&algorithm=SHA1&digits=6&period=30"
    check newRecoveryCode().len == 11 and newRecoveryCode()[5] == '-' and newRecoveryCode() != newRecoveryCode()
