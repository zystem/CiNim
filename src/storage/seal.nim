## Sealing the secrets of the stores (docs/storage-module.md): the module holds a key in its own Secret (`CINIM_STORAGE_SEAL_KEY`), the database holds only what is sealed under it. XChaCha20-Poly1305
## (common/sodiumaead.nim), a fresh random nonce for every sealing, the name of the store as the additional data, so that a sealed value copied to another store's row does not open.
## `v1.` + hex of the nonce and the ciphertext with its tag. A program that imports this module links `-lsodium`.
import std/strutils
import checksums/sha2
import ../common/sodiumaead

const tag = "v1."

func toHex(a: openArray[byte]): string =
  const digits = "0123456789abcdef"
  for b in a:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

func fromHex(s: string): seq[byte] =
  if s.len mod 2 != 0: return @[]
  for i in countup(0, s.len - 2, 2):
    try: result.add byte(parseHexInt(s[i .. i + 1]))
    except ValueError: return @[]

proc sealKey*(secret: string): seq[byte] =
  ## the 32 bytes of the key from whatever text the operator gave (any length; a long random one is the point)
  for c in secureHash(Sha_256, "cinim/storage/seal/v1|" & secret): result.add byte(ord(c))

proc seal*(key: openArray[byte]; store, plain: string): string =
  let nonce = randomBytes(nonceBytes)
  tag & toHex(nonce) & toHex(encrypt(key, nonce, plain, store))

proc unseal*(key: openArray[byte]; store, sealed: string): tuple[ok: bool, plain: string] =
  if not sealed.startsWith(tag): return
  let raw = fromHex(sealed[tag.len .. ^1])
  if raw.len < nonceBytes + tagBytes: return
  decrypt(key, raw[0 ..< nonceBytes], raw[nonceBytes .. ^1], store)
