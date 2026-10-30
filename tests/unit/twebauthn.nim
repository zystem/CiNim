## D-103: WebAuthn without a database: base64url, the CBOR a browser sends, the authenticator data, the checks of a registration and of an assertion, the signature (a software authenticator
## from tests/support/fakeauthn.nim signs what a browser would).
import std/[unittest, json, strutils]
import core/webauthn
import ../support/fakeauthn

let cfg = WebauthnConfig(rpId: "ci.example.org", rpName: "CiNim", origins: @["https://ci.example.org"])
let origin = "https://ci.example.org"

proc field(j: JsonNode; k: string): string = unb64url(j[k].getStr).data

suite "D-103 base64url and CBOR":
  test "base64url has no padding and no + or /, and refuses what is not it":
    check b64url("\xfb\xff\xfe") == "-__-" and unb64url("-__-").data == "\xfb\xff\xfe"
    check unb64url("YQ").data == "a" and unb64url("YQ==").ok == false and unb64url("a+b").ok == false and unb64url("Y").ok == false
    check unb64url("").ok
  test "integers, strings, arrays and maps; an indefinite length, a tag and a truncation are refused":
    var pos = 0
    let m = parseCbor(cborMap(cborText("a"), cborInt(-7), cborInt(3), cborBytes("xy")), pos)
    check m.ok and pos > 0 and m.value.mapGet(Cbor(kind: ckText, text: "a")).num == -7 and m.value.mapGet(Cbor(kind: ckInt, num: 3)).bytes == "xy"
    pos = 0
    check not parseCbor("\x5f\x41a\xff", pos).ok                     # an indefinite byte string
    pos = 0
    check not parseCbor("\xc1\x01", pos).ok                          # a tag
    pos = 0
    check not parseCbor("\x43ab", pos).ok                            # three bytes promised, two there
    pos = 0
    check not parseCbor("\x81\x81\x81\x81\x81\x81\x81\x81\x81\x81\x01", pos).ok     # nested too deep
    pos = 0
    check not parseCbor("", pos).ok

suite "D-103 a registration":
  test "a good one gives the credential and the challenge the browser signed":
    var au = newAuthenticator()
    let r = checkRegistration(cfg, au.create(cfg.rpId, origin, "chal-1").field("clientDataJSON"), au.create(cfg.rpId, origin, "chal-1").field("attestationObject"))
    check r.ok and r.challenge == "chal-1" and r.credential.id == b64url(au.credentialId) and r.credential.x == au.x and r.credential.y == au.y
  test "another origin, another site name, a frame, a login given as a registration, no presence, no credential, a point off the curve are each refused":
    var au = newAuthenticator()
    proc attempt(rp, org, ch: string; flags = flagUserPresent or flagAttested): Checked =
      let j = au.create(rp, org, ch, flags)
      checkRegistration(cfg, j.field("clientDataJSON"), j.field("attestationObject"))
    check attempt(cfg.rpId, origin, "c").ok
    check not attempt(cfg.rpId, "https://evil.example.org", "c").ok
    check not attempt("evil.example.org", origin, "c").ok
    check not attempt(cfg.rpId, origin, "c", flagAttested).ok                                # the person was not present
    check not attempt(cfg.rpId, origin, "c", flagUserPresent).ok                              # no credential in it
    check not checkRegistration(cfg, "not json", "").ok
    var bad = au
    bad.x = repeat('\x01', 32)
    bad.y = repeat('\x02', 32)
    let j = bad.create(cfg.rpId, origin, "c")
    check not checkRegistration(cfg, j.field("clientDataJSON"), j.field("attestationObject")).ok

suite "D-103 an assertion":
  var au = newAuthenticator()
  let reg = au.create(cfg.rpId, origin, "reg")
  let cred = checkRegistration(cfg, reg.field("clientDataJSON"), reg.field("attestationObject")).credential
  test "a signature of the key is good, and gives back the challenge":
    let j = au.get(cfg.rpId, origin, "login-1")
    let r = checkAssertion(cfg, cred, j.field("clientDataJSON"), j.field("authenticatorData"), j.field("signature"))
    check r.ok and r.challenge == "login-1" and r.authData.signCount == 1
  test "another key's signature, a changed message, another origin, a registration given as a login, no presence are each refused":
    var other = newAuthenticator()
    let a = other.get(cfg.rpId, origin, "c")
    check not checkAssertion(cfg, cred, a.field("clientDataJSON"), a.field("authenticatorData"), a.field("signature")).ok
    let b = au.get(cfg.rpId, origin, "c")
    check not checkAssertion(cfg, cred, b.field("clientDataJSON").replace("\"c\"", "\"d\""), b.field("authenticatorData"), b.field("signature")).ok
    let c = au.get(cfg.rpId, "https://evil.example.org", "c")
    check not checkAssertion(cfg, cred, c.field("clientDataJSON"), c.field("authenticatorData"), c.field("signature")).ok
    let d = au.get(cfg.rpId, origin, "c", kind = "webauthn.create")
    check not checkAssertion(cfg, cred, d.field("clientDataJSON"), d.field("authenticatorData"), d.field("signature")).ok
    let e = au.get(cfg.rpId, origin, "c", flags = 0)
    check not checkAssertion(cfg, cred, e.field("clientDataJSON"), e.field("authenticatorData"), e.field("signature")).ok
    check not checkAssertion(cfg, cred, "{}", "short", "").ok
  test "the counter must move on, unless the key has none":
    let first = au.get(cfg.rpId, origin, "x")
    var c2 = cred
    c2.signCount = au.counter                                        # the server has seen this counter already
    check not checkAssertion(cfg, c2, first.field("clientDataJSON"), first.field("authenticatorData"), first.field("signature")).ok
    var none = newAuthenticator()
    let nr = none.create(cfg.rpId, origin, "r")
    let nc = checkRegistration(cfg, nr.field("clientDataJSON"), nr.field("attestationObject")).credential
    let g = none.get(cfg.rpId, origin, "x", bump = false)
    check checkAssertion(cfg, nc, g.field("clientDataJSON"), g.field("authenticatorData"), g.field("signature")).ok
    check checkAssertion(cfg, nc, g.field("clientDataJSON"), g.field("authenticatorData"), g.field("signature")).ok     # twice: a key with no counter cannot be told
  test "the options for a page":
    let o = creationOptions(cfg, "ann", "ch", @["id1"])
    check o["rp"]["id"].getStr == cfg.rpId and o["pubKeyCredParams"][0]["alg"].getInt == -7 and o["excludeCredentials"][0]["id"].getStr == "id1" and o["user"]["id"].getStr == userHandle("ann")
    check userHandle("ann") != userHandle("bob") and userHandle("ann") == userHandle("ann")
    check requestOptions(cfg, "ch", @["a", "b"])["allowCredentials"].len == 2
