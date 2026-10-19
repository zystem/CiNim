## The key service of a card (`kekd`): the protocol of core/kekclient.nim (docs/hardware-key.md section 10) over a master key that is on a token. The cryptography is in `ecies.nim`, the
## token's side is a `Derive` (pkcs11.nim, or a software key in the tests), and this is the door: what the service agrees to do, and what it writes down.
##
##   GET  /v1/info    -> {"key_id": "<fingerprint of the master public key>", "version": 1, "token": "ready" | "locked" | "absent", "disabled": false}
##   POST /v1/wrap    {"plain": "<hex>", "aad": "cinim/dek/v1|..."}     -> {"wrapped": "ecies1...."}      (needs the public key only: works with the card out)
##   POST /v1/unwrap  {"wrapped": "...", "aad": "cinim/dek/v1|..."}      -> {"plain": "<hex>"}            (the private operation, on the card)
##   errors: 409 wrong_key and 422 damaged / bad_aad are final, 423 locked, 429 busy, 503 unavailable / disabled may pass (core/kekclient.nim)
## The door (docs/hardware-key.md section 9): only a data key's own additional data (`cinim/dek/v1|`) is wrapped or opened, so the service cannot be used as an oracle for anything else; at
## most so many operations a minute and a day; a file that, when it exists, makes the service refuse everything without touching the card; and a line for every call (time, the client that
## the TLS front named, the operation, the additional data, the result) - never a key, a PIN or a secret.
import std/[json, locks, os, strutils, times, base64]
import ../common/httpsrv
import guildenstern/guildenserver
import ecies

type
  Reply* = tuple[status: int, body: JsonNode]

  ServiceConfig* = object
    masterPoint*: string               ## the public key: 65 bytes
    derive*: Derive                    ## the card's ECDH
    tokenState*: proc (): string {.gcsafe.}       ## "ready", "locked" or "absent" (nil: ready)
    aadPrefix*: string                 ## the additional data of a data key begins with this
    perMinute*, perDay*: int           ## 0: no limit
    disableFile*: string               ## when this file exists the service refuses everything
    auditFile*: string                 ## "" writes to the standard output
    clientHeader*: string              ## the header in which the TLS front says which client it let in ("" = none)
    transitKeys*: seq[string]          ## the names of the keys of the Transit face (the seal `transit` of OpenBao); none: the face is off
    transitMount*: string              ## the mount of the Transit face ("transit" when empty)

const
  defaultAadPrefix* = "cinim/dek/v1|"
  transitAadPrefix* = "openbao/seal/v1|"   ## the additional data of the Transit face: this and the name of the key; the core's door does not take it, nor this face the core's
  version = 1

var
  lock: Lock
  cfg: ServiceConfig
  window: array[2, tuple[start: int64, count: int]]       ## the minute and the day
initLock(lock)

proc configure*(c: ServiceConfig) =
  withLock lock:
    cfg = c
    if cfg.aadPrefix.len == 0: cfg.aadPrefix = defaultAadPrefix
    window = default(array[2, tuple[start: int64, count: int]])

proc audit(client, op, aad, outcome: string) =
  ## one JSON line; the additional data is public (it names the organisation), the keys and the PIN are not here
  let line = $(%*{"at": getTime().toUnix(), "client": client, "op": op, "aad": aad, "result": outcome})
  withLock lock:
    if cfg.auditFile.len > 0:
      try:
        let f = open(cfg.auditFile, fmAppend)
        f.writeLine line
        f.close()
      except IOError: stderr.writeLine line
    else:
      echo line

proc allowed(): bool =
  ## the budget of a minute and of a day; spent when asked
  let now = getTime().toUnix()
  withLock lock:
    for (i, span, limit) in [(0, 60'i64, cfg.perMinute), (1, 86400'i64, cfg.perDay)]:
      if limit <= 0: continue
      if now - window[i].start >= span:
        window[i] = (now - now mod span, 0)
      if window[i].count >= limit: return false
    for i in 0 .. 1: inc window[i].count
    result = true

proc state(): ServiceConfig =
  withLock lock: result = cfg

proc errorReply(status: int; code: string; detail = ""): Reply =
  (status, (if detail.len > 0: %*{"error": code, "detail": detail} else: %*{"error": code}))

proc disabled(c: ServiceConfig): bool = c.disableFile.len > 0 and fileExists(c.disableFile)

proc infoReply*(): Reply =
  let c = state()
  if c.masterPoint.len != 65: return errorReply(503, "unavailable", "the service does not know the master public key yet")
  (200, %*{"key_id": fingerprint(c.masterPoint), "version": version, "token": (if c.tokenState == nil: "ready" else: c.tokenState()), "disabled": c.disabled})

type
  Outcome = tuple[status: int, code, detail, value: string]     ## value: the wrapped text, or the plain data key in bytes

proc doWrap(c: ServiceConfig; op, aad, prefix, plain, client: string; maxLen: int): Outcome =
  ## the door for one wrap: the switch, the additional data, the budget, then the key
  if c.disabled: audit(client, op, aad, "disabled"); return (503, "disabled", "", "")
  if not aad.startsWith(prefix): audit(client, op, aad, "bad_aad"); return (422, "bad_aad", "", "")
  if not allowed(): audit(client, op, aad, "busy"); return (429, "busy", "", "")
  if plain.len == 0 or plain.len > maxLen: audit(client, op, aad, "damaged"); return (422, "damaged", "", "")
  let w = wrapKey(c.masterPoint, plain, aad)
  if not w.ok: audit(client, op, aad, "unavailable"); return (503, "unavailable", "", "")
  audit(client, op, aad, "ok")
  (200, "", "", w.wrapped)

proc doUnwrap(c: ServiceConfig; op, aad, prefix, wrapped, client: string): Outcome =
  if c.disabled: audit(client, op, aad, "disabled"); return (503, "disabled", "", "")
  if not aad.startsWith(prefix): audit(client, op, aad, "bad_aad"); return (422, "bad_aad", "", "")
  if not allowed(): audit(client, op, aad, "busy"); return (429, "busy", "", "")
  let u = unwrapKey(c.masterPoint, c.derive, wrapped, aad)
  case u.status
  of usOk:
    audit(client, op, aad, "ok")
    (200, "", "", u.plain)
  of usWrongKey: audit(client, op, aad, "wrong_key"); (409, "wrong_key", "", "")
  of usDamaged: audit(client, op, aad, "damaged"); (422, "damaged", "", "")
  of usUnavailable:
    let locked = c.tokenState != nil and c.tokenState() == "locked"
    audit(client, op, aad, if locked: "locked" else: "unavailable")
    if locked: (423, "locked", u.error, "") else: (503, "unavailable", u.error, "")

proc wrapReply*(body: JsonNode; client = ""): Reply =
  let c = state()
  let aad = body{"aad"}.getStr
  let p = unhex(body{"plain"}.getStr)
  # a plain text that is not hexadecimal is damaged like one of a wrong size
  let o = doWrap(c, "wrap", aad, c.aadPrefix, (if p.ok: p.text else: ""), client, 1024)
  if o.status == 200: (200, %*{"wrapped": o.value}) else: errorReply(o.status, o.code, o.detail)

proc unwrapReply*(body: JsonNode; client = ""): Reply =
  let c = state()
  let o = doUnwrap(c, "unwrap", body{"aad"}.getStr, c.aadPrefix, body{"wrapped"}.getStr, client)
  if o.status == 200: (200, %*{"plain": hexOf(o.value)}) else: errorReply(o.status, o.code, o.detail)

proc vaultError(status: int; message: string): Reply = (status, %*{"errors": [message]})

proc transitReply*(op, key: string; body: JsonNode; client = ""): Reply =
  ## the two calls that the seal `transit` of OpenBao makes (PUT /v1/<mount>/encrypt/<key> {"plaintext": base64} and .../decrypt/<key> {"ciphertext": "vault:v1:..."}),
  ## answered the way Transit does ({"data": {...}}, {"errors": [...]}): the key of OpenBao's own barrier is sealed to the master key of the card, under the additional data
  ## `openbao/seal/v1|<key name>`. The ciphertext is `vault:v1:` and the wrapped text in base64 (OpenBao splits it at the colons into three).
  let c = state()
  if key notin c.transitKeys: return vaultError(404, "encryption key not found")
  let aad = transitAadPrefix & key
  case op
  of "encrypt":
    let raw = body{"plaintext"}
    if raw == nil or raw.kind != JString: return vaultError(400, "missing plaintext")
    var plain = ""
    try: plain = decode(raw.getStr)
    except ValueError: return vaultError(400, "failed to base64-decode plaintext")
    let o = doWrap(c, "transit-encrypt", aad, transitAadPrefix, plain, client, 8192)
    case o.status
    of 200: (200, %*{"data": {"ciphertext": "vault:v1:" & encode(o.value), "key_version": 1}})
    of 422: vaultError(400, "invalid plaintext")
    of 429: vaultError(429, "busy")
    else: vaultError(503, o.code)
  of "decrypt":
    let raw = body{"ciphertext"}
    if raw == nil or raw.kind != JString: return vaultError(400, "missing ciphertext")
    let parts = raw.getStr.split(':')
    if parts.len != 3 or parts[0] != "vault" or parts[1] != "v1": return vaultError(400, "invalid ciphertext: no prefix")
    var wrapped = ""
    try: wrapped = decode(parts[2])
    except ValueError: return vaultError(400, "invalid ciphertext")
    let o = doUnwrap(c, "transit-decrypt", aad, transitAadPrefix, wrapped, client)
    case o.status
    of 200: (200, %*{"data": {"plaintext": encode(o.value)}})
    of 409, 422: vaultError(400, "invalid ciphertext: cannot be opened with this key")
    of 429: vaultError(429, "busy")
    else: vaultError(503, o.code & (if o.detail.len > 0: ": " & o.detail else: ""))
  else: vaultError(404, "unsupported path")

func headerOf(rawRequest, name: string): string =
  ## a header of a raw HTTP request, "" when there is none; only the header part is looked at, the name is case-insensitive
  let headEnd = rawRequest.find("\r\n\r\n")
  let head = if headEnd >= 0: rawRequest[0 ..< headEnd] else: rawRequest
  for line in head.split("\r\n"):
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].strip.toLowerAscii == name.toLowerAscii: return line[colon + 1 .. ^1].strip

proc reply(r: Reply) =
  reply(HttpCode(r.status), $r.body, ["Content-Type: application/json"])

proc onRequest() {.raises: [], gcsafe.} =
  {.cast(gcsafe).}:
    try:
      let uri = getUri()
      let path = if '?' in uri: uri[0 ..< uri.find('?')] else: uri
      let meth = getMethod()
      let c = state()
      let client = if c.clientHeader.len > 0: headerOf(getRequest(), c.clientHeader) else: ""
      if path == "/v1/info" and meth == "GET": reply(infoReply())
      elif path == "/v1/wrap" and meth == "POST": reply(wrapReply(parseJson(getBody()), client))
      elif path == "/v1/unwrap" and meth == "POST": reply(unwrapReply(parseJson(getBody()), client))
      elif c.transitKeys.len > 0 and meth in ["POST", "PUT"] and path.startsWith("/v1/" & (if c.transitMount.len > 0: c.transitMount else: "transit") & "/"):
        let parts = path.split('/')                     # "", "v1", mount, op, key
        if parts.len == 5 and parts[3] in ["encrypt", "decrypt"]: reply(transitReply(parts[3], parts[4], parseJson(getBody()), client))
        else: reply(vaultError(404, "unsupported path"))
      else: reply(errorReply(404, "not_found"))
    except Exception as e:
      reply(errorReply(400, "bad_request", e.msg))

proc startService*(port: int) =
  ## returns at once: GuildenStern runs its own threads. It listens on every address: put it behind the TLS front of docs/hardware-key.md section 9 and close the port to everything else
  let s = newService(onRequest)
  discard s.start(port, 8)

proc stopService*() =
  shutdown()
