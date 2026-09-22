#!/usr/bin/env python3
"""Reference Protobuf vectors from Google's Python implementation (no protoc needed:
descriptors are built in code). Output: tests/vectors/pb_vectors.json."""
import json, sys
from google.protobuf import descriptor_pb2 as d, descriptor_pool, message_factory

F = d.FieldDescriptorProto
fdp = d.FileDescriptorProto(name="m0.proto", package="m0", syntax="proto3")

def field(msg, name, num, typ, label=F.LABEL_OPTIONAL, type_name=None, oneof=None):
    f = msg.field.add(name=name, number=num, type=typ, label=label)
    if type_name: f.type_name = type_name
    if oneof is not None: f.oneof_index = oneof
    return f

sc = fdp.message_type.add(name="Scalars")
for i, (n, t) in enumerate([("i32", F.TYPE_INT32), ("i64", F.TYPE_INT64), ("u32", F.TYPE_UINT32),
        ("u64", F.TYPE_UINT64), ("s32", F.TYPE_SINT32), ("s64", F.TYPE_SINT64), ("b", F.TYPE_BOOL),
        ("f32", F.TYPE_FIXED32), ("f64", F.TYPE_FIXED64), ("fl", F.TYPE_FLOAT), ("db", F.TYPE_DOUBLE),
        ("str", F.TYPE_STRING), ("by", F.TYPE_BYTES)], start=1):
    field(sc, n, i, t)

inner = fdp.message_type.add(name="Inner")
field(inner, "name", 1, F.TYPE_STRING); field(inner, "n", 2, F.TYPE_INT32)

en = fdp.enum_type.add(name="Kind")
for i, n in enumerate(["KIND_UNSET", "KIND_STEP", "KIND_APPROVAL"]): en.value.add(name=n, number=i)

outer = fdp.message_type.add(name="Outer")
field(outer, "inner", 1, F.TYPE_MESSAGE, type_name=".m0.Inner")
field(outer, "packed", 2, F.TYPE_INT32, F.LABEL_REPEATED)
field(outer, "names", 3, F.TYPE_STRING, F.LABEL_REPEATED)
field(outer, "items", 4, F.TYPE_MESSAGE, F.LABEL_REPEATED, ".m0.Inner")
field(outer, "kind", 5, F.TYPE_ENUM, type_name=".m0.Kind")
outer.oneof_decl.add(name="choice")
field(outer, "text", 6, F.TYPE_STRING, oneof=0)
field(outer, "num", 7, F.TYPE_INT32, oneof=0)
entry = outer.nested_type.add(name="CountsEntry"); entry.options.map_entry = True
field(entry, "key", 1, F.TYPE_STRING); field(entry, "value", 2, F.TYPE_INT32)
field(outer, "counts", 8, F.TYPE_MESSAGE, F.LABEL_REPEATED, ".m0.Outer.CountsEntry")

pool = descriptor_pool.DescriptorPool(); pool.Add(fdp)
factory = message_factory.MessageFactory(pool)
def cls(n):
    desc = pool.FindMessageTypeByName("m0." + n)
    if hasattr(message_factory, "GetMessageClass"): return message_factory.GetMessageClass(desc)
    return factory.GetPrototype(desc)
Scalars, Inner, Outer = cls("Scalars"), cls("Inner"), cls("Outer")

def hexof(m): return m.SerializeToString(deterministic=True).hex()
vec = {}
vec["scalars_basic"] = dict(json=dict(i32=150, i64=-1, u32=4294967295, u64=18446744073709551615, s32=-2, s64=-3,
    b=True, f32=7, f64=8, fl=1.5, db=-2.25, str="héllo мир", by="00ff10"), hex=hexof(Scalars(
    i32=150, i64=-1, u32=4294967295, u64=18446744073709551615, s32=-2, s64=-3, b=True, f32=7, f64=8,
    fl=1.5, db=-2.25, str="héllo мир", by=bytes([0, 255, 16]))))
vec["scalars_negative_i32"] = dict(json=dict(i32=-1), hex=hexof(Scalars(i32=-1)))
vec["scalars_defaults_omitted"] = dict(json={}, hex=hexof(Scalars(i32=0, str="", b=False)))
o = Outer(inner=Inner(name="a", n=-5), packed=[1, 300, -2, 0], names=["x", "", "yz"],
          items=[Inner(name="i1", n=1), Inner(name="i2", n=2)], kind=2, text="hello")
o.counts["b"] = 2; o.counts["a"] = 1
vec["outer_full"] = dict(json=dict(inner=dict(name="a", n=-5), packed=[1, 300, -2, 0], names=["x", "", "yz"],
    items=[dict(name="i1", n=1), dict(name="i2", n=2)], kind=2, text="hello", counts=dict(a=1, b=2)), hex=hexof(o))
o2 = Outer(num=42)
vec["outer_oneof_num"] = dict(json=dict(num=42), hex=hexof(o2))
# forward compatibility (N/N-1): a newer sender adds fields 100 (varint) and 101 (bytes); older reader must skip them
future = o.SerializeToString(deterministic=True) + bytes([0xA0, 0x06, 0x07]) + bytes([0xAA, 0x06, 0x03]) + b"abc"
vec["outer_future_fields"] = dict(json=vec["outer_full"]["json"], hex=future.hex())
json.dump(vec, open("tests/vectors/pb_vectors.json", "w"), indent=1, sort_keys=True)
print(len(vec), "vectors")
# self-check: python parses its own future-field vector
p = Outer(); p.ParseFromString(future); assert p.text == "hello" and p.kind == 2
