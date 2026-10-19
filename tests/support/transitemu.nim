## A stand-in for a Transit key service (Vault/OpenBao Transit, or hsmgate, docs/hardware-key.md), for testing the core's client (core/transitclient.nim) without one.
## It speaks the part of the Transit API that the core uses (GET keys/<name>, PUT encrypt/<name>, PUT decrypt/<name>, with a `context`) and answers failures the way
## hsmgate does (`{"errors": [...]}`, the header X-Hsmgate-Retryable). The "token" is a key in memory; the ciphertext is `vault:v1:` and the base64 of the data key sealed under
## it. What makes it worth having is what it can be told to do: not answer, be slow, say the token is locked or the rate exceeded, or change the key as if another card had been put in.
## It is not a key service: it holds nothing that matters. The real one is run by tests/unit/thsmgate.nim when the binary is there.
import std/[json, strutils, os, locks, base64]
import ../../src/common/httpsrv
import guildenstern/guildenserver
import crunchy
import ../../src/common/sodiumaead

type
  Fault* = enum fNone, fDown, fLocked, fSlow, fThrottle

const mount = "transit"

var
  lock: Lock
  masterKey: seq[byte]
  fault = fNone
  delayMs = 0
  keyNames: seq[string] = @["cinim-shard"]
  retryHeader = true                 ## answer failures with X-Hsmgate-Retryable (hsmgate does; Vault and OpenBao do not)
  tokenSeen*: string                 ## the X-Vault-Token of the last request
  calls*: array[3, int]              ## keys, encrypt, decrypt: how many times the core asked (read by the tests)
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
  toHex(sha256("cinim-transit-emulator|" & toHex(masterKey)))[0 ..< 32]

proc setKey*(key: seq[byte]) =
  withLock lock: masterKey = key

proc newRandomKey*() =
  setKey(randomBytes(keyBytes))

proc setFault*(f: Fault; delay = 0) =
  withLock lock:
    fault = f
    delayMs = delay

proc setKeyNames*(names: seq[string]) =
  withLock lock: keyNames = names

proc setRetryHeader*(on: bool) =
  withLock lock: retryHeader = on

proc headerOf(raw, name: string): string =
  let head = raw[0 ..< (if raw.find("\r\n\r\n") >= 0: raw.find("\r\n\r\n") else: raw.len)]
  for line in head.split("\r\n"):
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].strip.toLowerAscii == name.toLowerAscii: return line[colon + 1 .. ^1].strip

proc replyJson(status: HttpCode; body: JsonNode; extra: seq[string] = @[]) =
  var h = @["Content-Type: application/json"]
  h.add extra
  reply(status, $body, h)

proc fail(status: HttpCode; msg: string; retry: bool) =
  var retryOn = false
  withLock lock: retryOn = retryHeader
  replyJson(status, %*{"errors": [msg]}, (if retryOn: @["X-Hsmgate-Retryable: " & $retry] else: @[]))

proc onRequest() {.raises: [], gcsafe.} =
  {.cast(gcsafe).}:
    try:
      let uri = getUri()
      let path = if '?' in uri: uri[0 ..< uri.find('?')] else: uri
      let meth = getMethod()
      var f: Fault
      var d: int
      var key: seq[byte]
      var names: seq[string]
      withLock lock:
        f = fault
        d = delayMs
        key = masterKey
        names = keyNames
        tokenSeen = headerOf(getRequest(), "X-Vault-Token")
      if path == "/emu/fault" and meth == "POST":
        let j = parseJson(getBody())
        setFault(parseEnum[Fault](j{"mode"}.getStr("fNone")), j{"delay_ms"}.getInt(0))
        replyJson(Http200, %*{"ok": true})
        return
      case f
      of fDown:
        fail(Http503, "service unavailable", true)
        return
      of fLocked:
        fail(Http503, "token locked", true)
        return
      of fThrottle:
        fail(Http429, "rate limit exceeded", true)
        return
      of fSlow:
        sleep d
      of fNone: discard
      let prefix = "/v1/" & mount & "/"
      if not path.startsWith(prefix):
        fail(Http404, "unsupported path", false)
        return
      let parts = path[prefix.len .. ^1].split('/')
      if parts.len != 2 or parts[1] notin names:
        fail(Http403, "permission denied", false)                 # a key that does not exist looks like one that is not granted
        return
      let op = parts[0]
      if op == "keys" and meth == "GET":
        withLock lock: inc calls[0]
        replyJson(Http200, %*{"data": {"name": parts[1], "type": "ecdh-es-p256", "latest_version": 1, "min_decryption_version": 1,
                                       "keys": {"1": {"fingerprint": fingerprint()}}, "token_state": "ready"}})
      elif op == "encrypt" and meth in ["PUT", "POST"]:
        withLock lock: inc calls[1]
        let j = parseJson(getBody())
        var plain = ""
        var ctx = ""
        try:
          plain = decode(j{"plaintext"}.getStr)
          ctx = decode(j{"context"}.getStr)
        except ValueError:
          fail(Http400, "failed to base64-decode", false)
          return
        if plain.len == 0:
          fail(Http400, "invalid plaintext", false)
          return
        let nonce = randomBytes(nonceBytes)
        let text = "emu1." & fingerprint() & "." & toHex(nonce) & toHex(encrypt(key, nonce, plain, ctx))
        replyJson(Http200, %*{"data": {"ciphertext": "vault:v1:" & encode(text), "key_version": 1}})
      elif op == "decrypt" and meth in ["PUT", "POST"]:
        withLock lock: inc calls[2]
        let j = parseJson(getBody())
        let ct = j{"ciphertext"}.getStr.split(':')
        var ctx = ""
        var text = ""
        try:
          ctx = decode(j{"context"}.getStr)
          if ct.len == 3: text = decode(ct[2])
        except ValueError: discard
        let parts = text.split('.')
        if ct.len != 3 or parts.len != 3 or parts[0] != "emu1":
          fail(Http400, "invalid ciphertext: cannot be opened with this key", false)
          return
        if parts[1] != fingerprint():
          fail(Http400, "invalid ciphertext: cannot be opened with this key", false)       # sealed by another key: no waiting will help
          return
        let raw = fromHex(parts[2])
        if not raw.ok or raw.bytes.len < nonceBytes + tagBytes:
          fail(Http400, "invalid ciphertext: cannot be opened with this key", false)
          return
        let o = decrypt(key, raw.bytes[0 ..< nonceBytes], raw.bytes[nonceBytes .. ^1], ctx)
        if not o.ok:
          fail(Http400, "invalid ciphertext: cannot be opened with this key", false)
          return
        replyJson(Http200, %*{"data": {"plaintext": encode(o.plain)}})
      else:
        fail(Http404, "unsupported path", false)
    except CatchableError as e:
      fail(Http400, "invalid request body: " & e.msg, false)

proc startEmulator*(port: int; key: seq[byte] = @[]) =
  ## returns at once: GuildenStern runs its own threads
  setKey(if key.len == keyBytes: key else: randomBytes(keyBytes))
  let s = newService(onRequest)
  discard s.start(port, 8)

proc stopEmulator*() =
  shutdown()
