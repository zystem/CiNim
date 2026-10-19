## The key service of a card (kekd/service.nim): the door in front of the master key, and the protocol that the core's client (core/kekclient.nim) speaks to it. The card's private operation
## is a software key here; the card itself is tried by tools/hsm/kekd-card-test.sh.
import std/[unittest, json, os, strutils, base64, httpclient]
import ../../src/kekd/[ossl, ecies, service]
import ../../src/core/[kekclient, kekprovider]

let master = generate()
let masterPoint = master.point
let dir = getTempDir() / "tkekdservice"
createDir dir

proc soft(k: EcKey): Derive =
  result = proc (peer: string): DeriveResult {.gcsafe.} =
    {.cast(gcsafe).}:
      let r = k.derive(peer)
      (r.ok, false, "", r.secret)

proc setup(perMinute = 0, perDay = 0; disable = ""; audit = ""; derive: Derive = nil; token: proc (): string {.gcsafe.} = nil; keys: seq[string] = @[]) =
  configure(ServiceConfig(masterPoint: masterPoint, derive: (if derive != nil: derive else: soft(master)), tokenState: token,
                          perMinute: perMinute, perDay: perDay, disableFile: disable, auditFile: audit, clientHeader: "x-client", transitKeys: keys))

const aad = "cinim/dek/v1|t1"
let dekHex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

suite "kekd: the door":
  test "info names the key by its fingerprint (the one card-check.sh prints) and says how the token is":
    setup()
    let r = infoReply()
    check r.status == 200 and r.body["key_id"].getStr == fingerprint(masterPoint) and r.body["version"].getInt == 1 and r.body["token"].getStr == "ready" and not r.body["disabled"].getBool
    setup(token = proc (): string {.gcsafe.} = "locked")
    check infoReply().body["token"].getStr == "locked"
  test "a data key is wrapped and opened again, and the text is not the data key":
    setup()
    let w = wrapReply(%*{"plain": dekHex, "aad": aad})
    check w.status == 200 and w.body["wrapped"].getStr.startsWith("ecies1.") and dekHex notin w.body["wrapped"].getStr
    let u = unwrapReply(%*{"wrapped": w.body["wrapped"].getStr, "aad": aad})
    check u.status == 200 and u.body["plain"].getStr == dekHex
  test "only a data key's own additional data is accepted, either way: the service is no oracle for anything else":
    setup()
    check wrapReply(%*{"plain": dekHex, "aad": "something else"}).status == 422
    check wrapReply(%*{"plain": dekHex}).body["error"].getStr == "bad_aad"
    let w = wrapReply(%*{"plain": dekHex, "aad": aad}).body["wrapped"].getStr
    check unwrapReply(%*{"wrapped": w, "aad": "cinim/secret/v1|t1"}).body["error"].getStr == "bad_aad"
  test "the answers the core tells apart: wrong key 409, damaged 422 (final), a locked token 423 and an absent one 503 (may pass)":
    setup()
    let other = generate()
    let foreign = wrapKey(other.point, "k".repeat(32), aad).wrapped
    check unwrapReply(%*{"wrapped": foreign, "aad": aad}).status == 409
    check unwrapReply(%*{"wrapped": "junk", "aad": aad}).status == 422
    check unwrapReply(%*{"wrapped": wrapReply(%*{"plain": dekHex, "aad": aad}).body["wrapped"].getStr, "aad": "cinim/dek/v1|other"}).status == 422
    let w = wrapReply(%*{"plain": dekHex, "aad": aad}).body["wrapped"].getStr
    let off: Derive = proc (peer: string): DeriveResult {.gcsafe.} = (false, true, "no token in the reader", "")
    setup(derive = off, token = proc (): string {.gcsafe.} = "absent")
    check unwrapReply(%*{"wrapped": w, "aad": aad}).status == 503
    setup(derive = off, token = proc (): string {.gcsafe.} = "locked")
    check unwrapReply(%*{"wrapped": w, "aad": aad}).status == 423
    # wrapping needs no token at all
    check wrapReply(%*{"plain": dekHex, "aad": aad}).status == 200
  test "at most so many operations a minute: the next is busy (may pass), and the budget comes back with the next minute":
    setup(perMinute = 3)
    for _ in 1 .. 3: check wrapReply(%*{"plain": dekHex, "aad": aad}).status == 200
    check wrapReply(%*{"plain": dekHex, "aad": aad}).status == 429
    check infoReply().status == 200                                     # info costs nothing
  test "the switch: while its file exists everything is refused, with no touch of the token; without it the service goes on":
    let sw = dir / "disable"
    removeFile sw
    var asked = 0
    let counting: Derive = proc (peer: string): DeriveResult {.gcsafe.} =
      {.cast(gcsafe).}:
        inc asked
        let r = master.derive(peer)
        (r.ok, false, "", r.secret)
    setup(disable = sw, derive = counting)
    let w = wrapReply(%*{"plain": dekHex, "aad": aad}).body["wrapped"].getStr
    writeFile(sw, "off")
    check unwrapReply(%*{"wrapped": w, "aad": aad}).status == 503 and asked == 0
    check wrapReply(%*{"plain": dekHex, "aad": aad}).body["error"].getStr == "disabled"
    check infoReply().body["disabled"].getBool
    removeFile sw
    check unwrapReply(%*{"wrapped": w, "aad": aad}).status == 200 and asked == 1
  test "every call is a line, with the client and the result, and no key in it":
    let log = dir / "audit.log"
    removeFile log
    setup(audit = log)
    let w = wrapReply(%*{"plain": dekHex, "aad": aad}, "core-1").body["wrapped"].getStr
    discard unwrapReply(%*{"wrapped": w, "aad": aad}, "core-1")
    discard unwrapReply(%*{"wrapped": w, "aad": "nope"}, "")
    let lines = readFile(log).strip.splitLines
    check lines.len == 3
    let first = parseJson(lines[0])
    check first["op"].getStr == "wrap" and first["client"].getStr == "core-1" and first["aad"].getStr == aad and first["result"].getStr == "ok"
    check parseJson(lines[2])["result"].getStr == "bad_aad"
    let all = readFile(log)
    check dekHex notin all and w notin all

suite "kekd: the Transit face (the seal `transit` of OpenBao)":
  let key = "bao-seal"
  proc setupT(perMinute = 0; disable = ""; audit = ""; keys = @["bao-seal"]) =
    configure(ServiceConfig(masterPoint: masterPoint, derive: soft(master), perMinute: perMinute, disableFile: disable, auditFile: audit,
                            transitKeys: keys, clientHeader: "x-client"))
  let secret = "root-key-of-a-barrier-0123456789abcdef"
  test "encrypt gives vault:v1:<text> (three parts, as the client of OpenBao splits it) and decrypt gives the same back":
    setupT()
    let e = transitReply("encrypt", key, %*{"plaintext": encode(secret)})
    check e.status == 200
    let ct = e.body["data"]["ciphertext"].getStr
    check ct.split(':').len == 3 and ct.startsWith("vault:v1:") and secret notin ct
    let d = transitReply("decrypt", key, %*{"ciphertext": ct})
    check d.status == 200 and decode(d.body["data"]["plaintext"].getStr) == secret
  test "a key that is not offered is not there, and without any key the face is off":
    setupT()
    check transitReply("encrypt", "other", %*{"plaintext": encode(secret)}).status == 404
    setupT(keys = @[])
    check transitReply("encrypt", key, %*{"plaintext": encode(secret)}).status == 404
  test "what the face sealed does not open through the other door, nor the other way round (the additional data differs)":
    setupT()
    let ct = transitReply("encrypt", key, %*{"plaintext": encode(secret)}).body["data"]["ciphertext"].getStr
    let wrapped = decode(ct.split(':')[2])
    check wrapped.startsWith("ecies1.")
    check unwrapReply(%*{"wrapped": wrapped, "aad": "cinim/dek/v1|bao-seal"}).status == 422          # damaged: another additional data
    check unwrapReply(%*{"wrapped": wrapped, "aad": "openbao/seal/v1|bao-seal"}).status == 422       # bad_aad: not the door of the core
    let w2 = wrapReply(%*{"plain": hexOf(secret), "aad": aad}).body["wrapped"].getStr
    check transitReply("decrypt", key, %*{"ciphertext": "vault:v1:" & encode(w2)}).status == 400
  test "a ciphertext that is damaged or not of this service is refused as a bad request, a locked or absent card is told so":
    setupT()
    check transitReply("decrypt", key, %*{"ciphertext": "vault:v1:" & encode("junk")}).status == 400
    check transitReply("decrypt", key, %*{"ciphertext": "not-vault"}).status == 400
    check transitReply("encrypt", key, %*{"plaintext": "***not base64***"}).status == 400
    check transitReply("encrypt", key, %*{}).status == 400
    let ct = transitReply("encrypt", key, %*{"plaintext": encode(secret)}).body["data"]["ciphertext"].getStr
    let off: Derive = proc (peer: string): DeriveResult {.gcsafe.} = (false, true, "no token in the reader", "")
    configure(ServiceConfig(masterPoint: masterPoint, derive: off, transitKeys: @[key], tokenState: proc (): string {.gcsafe.} = "locked"))
    check transitReply("decrypt", key, %*{"ciphertext": ct}).status == 503
    check transitReply("encrypt", key, %*{"plaintext": encode(secret)}).status == 200               # wrapping needs no card
  test "the same door: the switch, the limit and the audit apply, and no key is in the audit":
    let sw = dir / "tdisable"
    let log = dir / "taudit.log"
    removeFile sw
    removeFile log
    setupT(perMinute = 3, disable = sw, audit = log)
    let ct = transitReply("encrypt", key, %*{"plaintext": encode(secret)}, "bao-1").body["data"]["ciphertext"].getStr
    discard transitReply("decrypt", key, %*{"ciphertext": ct}, "bao-1")
    check transitReply("encrypt", key, %*{"plaintext": encode(secret)}).status == 200
    check transitReply("encrypt", key, %*{"plaintext": encode(secret)}).status == 429
    setupT(disable = sw, audit = log)
    writeFile(sw, "off")
    check transitReply("decrypt", key, %*{"ciphertext": ct}).status == 503
    removeFile sw
    let all = readFile(log)
    check "\"op\":\"transit-encrypt\"" in all and "\"client\":\"bao-1\"" in all and "openbao/seal/v1|bao-seal" in all
    check secret notin all and ct notin all

const port = 18792
suite "kekd: over HTTP, with the core's own client":
  test "the core's provider wraps and unwraps through the service, and names the key by the service's fingerprint; the Transit routes next to it":
    setup(keys = @["bao-seal"])                       # the configuration is made before the service starts: its threads share it
    startService(port)
    sleep 300
    let cfg = KekdConfig(url: "http://127.0.0.1:" & $port, timeoutMs: 3000)
    let k = httpKek(cfg)
    check k.ok and k.kek.id == "kekd:" & fingerprint(masterPoint)
    var dek = newSeq[byte](32)
    for i in 0 ..< 32: dek[i] = byte(i * 3 + 1)
    let w = k.kek.wrap(dek, "cinim/dek/v1|t9")
    check w.ok and w.wrapped.startsWith("ecies1.")
    let u = k.kek.unwrap(w.wrapped, "cinim/dek/v1|t9")
    check u.ok and u.plain == dek
    let bad = k.kek.unwrap(w.wrapped, "cinim/dek/v1|t8")
    check not bad.ok and not bad.retry                                  # damaged: final
    let notOurs = k.kek.wrap(dek, "not a data key")
    check not notOurs.ok and not notOurs.retry                          # bad_aad: final
    # the Transit routes, the way the client of OpenBao calls them (PUT, a mount, no token)
    let c = newHttpClient(timeout = 3000)
    defer: c.close()
    c.headers = newHttpHeaders({"Content-Type": "application/json"})
    let base = "http://127.0.0.1:" & $port & "/v1/transit/"
    let e = c.request(base & "encrypt/bao-seal", httpMethod = HttpPut, body = $(%*{"plaintext": encode("0123456789")}))
    check e.code == Http200
    let ct = parseJson(e.body)["data"]["ciphertext"].getStr
    let d = c.request(base & "decrypt/bao-seal", httpMethod = HttpPost, body = $(%*{"ciphertext": ct}))
    check d.code == Http200 and decode(parseJson(d.body)["data"]["plaintext"].getStr) == "0123456789"
    check c.request(base & "decrypt/nokey", httpMethod = HttpPut, body = $(%*{"ciphertext": ct})).code == Http404
    check c.request(base & "rewrap/bao-seal", httpMethod = HttpPut, body = "{}").code == Http404
    stopService()
