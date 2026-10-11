## IAM-001: the hash of a password a person chose (Argon2id from libsodium).
import std/[unittest, strutils]
import ../../src/common/sodiumpw

suite "IAM-001 password hashes":
  test "the string holds the algorithm and its cost, and the password verifies against it":
    let h = passwordHash("correct horse battery staple")
    check h.startsWith("$argon2id$") and "m=8192,t=16,p=1" in h       # 8 MiB, 16 passes
    check passwordMatches(h, "correct horse battery staple")
  test "a wrong password, an empty one, one that differs by a character or by the case, do not":
    let h = passwordHash("correct horse battery staple")
    for bad in ["", "correct horse battery stapl", "Correct horse battery staple", "correct horse battery staple ", "wrong"]:
      check not passwordMatches(h, bad)
  test "the same password gives a different string every time (a salt), and both verify":
    let a = passwordHash("same-password-123456")
    let b = passwordHash("same-password-123456")
    check a != b and passwordMatches(a, "same-password-123456") and passwordMatches(b, "same-password-123456")
  test "a string that is not a hash of ours never matches, whatever the password":
    for stored in ["", "plain", "a".repeat(64), "$argon2id$garbage", "$"]:
      check not passwordMatches(stored, stored)
      check not passwordMatches(stored, "")
  test "a password with non-ASCII characters, spaces and a zero byte keeps all of its length":
    let pw = "пароль с пробелами 密码"
    let h = passwordHash(pw)
    check passwordMatches(h, pw) and not passwordMatches(h, pw[0 ..< pw.len - 1])
    let z = "ab\0cd-efghijklmnop"
    let hz = passwordHash(z)
    check passwordMatches(hz, z) and not passwordMatches(hz, "ab")
