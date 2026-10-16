## SHA-256 of the store from libsodium, which the node already links for the CURVE transport (D-24): the pure-Nim hash is several times slower, and the node hashes every object it
## writes, every part it assembles and every file it is asked the `hash` of. A program that imports this module links `-lsodium`.
{.passL: "-lsodium".}
import std/strutils

type Sha256* = object
  state: array[16, uint64]            ## room for crypto_hash_sha256_state (104 bytes), aligned

proc crypto_hash_sha256_init(state: pointer): cint {.cdecl, importc.}
proc crypto_hash_sha256_update(state: pointer; m: pointer; mlen: culonglong): cint {.cdecl, importc.}
proc crypto_hash_sha256_final(state: pointer; digest: ptr byte): cint {.cdecl, importc.}
proc sodium_init(): cint {.cdecl, importc.}

var ready = false

proc initSha256*(): Sha256 =
  if not ready:
    discard sodium_init()
    ready = true
  discard crypto_hash_sha256_init(addr result.state)

proc update*(s: var Sha256; data: string) =
  if data.len > 0: discard crypto_hash_sha256_update(addr s.state, unsafeAddr data[0], culonglong(data.len))

proc update*(s: var Sha256; data: openArray[char]) =
  if data.len > 0: discard crypto_hash_sha256_update(addr s.state, unsafeAddr data[0], culonglong(data.len))

proc hexDigest*(s: var Sha256): string =
  var d: array[32, byte]
  discard crypto_hash_sha256_final(addr s.state, addr d[0])
  for b in d: result.add toHex(int(b), 2).toLowerAscii

proc sha256Hex*(data: string): string =
  var s = initSha256()
  s.update(data)
  s.hexDigest()
