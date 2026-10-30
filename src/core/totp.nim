## D-101: time-based one-time passwords (RFC 6238, HMAC-SHA1, 30 seconds, 6 digits): what the authenticator apps of people compute from the secret in a QR code. Pure but for the source of randomness.
import std/[strutils, sysrand]
import crunchy

const
  stepSeconds* = 30'i64
  digits* = 6

proc hmacSha1*(key, msg: string): string =
  ## HMAC (RFC 2104) over SHA-1, the 20 bytes as a string
  var k = key
  if key.len > 64:
    k = ""
    for b in sha1(key): k.add char(b)
  k = k & repeat('\0', 64 - k.len)
  var inner, outer = newString(64)
  for i in 0 ..< 64:
    inner[i] = char(byte(k[i]) xor 0x36'u8)
    outer[i] = char(byte(k[i]) xor 0x5c'u8)
  var innerHash = ""
  for b in sha1(inner & msg): innerHash.add char(b)
  for b in sha1(outer & innerHash): result.add char(b)

func counterBytes(counter: int64): string =
  for shift in countdown(56, 0, 8): result.add char((uint64(counter) shr uint64(shift)) and 0xff'u64)

proc hotp*(secret: string; counter: int64; numDigits = digits): string =
  ## RFC 4226 dynamic truncation
  let h = hmacSha1(secret, counterBytes(counter))
  let offset = int(byte(h[19]) and 0x0f'u8)
  let bin = (uint32(byte(h[offset]) and 0x7f'u8) shl 24) or (uint32(byte(h[offset + 1])) shl 16) or (uint32(byte(h[offset + 2])) shl 8) or uint32(byte(h[offset + 3]))
  var m = 1'u32
  for _ in 0 ..< numDigits: m *= 10
  align($(bin mod m), numDigits, '0')

func counterAt*(unixTime: int64): int64 = unixTime div stepSeconds

proc verifyTotp*(secret, code: string; now, lastCounter: int64): tuple[ok: bool, counter: int64] =
  ## the code of this 30 seconds, of the one before or of the one after (the clock of a phone), and only a step newer than the last accepted one: a code is good once
  if code.len != digits: return
  for ch in code:
    if ch notin {'0' .. '9'}: return
  let now30 = counterAt(now)
  for delta in [0'i64, -1, 1]:
    let c = now30 + delta
    if c <= lastCounter: continue
    var diff = 0'u8
    let want = hotp(secret, c)
    for i in 0 ..< digits: diff = diff or (byte(want[i]) xor byte(code[i]))
    if diff == 0: return (true, c)

const b32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

func base32Encode*(s: string): string =
  var buffer = 0'u32
  var bits = 0
  for ch in s:
    buffer = (buffer shl 8) or uint32(byte(ch))
    bits += 8
    while bits >= 5:
      result.add b32[int((buffer shr uint32(bits - 5)) and 31'u32)]
      bits -= 5
      buffer = buffer and ((1'u32 shl uint32(bits)) - 1)
  if bits > 0: result.add b32[int((buffer shl uint32(5 - bits)) and 31'u32)]

func base32Decode*(s: string): string =
  var buffer = 0'u32
  var bits = 0
  for ch in s.toUpperAscii:
    if ch in {' ', '-', '='}: continue
    let v = b32.find(ch)
    if v < 0: return ""
    buffer = (buffer shl 5) or uint32(v)
    bits += 5
    if bits >= 8:
      result.add char((buffer shr uint32(bits - 8)) and 0xff'u32)
      bits -= 8
      buffer = buffer and ((1'u32 shl uint32(bits)) - 1)

proc newSecret*(): string =
  ## 20 random bytes (the size of the SHA-1 block output; what authenticator apps expect)
  var buf = newSeq[byte](20)
  if not urandom(buf): raise newException(OSError, "no source of randomness")
  for b in buf: result.add char(b)

func otpauthUri*(issuer, account, secret: string): string =
  func esc(s: string): string =
    for ch in s:
      if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.', '~'}: result.add ch
      else: result.add "%" & toHex(int(ord(ch)), 2)
  "otpauth://totp/" & esc(issuer) & ":" & esc(account) & "?secret=" & base32Encode(secret) & "&issuer=" & esc(issuer) & "&algorithm=SHA1&digits=6&period=30"

proc newRecoveryCode*(): string =
  ## ten letters and digits in two groups of five, easy to copy: `K7QD2-M4XPA`
  var buf = newSeq[byte](10)
  if not urandom(buf): raise newException(OSError, "no source of randomness")
  for i, b in buf:
    if i == 5: result.add '-'
    result.add b32[int(b) mod 32]
