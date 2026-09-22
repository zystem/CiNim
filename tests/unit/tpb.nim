## Protobuf codec against reference vectors from Google's Python implementation
## (tools/m0/gen_pb_vectors.py). Spike 2 / D-04 / contract tests (section 18).
import std/[unittest, json, strutils, os]
import protobuf_serialization
import protobuf_serialization/files/type_generator

import_proto3 "../../proto/m0.proto"

const vectors = staticRead("../vectors/pb_vectors.json")
let V = parseJson(vectors)

proc unhex(s: string): seq[byte] =
  for i in countup(0, s.len - 2, 2): result.add byte(parseHexInt(s[i .. i + 1]))

proc hex(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii

func bytesOf(s: string): seq[byte] = unhex(s)

suite "D-04 protobuf vectors shared with Python":
  let scalars = Scalars(i32: 150, i64: -1, u32: 4294967295'u32, u64: 18446744073709551615'u64,
    s32: -2, s64: -3, b: true, f32: 7, f64: 8, fl: 1.5, db: -2.25,
    str: "héllo мир", by: @[0'u8, 255, 16])
  let outer = Outer(inner: Inner(name: "a", n: -5), packed: @[1'i32, 300, -2, 0],
    names: @["x", "", "yz"], items: @[Inner(name: "i1", n: 1), Inner(name: "i2", n: 2)],
    kind: KIND_APPROVAL, choice: OuterChoice(kind: OuterChoiceKind.text, text: "hello"),
    counts: @[CountsEntry(key: "a", value: 1), CountsEntry(key: "b", value: 2)])

  test "D-04 scalars encode byte-for-byte like Python":
    check hex(Protobuf.encode(scalars)) == V["scalars_basic"]["hex"].getStr

  test "D-04 negative int32 is a 10-byte varint":
    check hex(Protobuf.encode(Scalars(i32: -1))) == V["scalars_negative_i32"]["hex"].getStr

  test "D-04 proto3 defaults are not encoded":
    check Protobuf.encode(Scalars()).len == 0

  test "D-04 nested, repeated, enum, oneof and map encode like Python":
    check hex(Protobuf.encode(outer)) == V["outer_full"]["hex"].getStr

  test "D-04 oneof member encodes like Python":
    check hex(Protobuf.encode(Outer(choice: OuterChoice(kind: OuterChoiceKind.num, num: 42)))) ==
      V["outer_oneof_num"]["hex"].getStr

  test "D-04 scalars decode Python bytes":
    check Protobuf.decode(unhex(V["scalars_basic"]["hex"].getStr), Scalars) == scalars

  proc checkOuter(got: Outer) =
    check got.inner == outer.inner
    check got.packed == outer.packed and got.names == outer.names and got.items == outer.items
    check got.kind == KIND_APPROVAL
    check got.choice.kind == OuterChoiceKind.text and got.choice.text == "hello"
    check got.counts.len == 2 and got.counts[1].key == "b" and got.counts[1].value == 2
    check hex(Protobuf.encode(got)) == hex(Protobuf.encode(outer))  # no case-object ==

  test "D-04 outer decodes Python bytes":
    checkOuter Protobuf.decode(unhex(V["outer_full"]["hex"].getStr), Outer)

  test "D-04 unknown future fields are skipped (N/N-1)":
    checkOuter Protobuf.decode(unhex(V["outer_future_fields"]["hex"].getStr), Outer)

  test "D-04 round trip of 1000 random-ish messages":
    for i in 0 ..< 1000:
      let m = Scalars(i32: int32(i * 7919 - 3000), i64: int64(i) * -1_000_003, u64: uint64(i) * 0x10001'u64,
        s32: int32(-i), b: i mod 2 == 0, str: "s" & $i, by: @[byte(i and 255)])
      check Protobuf.decode(Protobuf.encode(m), Scalars) == m

  test "D-04 truncated and garbage input is rejected without crashing":
    let good = unhex(V["outer_full"]["hex"].getStr)
    for cut in 1 ..< good.len:
      try:
        discard Protobuf.decode(good[0 ..< cut], Outer)
      except CatchableError: discard   # a clean error is fine; a crash or hang is not
    for garbage in [@[0xFF'u8, 0xFF, 0xFF], @[0x0A'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F], @[0x08'u8]]:
      try:
        discard Protobuf.decode(garbage, Outer)
      except CatchableError: discard
