## How the store node names a file for a key (docs/store.md, D-57). A key is a path of segments (`acme/s1_01a1/dist/app.txt`); the object is the file with that path under the
## node's `data/`, every segment escaped so that it is always one safe file name:
##   * letters, digits and `- _ . + = @ , ( )` stay, and so does a space inside the name; every other byte is `%XX` (upper case hex);
##   * a leading or trailing `.` or space is escaped too, so no file is hidden or special and none is called `.` or `..`;
##   * `~` is escaped: it marks the long form;
##   * a segment whose escape is longer than 200 bytes becomes its first 120 bytes (never cut inside a `%XX`), `~`, and 24 hex digits of the SHA-256 of the whole segment. It is still
##     readable, two different segments do not meet, and the whole name is in the database; read back from the disk it is not `exact`.
## A key is refused, never rewritten, when it could be a trick: empty, over 1024 bytes, an empty, `.` or `..` segment, a control character, a leading or trailing `/`.
import std/[strutils, sequtils]
import checksums/sha2

const
  maxKeyLen* = 1024
  maxEscapedSegment* = 200
  keptBytes = 120
  hashHexLen = 24
  hexDigits = "0123456789ABCDEF"

func safeByte(c: char): bool =
  c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.', '+', '=', '@', ',', '(', ')', ' '}

func hexOf(s: string): string =
  for c in s: result.add toHex(ord(c), 2).toLowerAscii

func escapeAll(s: string): string =
  for i, c in s:
    let edge = i == 0 or i == s.high
    if safeByte(c) and not (edge and c in {'.', ' '}): result.add c
    else:
      result.add '%'
      result.add hexDigits[ord(c) shr 4]
      result.add hexDigits[ord(c) and 15]

func escapeSegment*(s: string): string =
  ## the file name for one segment of a key
  result = escapeAll(s)
  if result.len <= maxEscapedSegment: return
  var cut = keptBytes
  while cut > 0 and cut < result.len and (result[cut - 1] == '%' or (cut >= 2 and result[cut - 2] == '%')): dec cut     # not inside a %XX
  var h = ""
  for c in secureHash(Sha_256, s): h.add toHex(ord(c), 2).toLowerAscii
  result = result[0 ..< cut] & "~" & h[0 ..< hashHexLen]

func hexVal(c: char): int =
  case c
  of '0' .. '9': ord(c) - ord('0')
  of 'A' .. 'F': ord(c) - ord('A') + 10
  of 'a' .. 'f': ord(c) - ord('a') + 10
  else: -1

func decodeEscapes(s: string): tuple[ok: bool, text: string] =
  var i = 0
  while i < s.len:
    if s[i] == '%':
      if i + 2 > s.high: return (false, "")
      let a = hexVal(s[i + 1])
      let b = hexVal(s[i + 2])
      if a < 0 or b < 0: return (false, "")
      result.text.add char(a * 16 + b)
      i += 3
    else:
      result.text.add s[i]
      inc i
  result.ok = true

func unescapeSegment*(name: string): tuple[ok, exact: bool, text: string] =
  ## the segment a file name stands for. A long form gives its readable start with `exact` false. A name nothing could have made is not ok.
  let tilde = name.rfind('~')
  if tilde >= 0:
    let tail = name[tilde + 1 .. ^1]
    if tail.len != hashHexLen or tail.anyIt(hexVal(it) < 0): return (false, false, "")
    let d = decodeEscapes(name[0 ..< tilde])
    return (d.ok, false, d.text)
  let d = decodeEscapes(name)
  (d.ok, d.ok, d.text)

func validKey*(key: string): string =
  ## "" if this may be a key, else why not (the node answers `bad_key` with it)
  if key.len == 0: return "the key is empty"
  if key.len > maxKeyLen: return "the key is over " & $maxKeyLen & " bytes"
  for c in key:
    if c < ' ' or c == '\x7f': return "the key has a control character"
  if key[0] == '/' or key[^1] == '/': return "the key starts or ends with /"
  for part in key.split('/'):
    if part.len == 0: return "the key has an empty segment"
    if part == "." or part == "..": return "the key has a . or .. segment"
  ""

func keyToRel*(key: string): string =
  ## the path under `data/` of the object of a valid key
  var parts: seq[string]
  for part in key.split('/'): parts.add escapeSegment(part)
  parts.join("/")

func relToKey*(rel: string): tuple[exact: bool, key: string] =
  ## the key a path under `data/` stands for; `exact` false if a segment is a long form (its start is returned)
  result.exact = true
  var parts: seq[string]
  for part in rel.split('/'):
    let u = unescapeSegment(part)
    if not u.ok:
      result.exact = false
      parts.add part
    else:
      if not u.exact: result.exact = false
      parts.add u.text
  result.key = parts.join("/")
