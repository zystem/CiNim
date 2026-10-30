## D-103: WebAuthn (security keys, Touch ID, Windows Hello) as a second factor, the parts that need no database: the base64url of the web, the small part of CBOR that a browser sends, the COSE key
## of a credential, the authenticator data, the checks of what the browser signed, and the one signature that is used, ES256 (ECDSA over P-256 and SHA-256, COSE algorithm -7).
## The check of a signature calls `libcrypto`, which the core links already for TLS (a static image takes it in with `--dynlibOverride:crypto`): no new library. The attestation of a new
## credential is not verified (format `none` is asked for; any other statement is read and ignored): the key is trusted the first time, as the password is, from a person who has just logged in.
import std/[json, strutils, base64, sysrand]
import crunchy
from std/openssl import DLLUtilName

type
  CborKind* = enum ckInt, ckBytes, ckText, ckArray, ckMap, ckSimple
  Cbor* = object
    case kind*: CborKind
    of ckInt: num*: int64
    of ckBytes: bytes*: string
    of ckText: text*: string
    of ckArray: items*: seq[Cbor]
    of ckMap: pairs*: seq[(Cbor, Cbor)]
    of ckSimple: simple*: int          ## 20 false, 21 true, 22 null

  WebauthnConfig* = object
    rpId*, rpName*: string
    origins*: seq[string]              ## the addresses a page may have (`https://ci.example.org`); a browser puts the one it is on into what it signs

  Credential* = object
    id*: string                        ## the credential id, base64url
    x*, y*: string                     ## the 32 bytes of each coordinate of the public key
    signCount*: uint32

  AuthData* = object
    rpIdHash*: string
    flags*: byte
    signCount*: uint32
    hasCredential*: bool
    credentialId*: string
    publicX*, publicY*: string

const
  flagUserPresent* = 0x01'u8
  flagUserVerified* = 0x04'u8
  flagAttested* = 0x40'u8
  maxDepth = 8
  maxItems = 64

func enabled*(cfg: WebauthnConfig): bool = cfg.rpId.len > 0 and cfg.origins.len > 0

# ---- base64url (no padding) ------------------------------------------------------------------------------------------------------------------------

func b64url*(s: string): string = encode(s, safe = true).strip(chars = {'='}, leading = false)

func unb64url*(s: string): tuple[ok: bool, data: string] =
  ## false for anything that is not base64url (the alphabet of the web, no padding)
  if s.len == 0: return (true, "")
  for ch in s:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_'}: return (false, "")
  if s.len mod 4 == 1: return (false, "")
  try: (true, decode(s.replace('-', '+').replace('_', '/') & repeat('=', (4 - s.len mod 4) mod 4))) except ValueError: (false, "")

proc randomChallenge*(): string =
  var buf = newSeq[byte](32)
  if not urandom(buf): raise newException(OSError, "no source of randomness")
  var raw = ""
  for b in buf: raw.add char(b)
  b64url(raw)

proc sha256Raw*(s: string): string =
  for b in sha256(s): result.add char(b)

# ---- CBOR: what a browser sends (definite lengths, integers, byte and text strings, arrays, maps, simple values) -----------------------------------

proc readCbor(s: string; pos: var int; depth: int): tuple[ok: bool, value: Cbor] =
  if depth > maxDepth or pos >= s.len: return
  let head = byte(s[pos])
  let major = head shr 5
  let info = int(head and 0x1f)
  inc pos
  var arg = 0'u64
  if major == 7:
    if info notin 20 .. 22: return
    return (true, Cbor(kind: ckSimple, simple: info))
  if info < 24: arg = uint64(info)
  elif info in 24 .. 27:
    let width = 1 shl (info - 24)
    if pos + width > s.len: return
    for i in 0 ..< width: arg = (arg shl 8) or uint64(byte(s[pos + i]))
    pos += width
  else: return                                                       # an indefinite length, or a reserved value: not used by an authenticator
  case major
  of 0:
    if arg > uint64(int64.high): return
    (true, Cbor(kind: ckInt, num: int64(arg)))
  of 1:
    if arg > uint64(int64.high): return
    (true, Cbor(kind: ckInt, num: -1'i64 - int64(arg)))
  of 2, 3:
    if arg > uint64(s.len - pos): return
    let str = s[pos ..< pos + int(arg)]
    pos += int(arg)
    (true, (if major == 2: Cbor(kind: ckBytes, bytes: str) else: Cbor(kind: ckText, text: str)))
  of 4:
    if arg > maxItems: return
    var v = Cbor(kind: ckArray)
    for _ in 0 ..< int(arg):
      let e = readCbor(s, pos, depth + 1)
      if not e.ok: return
      v.items.add e.value
    (true, v)
  of 5:
    if arg > maxItems: return
    var v = Cbor(kind: ckMap)
    for _ in 0 ..< int(arg):
      let k = readCbor(s, pos, depth + 1)
      if not k.ok: return
      let e = readCbor(s, pos, depth + 1)
      if not e.ok: return
      v.pairs.add (k.value, e.value)
    (true, v)
  else: (false, Cbor())                                              # tags (6) are not used here

proc parseCbor*(s: string; pos: var int): tuple[ok: bool, value: Cbor] =
  ## reads one item from `pos` and moves `pos` past it
  var p = pos
  result = readCbor(s, p, 0)
  if result.ok: pos = p

func mapGet*(m: Cbor; key: Cbor): Cbor =
  ## the value of `key` (an integer or a text) in a map, or a null simple value
  result = Cbor(kind: ckSimple, simple: 22)
  if m.kind != ckMap: return
  for (k, v) in m.pairs:
    if k.kind == key.kind and ((k.kind == ckInt and k.num == key.num) or (k.kind == ckText and k.text == key.text)):
      return v

func intKey(n: int64): Cbor = Cbor(kind: ckInt, num: n)
func textKey(t: string): Cbor = Cbor(kind: ckText, text: t)

# ---- authenticator data and the COSE key ---------------------------------------------------------------------------------------------------------

proc coseEs256(key: Cbor): tuple[ok: bool, x, y: string] =
  ## a COSE key of the type EC2, algorithm ES256, curve P-256 (RFC 9053): {1: 2, 3: -7, -1: 1, -2: x, -3: y}
  if key.kind != ckMap: return
  let kty = key.mapGet(intKey(1))
  let alg = key.mapGet(intKey(3))
  let crv = key.mapGet(intKey(-1))
  let x = key.mapGet(intKey(-2))
  let y = key.mapGet(intKey(-3))
  if kty.kind != ckInt or kty.num != 2 or alg.kind != ckInt or alg.num != -7 or crv.kind != ckInt or crv.num != 1: return
  if x.kind != ckBytes or y.kind != ckBytes or x.bytes.len != 32 or y.bytes.len != 32: return
  (true, x.bytes, y.bytes)

proc parseAuthData*(d: string): tuple[ok: bool, data: AuthData] =
  ## rpIdHash (32), flags (1), signCount (4), and when the flag says so the credential: aaguid (16), id length (2), id, the COSE key
  if d.len < 37: return
  var a = AuthData(rpIdHash: d[0 ..< 32], flags: byte(d[32]))
  a.signCount = (uint32(byte(d[33])) shl 24) or (uint32(byte(d[34])) shl 16) or (uint32(byte(d[35])) shl 8) or uint32(byte(d[36]))
  if (a.flags and flagAttested) != 0:
    if d.len < 55: return
    let idLen = (int(byte(d[53])) shl 8) or int(byte(d[54]))
    if idLen == 0 or idLen > 1023 or d.len < 55 + idLen: return
    a.credentialId = d[55 ..< 55 + idLen]
    var pos = 55 + idLen
    let k = parseCbor(d, pos)
    if not k.ok: return
    let c = coseEs256(k.value)
    if not c.ok: return
    a.hasCredential = true
    a.publicX = c.x
    a.publicY = c.y
  (true, a)

# ---- the signature -------------------------------------------------------------------------------------------------------------------------------

type EcKeyPtr = pointer

proc BN_bin2bn(s: cstring; len: cint; ret: pointer): pointer {.cdecl, dynlib: DLLUtilName, importc.}
proc BN_free(a: pointer) {.cdecl, dynlib: DLLUtilName, importc.}
proc EC_KEY_new_by_curve_name(nid: cint): EcKeyPtr {.cdecl, dynlib: DLLUtilName, importc.}
proc EC_KEY_free(k: EcKeyPtr) {.cdecl, dynlib: DLLUtilName, importc.}
proc EC_KEY_set_public_key_affine_coordinates(k: EcKeyPtr; x, y: pointer): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc ECDSA_verify(typ: cint; dgst: cstring; dlen: cint; sig: cstring; siglen: cint; key: EcKeyPtr): cint {.cdecl, dynlib: DLLUtilName, importc.}

const nidPrime256v1 = 415

proc verifyEs256*(x, y, message, derSignature: string): bool =
  ## whether `derSignature` (the ASN.1 form a browser gives) is a signature of SHA-256(`message`) by the key (x, y); a point that is not on the curve is no key
  if x.len != 32 or y.len != 32 or derSignature.len == 0 or derSignature.len > 80: return false
  let key = EC_KEY_new_by_curve_name(nidPrime256v1.cint)
  if key == nil: return false
  let bx = BN_bin2bn(x.cstring, 32, nil)
  let by = BN_bin2bn(y.cstring, 32, nil)
  try:
    if bx == nil or by == nil or EC_KEY_set_public_key_affine_coordinates(key, bx, by) != 1: return false
    let digest = sha256Raw(message)
    return ECDSA_verify(0, digest.cstring, 32, derSignature.cstring, derSignature.len.cint, key) == 1
  finally:
    if bx != nil: BN_free(bx)
    if by != nil: BN_free(by)
    EC_KEY_free(key)

# ---- the checks ----------------------------------------------------------------------------------------------------------------------------------

type ClientData = tuple[ok: bool, kind, challenge, origin: string, crossOrigin: bool]

proc readClientData(raw: string): ClientData =
  try:
    let j = parseJson(raw)
    if j.kind != JObject: return
    result = (true, j{"type"}.getStr, j{"challenge"}.getStr, j{"origin"}.getStr, j{"crossOrigin"}.getBool(false))
  except JsonParsingError, ValueError:
    discard

func originAllowed(cfg: WebauthnConfig; origin: string): bool = origin in cfg.origins

type
  Checked* = object
    ok*: bool
    error*: string
    challenge*: string                 ## what the browser signed: the caller checks that it is one it made for this person (and spends it)
    credential*: Credential
    authData*: AuthData

proc checkCommon(cfg: WebauthnConfig; clientDataJson, expectedType: string; auth: AuthData): tuple[ok: bool, error, challenge: string] =
  let cd = readClientData(clientDataJson)
  if not cd.ok: return (false, "clientDataJSON is not JSON", "")
  if cd.kind != expectedType: return (false, "the browser signed a " & cd.kind & ", not a " & expectedType, "")
  if cd.crossOrigin: return (false, "the page that asked is in a frame of another site", "")
  if not originAllowed(cfg, cd.origin): return (false, "the page is at " & cd.origin & ", which this shard does not accept for security keys (CINIM_WEBAUTHN_ORIGINS)", "")
  if auth.rpIdHash != sha256Raw(cfg.rpId): return (false, "the key was made for another site name than " & cfg.rpId, "")
  if (auth.flags and flagUserPresent) == 0: return (false, "the key did not report that you were there", "")
  if cd.challenge.len == 0: return (false, "no challenge", "")
  (true, "", cd.challenge)

proc checkRegistration*(cfg: WebauthnConfig; clientDataJson, attestationObject: string): Checked =
  ## the answer of `navigator.credentials.create`: the type, the origin, the site name hash, the presence of the person, a credential with a key we can use
  var pos = 0
  let att = parseCbor(attestationObject, pos)
  if not att.ok or att.value.kind != ckMap: return Checked(error: "attestationObject is not CBOR")
  let ad = att.value.mapGet(textKey("authData"))
  if ad.kind != ckBytes: return Checked(error: "attestationObject has no authData")
  let a = parseAuthData(ad.bytes)
  if not a.ok: return Checked(error: "authData is not well formed")
  if not a.data.hasCredential: return Checked(error: "the key sent no credential, or one that is not ES256 on P-256")
  let c = checkCommon(cfg, clientDataJson, "webauthn.create", a.data)
  if not c.ok: return Checked(error: c.error)
  # a point that is not on the curve is no key: ask libcrypto before the key is kept
  let probe = EC_KEY_new_by_curve_name(nidPrime256v1.cint)
  let bx = BN_bin2bn(a.data.publicX.cstring, 32, nil)
  let by = BN_bin2bn(a.data.publicY.cstring, 32, nil)
  let onCurve = probe != nil and bx != nil and by != nil and EC_KEY_set_public_key_affine_coordinates(probe, bx, by) == 1
  if bx != nil: BN_free(bx)
  if by != nil: BN_free(by)
  if probe != nil: EC_KEY_free(probe)
  if not onCurve: return Checked(error: "the public key is not a point of P-256")
  Checked(ok: true, challenge: c.challenge, authData: a.data,
          credential: Credential(id: b64url(a.data.credentialId), x: a.data.publicX, y: a.data.publicY, signCount: a.data.signCount))

proc checkAssertion*(cfg: WebauthnConfig; cred: Credential; clientDataJson, authenticatorData, signature: string): Checked =
  ## the answer of `navigator.credentials.get`: as above, and the signature of the key we hold over authenticatorData and the hash of clientDataJSON; the counter must have moved on
  ## (a counter that stays at 0 is an authenticator that has none)
  let a = parseAuthData(authenticatorData)
  if not a.ok: return Checked(error: "authenticatorData is not well formed")
  let c = checkCommon(cfg, clientDataJson, "webauthn.get", a.data)
  if not c.ok: return Checked(error: c.error)
  if not verifyEs256(cred.x, cred.y, authenticatorData & sha256Raw(clientDataJson), signature): return Checked(error: "the signature is not right")
  if (a.data.signCount != 0 or cred.signCount != 0) and a.data.signCount <= cred.signCount:
    return Checked(error: "the counter of the key did not move on: it may have been copied")
  Checked(ok: true, challenge: c.challenge, authData: a.data, credential: cred)

# ---- what a page is given to ask the browser -------------------------------------------------------------------------------------------------------

proc userHandle*(user: string): string = b64url(sha256Raw("cinim-webauthn:" & user))

proc creationOptions*(cfg: WebauthnConfig; user, challenge: string; existing: seq[string]): JsonNode =
  ## the `publicKey` argument of `navigator.credentials.create`, in the form the page turns into buffers
  var exclude = newJArray()
  for id in existing: exclude.add %*{"type": "public-key", "id": id}
  %*{"rp": {"id": cfg.rpId, "name": cfg.rpName}, "user": {"id": userHandle(user), "name": user, "displayName": user}, "challenge": challenge,
     "pubKeyCredParams": [{"type": "public-key", "alg": -7}], "excludeCredentials": exclude, "attestation": "none",
     "authenticatorSelection": {"userVerification": "preferred", "residentKey": "discouraged"}, "timeout": 120000}

func requestOptions*(cfg: WebauthnConfig; challenge: string; ids: seq[string]): JsonNode =
  ## the `publicKey` argument of `navigator.credentials.get`
  var allow = newJArray()
  for id in ids: allow.add %*{"type": "public-key", "id": id}
  %*{"rpId": cfg.rpId, "challenge": challenge, "allowCredentials": allow, "userVerification": "preferred", "timeout": 120000}
