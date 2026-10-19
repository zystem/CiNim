## The little of OpenSSL (libcrypto 3) that the key service needs: an EC P-256 key made in software, a public key read from the 65 bytes of its point and checked, and ECDH between them.
## The private operation of the *master* key is the card's, not OpenSSL's (kekd/pkcs11.nim); OpenSSL does the ephemeral half of an ECIES (`wrap` needs the master's public key only) and, in the
## tests, stands in for the card. A program that imports this module links `-lcrypto`.
{.passL: "-lcrypto".}

type
  EvpPkey = distinct pointer
  EvpPkeyCtx = distinct pointer

  EcKey* = ref object
    ## a private key in software: its handle is freed with the object
    pkey: EvpPkey

proc EVP_PKEY_Q_keygen(libctx: pointer; propq: cstring; typ: cstring): EvpPkey {.cdecl, importc, varargs.}       # EVP_EC_gen(curve) is a macro for this
proc EVP_PKEY_free(k: EvpPkey) {.cdecl, importc.}
proc EVP_PKEY_get1_encoded_public_key(k: EvpPkey; pub: ptr ptr byte): csize_t {.cdecl, importc.}
proc d2i_PUBKEY(a: pointer; pp: ptr ptr byte; length: clong): EvpPkey {.cdecl, importc.}
proc i2d_PUBKEY(k: EvpPkey; pp: ptr ptr byte): cint {.cdecl, importc.}
proc EVP_PKEY_CTX_new(k: EvpPkey; e: pointer): EvpPkeyCtx {.cdecl, importc.}
proc EVP_PKEY_CTX_free(c: EvpPkeyCtx) {.cdecl, importc.}
proc EVP_PKEY_derive_init(c: EvpPkeyCtx): cint {.cdecl, importc.}
proc EVP_PKEY_derive_set_peer(c: EvpPkeyCtx; peer: EvpPkey): cint {.cdecl, importc.}
proc EVP_PKEY_derive(c: EvpPkeyCtx; key: ptr byte; keylen: ptr csize_t): cint {.cdecl, importc.}
proc EVP_PKEY_public_check(c: EvpPkeyCtx): cint {.cdecl, importc.}
proc CRYPTO_free(p: pointer; file: cstring; line: cint) {.cdecl, importc.}

const
  pointBytes* = 65                 ## an uncompressed point of P-256: 0x04, X, Y
  secretBytes* = 32                ## what ECDH on P-256 gives
  spkiPrefix* = "\x30\x59\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\x03\x42\x00"
    ## the DER of SubjectPublicKeyInfo of a P-256 key up to the point: what `openssl ec -pubin` and `pkcs11-tool --read-object --type pubkey` give is this and the 65 bytes

proc freeKey(k: EcKey) = (if pointer(k.pkey) != nil: EVP_PKEY_free(k.pkey))

proc generate*(): EcKey =
  ## a new key pair on P-256
  let k = EVP_PKEY_Q_keygen(nil, nil, "EC", cstring("P-256"))
  if pointer(k) == nil: raise newException(OSError, "OpenSSL could not make an EC key")
  new(result, freeKey)
  result.pkey = k

proc point*(k: EcKey): string =
  ## the public half as 65 bytes (0x04, X, Y)
  var p: ptr byte
  let n = EVP_PKEY_get1_encoded_public_key(k.pkey, addr p)
  if n != csize_t(pointBytes) or p == nil: raise newException(OSError, "unexpected public key size")
  result = newString(pointBytes)
  copyMem(addr result[0], p, pointBytes)
  CRYPTO_free(p, "", 0)

func spkiOf*(point: string): string = spkiPrefix & point

proc loadPeer(point: string): EvpPkey =
  ## a public key from its 65 bytes, refused unless the point is on the curve (an invalid point makes ECDH leak the private key, so this is checked here and again by the card)
  if point.len != pointBytes or point[0] != '\x04': return EvpPkey(nil)
  let der = spkiOf(point)
  var src = cast[ptr byte](unsafeAddr der[0])
  let k = d2i_PUBKEY(nil, addr src, clong(der.len))
  if pointer(k) == nil: return EvpPkey(nil)
  let c = EVP_PKEY_CTX_new(k, nil)
  let ok = pointer(c) != nil and EVP_PKEY_public_check(c) == 1
  if pointer(c) != nil: EVP_PKEY_CTX_free(c)
  if not ok:
    EVP_PKEY_free(k)
    return EvpPkey(nil)
  k

proc pointIsValid*(point: string): bool =
  let k = loadPeer(point)
  if pointer(k) == nil: return false
  EVP_PKEY_free(k)
  true

proc derive*(k: EcKey; peerPoint: string): tuple[ok: bool, secret: string] =
  ## ECDH of this private key with a public point; not ok when the point is not a point of the curve
  let peer = loadPeer(peerPoint)
  if pointer(peer) == nil: return
  let c = EVP_PKEY_CTX_new(k.pkey, nil)
  defer:
    if pointer(c) != nil: EVP_PKEY_CTX_free(c)
    EVP_PKEY_free(peer)
  if pointer(c) == nil or EVP_PKEY_derive_init(c) != 1 or EVP_PKEY_derive_set_peer(c, peer) != 1: return
  var n: csize_t = csize_t(secretBytes)
  var buf = newString(secretBytes)
  if EVP_PKEY_derive(c, cast[ptr byte](addr buf[0]), addr n) != 1 or n != csize_t(secretBytes): return
  (true, buf)
