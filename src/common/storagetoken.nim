## The token of the core's call to the storage module (docs/storage-module.md): `Authorization: Bearer v1.<expires>.<mac>`, made by the core and checked by the module (storage/service.nim).
## The MAC is HMAC-SHA256 under the secret of the shard of the **shard**, the method, the **target** (the decoded path, and the query as it is sent, so that what a call does cannot be changed by
## changing the query) and the time the token stops being good: a token made for one call is no good for another path, query, method or shard, or after `tokenLifetime` seconds.
import std/strutils
import crunchy

const
  tokenLifetime* = 120        ## seconds a token is good for
  clockSkew* = 30             ## seconds a token may be from the future (the clocks of the core and of the module are not the same)

func hexOf(a: array[32, uint8]): string =
  const digits = "0123456789abcdef"
  for b in a:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

func equalConstTime(a, b: string): bool =
  var diff = a.len xor b.len
  for i in 0 ..< min(a.len, b.len): diff = diff or (ord(a[i]) xor ord(b[i]))
  diff == 0

proc macOfTarget(secret, shard, meth, target: string; expires: int64): string =
  hexOf(hmacSha256(secret, "cinim/storage/v1|" & $shard.len & "|" & shard & "|" & meth.toUpperAscii & "|" & $target.len & "|" & target & "|" & $expires))

proc signTarget*(secret, shard, meth, target: string; now: int64): string =
  ## the Authorization value (without `Bearer `) of a call for `shard`
  let expires = now + tokenLifetime
  "v1." & $expires & "." & macOfTarget(secret, shard, meth, target, expires)

proc verifyTarget*(secret, shard, meth, target, token: string; now: int64): bool =
  if secret.len == 0 or shard.len == 0: return false
  let parts = token.split('.')
  if parts.len != 3 or parts[0] != "v1" or parts[1].len == 0 or parts[1].len > 12: return false
  var expires: int64
  try: expires = parseBiggestInt(parts[1])
  except ValueError: return false
  if expires < now or expires > now + tokenLifetime + clockSkew: return false
  equalConstTime(parts[2], macOfTarget(secret, shard, meth, target, expires))
