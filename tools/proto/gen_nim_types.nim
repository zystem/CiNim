## The Nim types of all the messages (build/nimproto/all.proto) as a module of their own, `build/nimproto/protos.nim`, made by tools/proto/nim_flatten.sh.
## The macro `import_proto3` of protobuf_serialization makes the same types, but it runs in every program that is compiled (about 7 seconds of the compile of a test), and in every module that
## uses it, so that a program with three of them had three copies of every type. A module that imports and exports `protos` has them once and costs nothing to compile.
## Run by `nim c --compileOnly -d:protoFile=<all.proto> -d:outFile=<protos.nim> tools/proto/gen_nim_types.nim` (the file is written while it is compiled; `nim check` does not run the macro).
import std/macros
import protobuf_serialization
import protobuf_serialization/files/type_generator

const
  protoFile {.strdefine.} = ""
  outFile {.strdefine.} = ""

macro generate(): untyped =
  doAssert protoFile.len > 0 and outFile.len > 0, "give -d:protoFile=... and -d:outFile=..."
  let types = protoToTypesImpl(protoFile)
  writeFile(outFile, "## Made by tools/proto/gen_nim_types.nim from build/nimproto/all.proto; do not edit (tools/proto/nim_flatten.sh makes it again when the proto files change).\n" &
                     "import protobuf_serialization\nimport protobuf_serialization/files/type_generator\n\n" & types.repr & "\n")
  result = newStmtList()

generate()
