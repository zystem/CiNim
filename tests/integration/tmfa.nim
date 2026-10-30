## D-101, against a real rqlite: two-step login with TOTP: set up, confirm with the first code, the codes of the app and the recovery codes (each once), a code used twice, turning it off, the reset of credentials
## and the deletion of a user take it away. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, sequtils, sets]
import common/rqlite
import core/[schema, apiauth, secretvault, kekprovider, mfa, totp]

let url = getEnv("CINIM_RQLITE_URL")

suite "D-101 two-step login":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    setDekCacheSeconds(0.0)
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let kek = derivedKek("mfa-key-" & sfx)
    let t0 = 1_800_000_000'i64
    var n = 0
    proc person(): string =
      inc n
      let name = "m" & sfx & $n
      check c.createUser(name, "dev", "a-long-password-of-" & name, t0, "org:acme-" & sfx)
      name
    proc codeAt(secretB32: string; t: int64): string = hotp(base32Decode(secretB32), counterAt(t))

    test "nothing is asked of a person who has not turned it on":
      let ann = person()
      check not c.mfaEnabled(ann) and c.checkSecondFactor(kek, ann, "", t0) == mcNotNeeded and c.checkSecondFactor(kek, ann, "123456", t0) == mcNotNeeded
    test "set up, confirmed with the first code, then the code of the app is asked and is good once":
      let ann = person()
      let e = c.enrollTotp(kek, ann, "CiNim", t0)
      check e.ok and e.secret.len >= 32 and e.uri.startsWith("otpauth://totp/CiNim:") and not c.mfaEnabled(ann)
      check c.checkSecondFactor(kek, ann, "", t0) == mcNotNeeded                                        # not on until it is confirmed
      check not c.confirmTotp(kek, ann, "000000", t0).ok and not c.confirmTotp(kek, ann, "", t0).ok
      let cf = c.confirmTotp(kek, ann, codeAt(e.secret, t0), t0)
      check cf.ok and cf.recovery.len == 10 and c.mfaEnabled(ann) and c.recoveryLeft(ann) == 10
      check c.checkSecondFactor(kek, ann, "", t0 + 60) == mcMissing and c.checkSecondFactor(kek, ann, "000000", t0 + 60) == mcWrong
      let next = codeAt(e.secret, t0 + 60)
      check c.checkSecondFactor(kek, ann, next, t0 + 60) == mcOk
      check c.checkSecondFactor(kek, ann, next, t0 + 61) == mcWrong                                      # the same code a second time
      check c.checkSecondFactor(kek, ann, codeAt(e.secret, t0 + 90), t0 + 90) == mcOk
      check not c.enrollTotp(kek, ann, "CiNim", t0).ok                                                   # on already
    test "a recovery code is good once, in any case and with or without the dash; a wrong one is wrong":
      let bob = person()
      let e = c.enrollTotp(kek, bob, "CiNim", t0)
      let cf = c.confirmTotp(kek, bob, codeAt(e.secret, t0), t0)
      let r = cf.recovery
      check c.checkSecondFactor(kek, bob, r[0], t0 + 1) == mcOk and c.checkSecondFactor(kek, bob, r[0], t0 + 1) == mcWrong
      check c.checkSecondFactor(kek, bob, r[1].toLowerAscii.replace("-", ""), t0 + 1) == mcOk and c.recoveryLeft(bob) == 8
      check c.checkSecondFactor(kek, bob, "AAAAA-AAAAA", t0 + 1) == mcWrong and c.recoveryLeft(bob) == 8
      check cf.recovery.deduplicate.len == 10
    test "the secret is not in the table; the hashes of the recovery codes are":
      let eve = person()
      let e = c.enrollTotp(kek, eve, "CiNim", t0)
      let cf = c.confirmTotp(kek, eve, codeAt(e.secret, t0), t0)
      let row = c.query(%*[["SELECT * FROM user_mfa WHERE user_name = ?", eve]])["results"][0]["values"][0]
      check e.secret notin $row and cf.recovery[0].replace("-", "") notin $row
      check c.query(%*[["SELECT value_enc FROM step_secrets WHERE tenant_id = '~mfa' AND name = ?", eve]])["results"][0]["values"][0][0].getStr.len > 0
      check e.secret notin c.query(%*[["SELECT value_enc FROM step_secrets WHERE tenant_id = '~mfa' AND name = ?", eve]])["results"][0]["values"][0][0].getStr
    test "turning it off, the reset of the credentials and the deletion of the user each take it away":
      let a = person()
      let b = person()
      let d = person()
      for u in [a, b, d]:
        let e = c.enrollTotp(kek, u, "CiNim", t0)
        check c.confirmTotp(kek, u, codeAt(e.secret, t0), t0).ok
      c.disableMfa(a)
      check not c.mfaEnabled(a) and c.checkSecondFactor(kek, a, "", t0) == mcNotNeeded
      check c.resetUserCredentials(b, t0).ok and not c.mfaEnabled(b)
      check c.deleteUser(d, t0) and not c.mfaEnabled(d) and c.query(%*[["SELECT count(*) FROM step_secrets WHERE tenant_id = '~mfa' AND name = ?", d]])["results"][0]["values"][0][0].getInt == 0
    test "the policy: administrators, everyone, or nobody":
      check mfaRequired("admin", true) and not mfaRequired("admin", false) and mfaRequired("all", false) and not mfaRequired("", true) and not mfaRequired("off", true)
