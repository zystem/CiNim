## XChaCha20-Poly1305 (IETF construction) from libsodium, which the core and the shim already link for the CURVE transport (D-24; the static
## build of tools/image/Dockerfile.kaniko, a `--enable-minimal` libsodium, has this primitive). A 256-bit key, a 192-bit nonce that can safely be drawn at
## random for every message (AES-GCM's 96-bit nonce cannot, past about 2^32 messages under one key), a 128-bit tag, and additional data. It is
## constant-time in software, which a table-driven AES in pure Nim is not.
## A program that imports this module links `-lsodium`.
{.passL: "-lsodium".}

const
  keyBytes* = 32
  nonceBytes* = 24
  tagBytes* = 16

proc sodium_init(): cint {.cdecl, importc.}
proc randombytes_buf(buf: pointer; size: csize_t) {.cdecl, importc.}
proc crypto_aead_xchacha20poly1305_ietf_encrypt(c: ptr byte; clenP: ptr culonglong; m: ptr byte; mlen: culonglong; ad: ptr byte; adlen: culonglong;
                                                nsec: pointer; npub: ptr byte; k: ptr byte): cint {.cdecl, importc.}
proc crypto_aead_xchacha20poly1305_ietf_decrypt(m: ptr byte; mlenP: ptr culonglong; nsec: pointer; c: ptr byte; clen: culonglong; ad: ptr byte;
                                                adlen: culonglong; npub: ptr byte; k: ptr byte): cint {.cdecl, importc.}

var ready = false

proc init() =
  if not ready:
    if sodium_init() < 0: raise newException(OSError, "libsodium could not be initialised")
    ready = true

proc randomBytes*(n: int): seq[byte] =
  init()
  result = newSeq[byte](n)
  if n > 0: randombytes_buf(addr result[0], csize_t(n))

proc encrypt*(key, nonce: openArray[byte]; plain: string; aad: string): seq[byte] =
  ## ciphertext followed by the tag
  doAssert key.len == keyBytes and nonce.len == nonceBytes
  init()
  result = newSeq[byte](plain.len + tagBytes)
  var clen: culonglong
  let m = if plain.len > 0: cast[ptr byte](unsafeAddr plain[0]) else: nil
  let ad = if aad.len > 0: cast[ptr byte](unsafeAddr aad[0]) else: nil
  if crypto_aead_xchacha20poly1305_ietf_encrypt(addr result[0], addr clen, m, culonglong(plain.len), ad, culonglong(aad.len), nil,
                                                unsafeAddr nonce[0], unsafeAddr key[0]) != 0:
    raise newException(OSError, "encryption failed")

proc decrypt*(key, nonce: openArray[byte]; sealed: openArray[byte]; aad: string): tuple[ok: bool, plain: string] =
  ## not ok when the key, the nonce, the additional data or the text is not the one that was sealed
  if key.len != keyBytes or nonce.len != nonceBytes or sealed.len < tagBytes: return
  init()
  var buf = newSeq[byte](max(1, sealed.len - tagBytes))
  var mlen: culonglong
  let ad = if aad.len > 0: cast[ptr byte](unsafeAddr aad[0]) else: nil
  if crypto_aead_xchacha20poly1305_ietf_decrypt(addr buf[0], addr mlen, nil, unsafeAddr sealed[0], culonglong(sealed.len), ad, culonglong(aad.len),
                                                unsafeAddr nonce[0], unsafeAddr key[0]) != 0: return
  result.ok = true
  result.plain = newString(int(mlen))
  if mlen > 0: copyMem(addr result.plain[0], addr buf[0], int(mlen))
