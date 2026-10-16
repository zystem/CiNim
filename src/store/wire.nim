## The messages between the core and a store node (docs/store.md, D-57): one request and one reply, each the payload of a frame of the push channel's envelope (common/stream.nim:
## kind `store.req` and `store.rep`, the reply carries the request's `id` in `re`). The body is a list of fields, each `u8 tag | u32 length | bytes` (big endian); a number is its decimal
## text, so a reader that meets a tag it does not know skips it and a field that is not there is the empty string or zero. Hand made, not Protobuf: the node needs none of the generated
## message types of the rest of the platform.
import std/[strutils, options]

type
  Field* = tuple[tag: uint8, value: string]
  Msg* = seq[Field]

const
  tOp* = 1'u8
  tToken* = 2'u8
  tKey* = 3'u8
  tData* = 4'u8
  tUploadId* = 5'u8
  tPart* = 6'u8
  tOffset* = 7'u8
  tLength* = 8'u8
  tSha256* = 9'u8
  tParts* = 10'u8            ## repeated: `<part>:<etag>`
  tPrefix* = 11'u8
  tAfter* = 12'u8
  tLimit* = 13'u8
  # the reply
  tOk* = 20'u8
  tCode* = 21'u8
  tError* = 22'u8
  tSize* = 23'u8
  tEtag* = 24'u8
  tEntries* = 25'u8          ## repeated: see `entryText`
  tNext* = 26'u8
  tTotal* = 27'u8
  tFree* = 28'u8
  tCount* = 29'u8
  maxBody* = 32 * 1024 * 1024

func add*(m: var Msg; tag: uint8; value: string) = m.add (tag, value)
func add*(m: var Msg; tag: uint8; value: int64) = m.add (tag, $value)

func encode*(m: Msg): string =
  var n = 0
  for f in m: n += 5 + f.value.len
  result = newStringOfCap(n)
  for f in m:
    result.add char(f.tag)
    for i in countdown(3, 0): result.add char((f.value.len shr (i * 8)) and 0xff)
    result.add f.value

func decode*(s: string): Option[Msg] =
  ## none for anything cut short or longer than it says
  var m: Msg
  var at = 0
  while at < s.len:
    if at + 5 > s.len: return none(Msg)
    let tag = uint8(s[at])
    var n = 0
    for i in 1 .. 4: n = (n shl 8) or ord(s[at + i])
    at += 5
    if n < 0 or n > maxBody or at + n > s.len: return none(Msg)
    m.add (tag, s[at ..< at + n])
    at += n
  some(m)

type
  Span* = tuple[p: ptr UncheckedArray[char], n: int]      ## bytes in somebody else's buffer
  View* = object
    ## A request read in place: the fields are positions in the buffer of the frame, which must live as long as the view does. A big field (`tData`) is never copied out of it.
    buf: ptr UncheckedArray[char]
    fields: seq[tuple[tag: uint8, at, n: int]]

func view*(p: ptr UncheckedArray[char]; len: int): Option[View] =
  ## the same checks as `decode`; none for anything cut short or longer than it says
  var v = View(buf: p)
  var at = 0
  while at < len:
    if at + 5 > len: return none(View)
    var n = 0
    for i in 1 .. 4: n = (n shl 8) or ord(p[at + i])
    let tag = uint8(p[at])
    at += 5
    if n < 0 or n > maxBody or at + n > len: return none(View)
    v.fields.add (tag, at, n)
    at += n
  some(v)

func span*(v: View; tag: uint8): Span =
  for f in v.fields:
    if f.tag == tag: return (cast[ptr UncheckedArray[char]](addr v.buf[f.at]), f.n)

func get*(v: View; tag: uint8): string =
  ## a copy: for the small fields
  let s = v.span(tag)
  if s.n > 0:
    result = newString(s.n)
    copyMem(addr result[0], s.p, s.n)

func all*(v: View; tag: uint8): seq[string] =
  for f in v.fields:
    if f.tag == tag:
      var s = newString(f.n)
      if f.n > 0: copyMem(addr s[0], addr v.buf[f.at], f.n)
      result.add s

func getInt*(v: View; tag: uint8; default = 0'i64): int64 =
  let s = v.get(tag)
  if s.len == 0: return default
  try: parseBiggestInt(s) except ValueError: default

func tlvSize*(m: Msg): int =
  for f in m: result += 5 + f.value.len

func putTlv*(dest: var string; m: Msg) =
  ## appends the encoding of `m` (`encode` is this into an empty string)
  for f in m:
    dest.add char(f.tag)
    for i in countdown(3, 0): dest.add char((f.value.len shr (i * 8)) and 0xff)
    dest.add f.value

func get*(m: Msg; tag: uint8): string =
  for f in m:
    if f.tag == tag: return f.value

func has*(m: Msg; tag: uint8): bool =
  for f in m:
    if f.tag == tag: return true

func getInt*(m: Msg; tag: uint8; default = 0'i64): int64 =
  let v = m.get(tag)
  if v.len == 0: return default
  try: parseBiggestInt(v) except ValueError: default

func all*(m: Msg; tag: uint8): seq[string] =
  for f in m:
    if f.tag == tag: result.add f.value

func partText*(part: int; etag: string): string = $part & ":" & etag

func parsePart*(s: string): Option[(int, string)] =
  let i = s.find(':')
  if i < 1: return none((int, string))
  try: some((parseInt(s[0 ..< i]), s[i + 1 .. ^1]))
  except ValueError: none((int, string))

func entryText*(key: string; size, mtime: int64; exact: bool): string =
  ## one entry of a listing: `size`, `mtime` and `1`/`0` for exact, a space apart, then the key
  $size & " " & $mtime & " " & (if exact: "1" else: "0") & " " & key

func parseEntry*(s: string): Option[tuple[key: string, size, mtime: int64, exact: bool]] =
  let p = s.split(' ', maxsplit = 3)
  if p.len != 4: return none(tuple[key: string, size, mtime: int64, exact: bool])
  try: some((p[3], parseBiggestInt(p[0]).int64, parseBiggestInt(p[1]).int64, p[2] == "1"))
  except ValueError: none(tuple[key: string, size, mtime: int64, exact: bool])
