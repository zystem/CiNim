## D-57 (docs/store.md): the messages between the core and a store node. A body of fields round-trips with any bytes, a body cut short or longer than it says is not read, a field
## that is not there is empty, and a tag nobody knows is passed over. Pure.
import std/[unittest, options, strutils]
import store/wire

suite "D-57 the wire form":
  test "fields round-trip, in order, with any bytes, empty values and a big one":
    var m: Msg
    var all = ""
    for i in 0 .. 255: all.add char(i)
    m.add(tOp, "put")
    m.add(tKey, "acme/r/ключ")
    m.add(tData, all & all)
    m.add(tSha256, "")
    m.add(tOffset, 1234567890123'i64)
    let back = decode(encode(m))
    check back.isSome and back.get == m
    check back.get.get(tData) == all & all and back.get.getInt(tOffset) == 1234567890123'i64
    var big: Msg
    big.add(tData, 'x'.repeat(9 shl 20))
    check decode(encode(big)).get.get(tData).len == 9 shl 20
  test "an empty body is no fields":
    check decode("").isSome and decode("").get.len == 0
  test "a body cut short, or with a length that goes past its end, is not read":
    var m: Msg
    m.add(tKey, "abcdef")
    m.add(tOp, "read")
    let s = encode(m)
    for cut in 1 ..< s.len:
      if cut != 11: check decode(s[0 ..< cut]).isNone          # 11 is the end of the first field: a whole body of one field
    check decode(s[0 ..< 11]).isSome
    check decode("\x03\xff\xff\xff\xffabc").isNone
    check decode("\x03\x7f\xff\xff\xffabc").isNone                      # over the largest body
  test "a missing field is empty or zero, a number that is not one is the default, repeated fields come back in order":
    var m: Msg
    m.add(tParts, partText(1, "aa"))
    m.add(tParts, partText(2, "bb"))
    m.add(tLimit, "not a number")
    check m.get(tKey) == "" and not m.has(tKey) and m.getInt(tOffset) == 0 and m.getInt(tOffset, 7) == 7
    check m.getInt(tLimit, 5) == 5
    check m.all(tParts) == @["1:aa", "2:bb"]
    check parsePart("2:bb").get == (2, "bb") and parsePart("x:bb").isNone and parsePart("nocolon").isNone and parsePart(":bb").isNone
  test "a tag nobody knows is carried and ignored":
    var m: Msg
    m.add(200'u8, "future")
    m.add(tOp, "ping")
    let back = decode(encode(m)).get
    check back.get(tOp) == "ping" and back.get(200'u8) == "future"
  test "an entry of a listing keeps a key with spaces":
    let e = parseEntry(entryText("a b/c d", 42, 1700000000, true)).get
    check e.key == "a b/c d" and e.size == 42 and e.mtime == 1700000000 and e.exact
    check not parseEntry(entryText("k", 1, 2, false)).get.exact
    check parseEntry("garbage").isNone

  test "a view reads the same fields in place, with the same checks, and a big field is a span of the buffer":
    var m: Msg
    m.add(tOp, "put")
    m.add(tParts, partText(1, "aa"))
    m.add(tData, 'x'.repeat(3 shl 20))
    m.add(tParts, partText(2, "bb"))
    m.add(tOffset, 99'i64)
    var s = encode(m)
    let v = view(cast[ptr UncheckedArray[char]](addr s[0]), s.len)
    check v.isSome
    check v.get.get(tOp) == "put" and v.get.getInt(tOffset) == 99 and v.get.getInt(tLimit, 5) == 5 and v.get.get(tKey) == ""
    check v.get.all(tParts) == @["1:aa", "2:bb"]
    let sp = v.get.span(tData)
    check sp.n == 3 shl 20 and cast[uint](sp.p) > cast[uint](addr s[0]) and cast[uint](sp.p) < cast[uint](addr s[0]) + uint(s.len)
    check v.get.span(tKey).n == 0
    for cut in [1, 5, 10, s.len - 1]:
      var c = s[0 ..< cut]
      check view(cast[ptr UncheckedArray[char]](addr c[0]), c.len).isNone
    check view(nil, 0).isSome and view(nil, 0).get.get(tOp) == ""
  test "putTlv appends what encode makes":
    var m: Msg
    m.add(tOk, "1")
    m.add(tSize, 42'i64)
    var s = "head"
    s.putTlv(m)
    check s == "head" & encode(m) and m.tlvSize == encode(m).len
