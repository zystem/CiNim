## A stand-in for the key service of a SmartCard-HSM (core/kekclient.nim describes the protocol), for developing and testing the core without the card.
## The "token" is a key in memory; the wrapped text is the data key sealed under it, and the key's name is a fingerprint of it. What makes it worth having is
## what it can be told to do (`POST /emu/fault`): not answer, be slow, say the token is locked, or change the key as if another card had been put in, so that the
## core's waiting, retrying, caching and refusing can be seen. It is not secure and holds nothing that matters; never run it where it could be mistaken for the real one.
import std/[json, strutils, os, locks, times]
import guildenstern/[dispatcher, httpserver, guildenserver]
import crunchy
import ../common/sodiumaead

type
  Fault* = enum fNone, fDown, fLocked, fSlow, fThrottle

var
  lock: Lock
  masterKey: seq[byte]
  fault = fNone
  delayMs = 0
  calls*: array[3, int]            ## info, wrap, unwrap: how many times the core asked (read by the tests)
initLock(lock)

func toHex(a: openArray[byte]): string =
  const digits = "0123456789abcdef"
  for b in a:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

func fromHex(s: string): tuple[ok: bool, bytes: seq[byte]] =
  if s.len mod 2 != 0: return
  var i = 0
  while i < s.len:
    let v = try: parseHexInt(s[i .. i + 1]) except ValueError: return
    result.bytes.add byte(v)
    i += 2
  result.ok = true

proc fingerprint(): string =
  let d = sha256("cinim-kekd-emulator|" & toHex(masterKey))
  toHex(d)[0 ..< 32]

proc setKey*(key: seq[byte]) =
  withLock lock: masterKey = key

proc newRandomKey*() =
  setKey(randomBytes(keyBytes))

proc setFault*(f: Fault; delay = 0) =
  withLock lock:
    fault = f
    delayMs = delay

proc reply(status: HttpCode; body: JsonNode) =
  reply(status, $body, ["Content-Type: application/json"])

proc onRequest() {.raises: [], gcsafe.} =
  {.cast(gcsafe).}:
    try:
      let uri = getUri()
      let path = if '?' in uri: uri[0 ..< uri.find('?')] else: uri
      let meth = getMethod()
      var f: Fault
      var d: int
      var key: seq[byte]
      withLock lock:
        f = fault
        d = delayMs
        key = masterKey
      if path == "/emu/fault" and meth == "POST":
        let j = parseJson(getBody())
        setFault(parseEnum[Fault](j{"mode"}.getStr("fNone")), j{"delay_ms"}.getInt(0))
        reply(Http200, %*{"ok": true})
        return
      if path == "/emu/rekey" and meth == "POST":
        newRandomKey()                    # another card has been put in
        reply(Http200, %*{"ok": true, "key_id": fingerprint()})
        return
      case f
      of fDown:
        reply(Http503, %*{"error": "unavailable"})
        return
      of fLocked:
        reply(Http423, %*{"error": "locked"})
        return
      of fThrottle:
        reply(Http429, %*{"error": "busy"})
        return
      of fSlow:
        sleep d
      of fNone: discard
      if path == "/v1/info" and meth == "GET":
        withLock lock: inc calls[0]
        reply(Http200, %*{"key_id": fingerprint(), "version": 1})
      elif path == "/v1/wrap" and meth == "POST":
        withLock lock: inc calls[1]
        let j = parseJson(getBody())
        let p = fromHex(j{"plain"}.getStr)
        if not p.ok or p.bytes.len == 0:
          reply(Http422, %*{"error": "damaged"})
          return
        var plain = newString(p.bytes.len)
        copyMem(addr plain[0], unsafeAddr p.bytes[0], p.bytes.len)
        let nonce = randomBytes(nonceBytes)
        reply(Http200, %*{"wrapped": "emu1." & fingerprint() & "." & toHex(nonce) & toHex(encrypt(key, nonce, plain, j{"aad"}.getStr))})
      elif path == "/v1/unwrap" and meth == "POST":
        withLock lock: inc calls[2]
        let j = parseJson(getBody())
        let parts = j{"wrapped"}.getStr.split('.')
        if parts.len != 3 or parts[0] != "emu1":
          reply(Http422, %*{"error": "damaged"})
          return
        if parts[1] != fingerprint():
          reply(Http409, %*{"error": "wrong_key"})                 # wrapped by another key: no waiting will help
          return
        let raw = fromHex(parts[2])
        if not raw.ok or raw.bytes.len < nonceBytes + tagBytes:
          reply(Http422, %*{"error": "damaged"})
          return
        let o = decrypt(key, raw.bytes[0 ..< nonceBytes], raw.bytes[nonceBytes .. ^1], j{"aad"}.getStr)
        if not o.ok:
          reply(Http422, %*{"error": "damaged"})
          return
        var bytes = newSeq[byte](o.plain.len)
        copyMem(addr bytes[0], unsafeAddr o.plain[0], o.plain.len)
        reply(Http200, %*{"plain": toHex(bytes)})
      else:
        reply(Http404, %*{"error": "not_found"})
    except CatchableError as e:
      reply(Http400, %*{"error": "bad_request", "detail": e.msg})

proc startEmulator*(port: int; key: seq[byte] = @[]) =
  ## returns at once: GuildenStern runs its own threads
  setKey(if key.len == keyBytes: key else: randomBytes(keyBytes))
  let s = newHttpServer(onRequest)
  discard s.start(port, 8)

proc stopEmulator*() =
  shutdown()
