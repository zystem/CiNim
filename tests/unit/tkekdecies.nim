## The wrapping of a data key for the key service of a card (kekd/ecies.nim): ECDH-ES on P-256, HKDF-SHA256, XChaCha20-Poly1305. The card's private operation is stood in for by a software key.
import std/[unittest, strutils, os, osproc, strformat]
import ../../src/kekd/[ossl, ecies]

let master = generate()
let masterPoint = master.point
var asked = 0

proc card(k: EcKey): Derive =
  result = proc (peer: string): DeriveResult {.gcsafe.} =
    {.cast(gcsafe).}:
      inc asked
      let r = k.derive(peer)
      (r.ok, false, (if r.ok: "" else: "the card refused the point"), r.secret)

let theCard = card(master)
let dek = "0123456789abcdef0123456789abcdef"
const aad = "cinim/dek/v1|t1"

suite "kekd: the wrapping of a data key":
  test "the master public key is 65 bytes, the fingerprint is the SHA-256 of its SubjectPublicKeyInfo - the number card-check.sh prints - and OpenSSL reads that DER":
    check masterPoint.len == 65 and masterPoint[0] == '\x04'
    let dir = getTempDir() / "tkekd"
    createDir dir
    writeFile(dir / "p.der", spkiOf(masterPoint))
    let (o, c) = execCmdEx("openssl dgst -sha256 -r " & (dir / "p.der"))
    check c == 0 and o.startsWith(fingerprint(masterPoint))
    let (t, c2) = execCmdEx("openssl ec -pubin -inform DER -in " & (dir / "p.der") & " -noout -text")
    check c2 == 0 and "256 bit" in t
  test "wrapped, a data key opens again with the card; the text names the key and hides the data key":
    let w = wrapKey(masterPoint, dek, aad)
    check w.ok and w.wrapped.startsWith("ecies1." & fingerprint(masterPoint) & ".") and hexOf(dek) notin w.wrapped
    let before = asked
    let u = unwrapKey(masterPoint, theCard, w.wrapped, aad)
    check u.status == usOk and u.plain == dek and asked == before + 1
  test "wrapping needs no card: the same data key wrapped twice gives two different texts (an ephemeral key each time)":
    let a = wrapKey(masterPoint, dek, aad).wrapped
    let b = wrapKey(masterPoint, dek, aad).wrapped
    check a != b
  test "another place (additional data) does not open it, and is damaged for good":
    let w = wrapKey(masterPoint, dek, aad).wrapped
    check unwrapKey(masterPoint, theCard, w, "cinim/dek/v1|t2").status == usDamaged
  test "a text wrapped for another master key is wrong_key, and the card is not asked":
    let other = generate()
    let w = wrapKey(other.point, dek, aad).wrapped
    let before = asked
    check unwrapKey(masterPoint, theCard, w, aad).status == usWrongKey and asked == before
  test "a changed text is damaged, whatever byte is changed":
    let w = wrapKey(masterPoint, dek, aad).wrapped
    let parts = w.split('.')
    # the sealed part: one nibble flipped in the middle
    var body = parts[3]
    body[body.len div 2] = (if body[body.len div 2] == 'a': 'b' else: 'a')
    check unwrapKey(masterPoint, theCard, parts[0 .. 2].join(".") & "." & body, aad).status == usDamaged
    check unwrapKey(masterPoint, theCard, "", aad).status == usDamaged
    check unwrapKey(masterPoint, theCard, "ecies1.x", aad).status == usDamaged
    check unwrapKey(masterPoint, theCard, "emu1." & parts[1] & "." & parts[3], aad).status == usDamaged
  test "a point that is not on the curve is refused before the card sees it (it could make ECDH leak the key)":
    let w = wrapKey(masterPoint, dek, aad).wrapped
    let parts = w.split('.')
    let before = asked
    let bad = "04" & "00".repeat(64)                                            # (0, 0) is not on P-256
    check unwrapKey(masterPoint, theCard, parts[0] & "." & parts[1] & "." & bad & "." & parts[3], aad).status == usDamaged
    let shortPoint = hexOf(unhex(parts[2]).text[0 .. 32])
    check unwrapKey(masterPoint, theCard, parts[0] & "." & parts[1] & "." & shortPoint & "." & parts[3], aad).status == usDamaged
    let compressed = "02" & parts[2][2 .. 65]
    check unwrapKey(masterPoint, theCard, parts[0] & "." & parts[1] & "." & compressed & "." & parts[3], aad).status == usDamaged
    check asked == before
  test "a card that cannot answer now (locked, removed) is unavailable, not damaged: asking again may work":
    let w = wrapKey(masterPoint, dek, aad).wrapped
    let locked: Derive = proc (peer: string): DeriveResult {.gcsafe.} = (false, true, "the token is locked", "")
    check unwrapKey(masterPoint, locked, w, aad).status == usUnavailable
  test "wrapping for a point that is not on the curve fails":
    check not wrapKey("\x04" & "\x00".repeat(64), dek, aad).ok
