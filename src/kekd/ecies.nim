## The wrapping of a data key under the master key, for the key service of a card (docs/hardware-key.md): ECDH-ES on P-256, then HKDF-SHA256, then XChaCha20-Poly1305.
##
##   wrap   (the master's PUBLIC key is enough: no card, no PIN)
##     an ephemeral key pair E; Z = ECDH(E, master public); K = HKDF-SHA256(Z, salt "cinim/kek/v1", info "cinim/kek/v1|<fingerprint>|<E public, hex>");
##     the wrapped text is  ecies1.<fingerprint>.<E public, 65 bytes hex>.<nonce 24 bytes || ciphertext || tag, hex>   (the data key sealed by K with the additional data)
##   unwrap (the card does the private operation)
##     Z = ECDH(master private, E public) on the card, the same K, the same unsealing. Nothing but the shared secret Z leaves the card.
## The fingerprint is the SHA-256 of the DER SubjectPublicKeyInfo of the master public key, the number that `tools/hsm/card-check.sh` prints; it names the key, and a wrapped text
## that names another key is `wrong_key` (final), not "damaged". The point E is checked to be on the curve before the card is asked (an invalid point would make ECDH leak the
## card's private key; the card checks too). The additional data binds the wrapped key to its place (the organisation): the service opens it for the same text only.
import std/strutils
import crunchy
import ../common/sodiumaead
import ossl

const
  formatTag* = "ecies1"
  kdfLabel = "cinim/kek/v1"

type
  DeriveResult* = tuple[ok, retry: bool, error: string, secret: string]
  Derive* = proc (peerPoint: string): DeriveResult {.gcsafe.}      ## the private half of the master key: ECDH with a point, on the card

  UnwrapStatus* = enum
    usOk
    usWrongKey                     ## wrapped for another key: nothing will help
    usDamaged                      ## not a wrapped key, or not for this place, or altered: nothing will help
    usUnavailable                  ## the card could not answer now (locked, removed, busy): may pass

  Unwrapped* = tuple[status: UnwrapStatus, plain: string, error: string]

func hexOf*(s: string): string =
  const digits = "0123456789abcdef"
  for c in s:
    result.add digits[int(byte(c) shr 4)]
    result.add digits[int(byte(c) and 15)]

func unhex*(s: string): tuple[ok: bool, text: string] =
  if s.len mod 2 != 0: return
  var i = 0
  while i < s.len:
    let v = try: parseHexInt(s[i .. i + 1]) except ValueError: return
    result.text.add char(v)
    i += 2
  result.ok = true

func bytesToString(b: openArray[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

proc fingerprint*(masterPoint: string): string =
  ## SHA-256 of the DER SubjectPublicKeyInfo of the master public key, hex (64 characters)
  hexOf(bytesToString(sha256(spkiOf(masterPoint))))

proc deriveKey(secret, fp, ephPoint: string): seq[byte] =
  ## HKDF-SHA256 (RFC 5869) with a salt, to one block: 32 bytes
  let prk = bytesToString(hmacSha256(kdfLabel, secret))
  let okm = hmacSha256(prk, kdfLabel & "|" & fp & "|" & hexOf(ephPoint) & "\x01")
  result = newSeq[byte](keyBytes)
  for i in 0 ..< keyBytes: result[i] = okm[i]

proc wrapKey*(masterPoint: string; plain: string; aad: string): tuple[ok: bool, wrapped: string] =
  ## `plain` is the data key; fails only if the master point is not a point of the curve
  let eph = generate()
  let z = eph.derive(masterPoint)
  if not z.ok: return
  let fp = fingerprint(masterPoint)
  let ephPoint = eph.point
  let key = deriveKey(z.secret, fp, ephPoint)
  let nonce = randomBytes(nonceBytes)
  let sealed = encrypt(key, nonce, plain, aad)
  result.ok = true
  result.wrapped = formatTag & "." & fp & "." & hexOf(ephPoint) & "." & hexOf(bytesToString(nonce) & bytesToString(sealed))

proc unwrapKey*(masterPoint: string; derive: Derive; wrapped, aad: string): Unwrapped =
  let parts = wrapped.split('.')
  if parts.len != 4 or parts[0] != formatTag: return (usDamaged, "", "not a wrapped key")
  if parts[1] != fingerprint(masterPoint): return (usWrongKey, "", "wrapped for another key")
  let ephHex = unhex(parts[2])
  if not ephHex.ok or not pointIsValid(ephHex.text): return (usDamaged, "", "the ephemeral point is not a point of the curve")
  let body = unhex(parts[3])
  if not body.ok or body.text.len < nonceBytes + tagBytes: return (usDamaged, "", "damaged")
  let z = derive(ephHex.text)
  if not z.ok:
    let why = if z.retry: usUnavailable else: usDamaged
    return (why, "", z.error)
  let key = deriveKey(z.secret, parts[1], ephHex.text)
  var nonce = newSeq[byte](nonceBytes)
  for i in 0 ..< nonceBytes: nonce[i] = byte(body.text[i])
  var sealed = newSeq[byte](body.text.len - nonceBytes)
  for i in 0 ..< sealed.len: sealed[i] = byte(body.text[nonceBytes + i])
  let o = decrypt(key, nonce, sealed, aad)
  if not o.ok: return (usDamaged, "", "damaged, or not for this place")
  (usOk, o.plain, "")
