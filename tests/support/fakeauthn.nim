## A software authenticator for the tests of WebAuthn (D-103): it makes an ES256 key with libcrypto, answers `create` with an attestation object (format `none`) and `get` with a signed assertion,
## in the forms a browser gives them (base64url strings), so that a test can drive the core as a browser would.
import std/[json, strutils]
import ../../src/core/webauthn
from std/openssl import DLLUtilName

proc EC_KEY_new_by_curve_name(nid: cint): pointer {.cdecl, dynlib: DLLUtilName, importc.}
proc EC_KEY_generate_key(k: pointer): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EC_KEY_get0_public_key(k: pointer): pointer {.cdecl, dynlib: DLLUtilName, importc.}
proc EC_KEY_get0_group(k: pointer): pointer {.cdecl, dynlib: DLLUtilName, importc.}
proc EC_POINT_point2oct(g, p: pointer; form: cint; buf: pointer; len: csize_t; ctx: pointer): csize_t {.cdecl, dynlib: DLLUtilName, importc.}
proc ECDSA_sign(typ: cint; dgst: cstring; dlen: cint; sig: pointer; siglen: ptr cuint; key: pointer): cint {.cdecl, dynlib: DLLUtilName, importc.}

type Authenticator* = object
  key: pointer
  credentialId*: string              ## raw bytes
  x*, y*: string
  counter*: uint32

func cborHead(major: int; n: uint64): string =
  let m = char(major shl 5)
  if n < 24: $char(ord(m) or int(n))
  elif n < 256: $char(ord(m) or 24) & $char(n)
  else: $char(ord(m) or 25) & $char(n shr 8) & $char(n and 0xff)

func cborBytes*(s: string): string = cborHead(2, uint64(s.len)) & s
func cborText*(s: string): string = cborHead(3, uint64(s.len)) & s
func cborInt*(n: int): string = (if n >= 0: cborHead(0, uint64(n)) else: cborHead(1, uint64(-1 - n)))
func cborMap*(pairs: varargs[string]): string = cborHead(5, uint64(pairs.len div 2)) & pairs.join("")

proc newAuthenticator*(idByte = 'k'): Authenticator =
  result.key = EC_KEY_new_by_curve_name(415)
  doAssert EC_KEY_generate_key(result.key) == 1
  var buf = newString(65)
  doAssert EC_POINT_point2oct(EC_KEY_get0_group(result.key), EC_KEY_get0_public_key(result.key), 4, addr buf[0], 65, nil) == 65
  result.x = buf[1 ..< 33]
  result.y = buf[33 ..< 65]
  result.credentialId = repeat(idByte, 32)

func be32(n: uint32): string = $char(n shr 24) & $char((n shr 16) and 0xff) & $char((n shr 8) and 0xff) & $char(n and 0xff)

proc cose(a: Authenticator): string =
  cborMap(cborInt(1), cborInt(2), cborInt(3), cborInt(-7), cborInt(-1), cborInt(1), cborInt(-2), cborBytes(a.x), cborInt(-3), cborBytes(a.y))

proc clientData(kind, challenge, origin: string): string =
  $(%*{"type": kind, "challenge": challenge, "origin": origin, "crossOrigin": false})

proc create*(a: var Authenticator; rpId, origin, challenge: string; flags = flagUserPresent or flagAttested): JsonNode =
  ## what the page sends to :finish
  let authData = sha256Raw(rpId) & $char(flags) & be32(a.counter) & repeat('\0', 16) & $char(a.credentialId.len shr 8) & $char(a.credentialId.len and 0xff) & a.credentialId & a.cose
  let att = cborMap(cborText("fmt"), cborText("none"), cborText("attStmt"), cborMap(), cborText("authData"), cborBytes(authData))
  %*{"id": b64url(a.credentialId), "clientDataJSON": b64url(clientData("webauthn.create", challenge, origin)), "attestationObject": b64url(att)}

proc get*(a: var Authenticator; rpId, origin, challenge: string; flags = flagUserPresent; kind = "webauthn.get"; bump = true): JsonNode =
  ## what the page sends with the login
  if bump: inc a.counter
  let authData = sha256Raw(rpId) & $char(flags) & be32(a.counter)
  let cd = clientData(kind, challenge, origin)
  let digest = sha256Raw(authData & sha256Raw(cd))
  var sig = newString(80)
  var n: cuint = 80
  doAssert ECDSA_sign(0, digest.cstring, 32, addr sig[0], addr n, a.key) == 1
  sig.setLen(int(n))
  %*{"id": b64url(a.credentialId), "clientDataJSON": b64url(cd), "authenticatorData": b64url(authData), "signature": b64url(sig)}
