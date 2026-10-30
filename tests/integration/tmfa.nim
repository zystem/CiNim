## D-101, against a real rqlite: two-step login with TOTP: set up, confirm with the first code, the codes of the app and the recovery codes (each once), a code used twice, turning it off, the reset of credentials
## and the deletion of a user take it away. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, sequtils, sets]
import common/rqlite
import core/[schema, apiauth, secretvault, kekprovider, mfa, totp, webauthn]
import ../support/fakeauthn

let url = getEnv("CINIM_RQLITE_URL")
let sharedSfx = newId()[^6 .. ^1].toLowerAscii          # the vault of the pseudo organisation ~mfa is sealed by one key: both suites use the same

suite "D-101 two-step login":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    setDekCacheSeconds(0.0)
    let sfx = sharedSfx
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

suite "D-103 security keys":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    setDekCacheSeconds(0.0)
    let sfx = sharedSfx
    let kek = derivedKek("mfa-key-" & sfx)
    let t0 = 1_800_000_000'i64
    let cfg = WebauthnConfig(rpId: "ci.example.org", rpName: "CiNim", origins: @["https://ci.example.org"])
    let origin = "https://ci.example.org"
    var n = 0
    proc person(): string =
      inc n
      let name = "w" & sfx & $n
      check c.createUser(name, "dev", "a-long-password-of-" & name, t0, "org:acme-" & sfx)
      name
    proc register(user: string; au: var Authenticator; name = ""; at = t0): tuple[ok: bool, error: string, recovery: seq[string]] =
      let b = c.beginKey(cfg, user, at)
      check b.ok
      c.finishKey(cfg, user, name, au.create(cfg.rpId, origin, b.options["challenge"].getStr), at)
    proc challengeFor(user: string; at = t0): string = c.loginOptions(cfg, user, at)["challenge"].getStr

    test "a shard that is not set up for keys offers none":
      check not c.beginKey(WebauthnConfig(), "nobody", t0).ok
      check c.loginOptions(WebauthnConfig(), "nobody", t0).isNil
    test "a key is registered, makes the recovery codes once, and is asked for at the login":
      let ann = person()
      var au = newAuthenticator()
      check c.checkSecondFactor(kek, ann, "", t0, cfg = cfg) == mcNotNeeded and c.loginOptions(cfg, ann, t0).isNil
      let r = register(ann, au, "my phone")
      check r.ok and r.recovery.len == 10 and c.mfaEnabled(ann) and not c.totpEnabled(ann) and c.keyCount(ann) == 1
      check c.listKeys(ann)[0]["name"].getStr == "my phone"
      check c.checkSecondFactor(kek, ann, "", t0 + 5, cfg = cfg) == mcMissing
      let ch = challengeFor(ann, t0 + 5)
      check c.checkSecondFactor(kek, ann, "", t0 + 6, au.get(cfg.rpId, origin, ch), cfg) == mcOk
      check c.checkSecondFactor(kek, ann, "", t0 + 7, au.get(cfg.rpId, origin, ch), cfg) == mcWrong          # the challenge is spent
      check c.checkSecondFactor(kek, ann, r.recovery[0], t0 + 8, cfg = cfg) == mcOk                           # a recovery code does as well
      check c.checkSecondFactor(kek, ann, "123456", t0 + 8, cfg = cfg) == mcWrong                             # no app: a six-digit code is nothing
    test "a replayed answer, an old challenge, another person's challenge and another person's key are refused":
      let bob = person()
      let eve = person()
      var ab = newAuthenticator('b')
      var ae = newAuthenticator('e')
      discard register(bob, ab)
      discard register(eve, ae)
      let ch = challengeFor(bob, t0)
      let ans = ab.get(cfg.rpId, origin, ch)
      check c.checkSecondFactor(kek, bob, "", t0 + 1, ans, cfg) == mcOk
      check c.checkSecondFactor(kek, bob, "", t0 + 2, ans, cfg) == mcWrong                                    # the same answer again
      let old = challengeFor(bob, t0)
      check c.checkSecondFactor(kek, bob, "", t0 + 301 + 1, ab.get(cfg.rpId, origin, old), cfg) == mcWrong    # five minutes passed
      let forBob = challengeFor(bob, t0 + 400)
      check c.checkSecondFactor(kek, eve, "", t0 + 401, ae.get(cfg.rpId, origin, forBob), cfg) == mcWrong     # eve signs bob's challenge with her key
      check c.checkSecondFactor(kek, eve, "", t0 + 402, ab.get(cfg.rpId, origin, challengeFor(eve, t0 + 402)), cfg) == mcWrong     # bob's key is not eve's
    test "a key with a counter that does not move on is refused":
      let cat = person()
      var au = newAuthenticator('c')
      discard register(cat, au)
      check c.checkSecondFactor(kek, cat, "", t0, au.get(cfg.rpId, origin, challengeFor(cat)), cfg) == mcOk
      au.counter = 0
      check c.checkSecondFactor(kek, cat, "", t0, au.get(cfg.rpId, origin, challengeFor(cat)), cfg) == mcWrong
    test "a registration needs a challenge made for it, for this person; the same key twice is refused":
      let dan = person()
      let fay = person()
      var au = newAuthenticator('d')
      let b = c.beginKey(cfg, dan, t0)
      let ans = au.create(cfg.rpId, origin, b.options["challenge"].getStr)
      check not c.finishKey(cfg, fay, "", ans, t0).ok                                                         # fay did not ask
      check not c.finishKey(cfg, dan, "", au.create(cfg.rpId, origin, "made-up"), t0).ok
      check c.finishKey(cfg, dan, "", ans, t0).ok
      check not c.finishKey(cfg, dan, "", ans, t0).ok                                                         # spent
      let again = c.beginKey(cfg, dan, t0)
      check again.options["excludeCredentials"].len == 1
      check not c.finishKey(cfg, dan, "", au.create(cfg.rpId, origin, again.options["challenge"].getStr), t0).ok     # the same credential id
    test "with the app on as well, either is good; the recovery codes of the app are kept when a key is added":
      let gus = person()
      let e = c.enrollTotp(kek, gus, "CiNim", t0)
      let cf = c.confirmTotp(kek, gus, hotp(base32Decode(e.secret), counterAt(t0)), t0)
      var au = newAuthenticator('g')
      let r = register(gus, au)
      check r.ok and r.recovery.len == 0 and c.recoveryLeft(gus) == 10
      check c.checkSecondFactor(kek, gus, hotp(base32Decode(e.secret), counterAt(t0 + 60)), t0 + 60, cfg = cfg) == mcOk
      check c.checkSecondFactor(kek, gus, "", t0 + 90, au.get(cfg.rpId, origin, challengeFor(gus, t0 + 90)), cfg) == mcOk
      check cf.ok
    test "removing the last key takes the recovery codes with it; removing one of two does not":
      let hal = person()
      var a1 = newAuthenticator('1')
      var a2 = newAuthenticator('2')
      discard register(hal, a1)
      discard register(hal, a2)
      check c.keyCount(hal) == 2
      check c.removeKey(hal, b64url(a1.credentialId)) and c.mfaEnabled(hal) and c.recoveryLeft(hal) == 10
      check not c.removeKey(hal, b64url(a1.credentialId))
      check c.removeKey(hal, b64url(a2.credentialId)) and not c.mfaEnabled(hal) and c.recoveryLeft(hal) == 0
      check c.checkSecondFactor(kek, hal, "", t0, cfg = cfg) == mcNotNeeded
    test "turning two-step login off, the reset of the credentials and the deletion of the user take the keys away":
      let a = person()
      let b = person()
      let d = person()
      for u in [a, b, d]:
        var au = newAuthenticator()
        discard register(u, au)
      c.disableMfa(a)
      check c.keyCount(a) == 0 and not c.mfaEnabled(a)
      check c.resetUserCredentials(b, t0).ok and c.keyCount(b) == 0
      check c.deleteUser(d, t0) and c.keyCount(d) == 0
    test "at most ten keys":
      let ivy = person()
      for i in 0 ..< 10:
        var au = newAuthenticator(char(ord('A') + i))
        check register(ivy, au).ok
      check not c.beginKey(cfg, ivy, t0).ok

suite "D-103 the ticket between the password and the second factor":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let t0 = 1_800_000_000'i64
    test "a ticket names the person, counts a try each time it is asked, runs out after five and after five minutes, and is spent once":
      let tk = c.issueTicket("somebody", t0)
      check tk.len >= 40 and c.ticketUser(tk, t0 + 1) == "somebody"
      check "somebody" notin $c.query(%*[["SELECT hash FROM login_tickets WHERE user_name = 'somebody' ORDER BY expires_at DESC LIMIT 1"]])["results"][0]["values"][0][0]
      check tk notin $c.query(%*[["SELECT * FROM login_tickets WHERE user_name = 'somebody'"]])          # only the hash is kept
      for _ in 0 ..< 3: check c.ticketUser(tk, t0 + 2) == "somebody"
      check c.ticketUser(tk, t0 + 3) == "somebody"                                                         # the fifth
      check c.ticketUser(tk, t0 + 4) == ""                                                                 # out of tries
      let tk2 = c.issueTicket("somebody", t0)
      check c.ticketUser(tk2, t0 + 301) == ""                                                              # five minutes passed
      let tk3 = c.issueTicket("somebody", t0)
      check c.spendTicket(tk3) and not c.spendTicket(tk3) and c.ticketUser(tk3, t0 + 1) == ""
      check c.ticketUser("not-a-ticket", t0) == ""
