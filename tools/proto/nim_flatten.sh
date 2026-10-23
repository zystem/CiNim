#!/bin/bash
# protobuf_serialization resolves non-google imports relative to the importing file, while buf needs module-root paths.
# This builds a flat copy of proto/cicd/** (imports rewritten to bare file names) plus all.proto that imports everything,
# so that Nim gets every message from one file. It then makes `OUTDIR/protos.nim`, the Nim types of all of them (tools/proto/gen_nim_types.nim), which the modules of src/ import instead of running
# the macro `import_proto3` themselves (7 seconds in every compile, and a copy of the types in every module). The module is kept by the hash of the proto files, so a second call costs nothing. Usage: nim_flatten.sh OUTDIR
set -e
SRC="$(cd "$(dirname "$0")/../../proto" && pwd)"; OUT="${1:?output dir}"
rm -rf "$OUT"; mkdir -p "$OUT"
find "$SRC/cicd" -name '*.proto' | while read f; do
  sed -E 's|^import "cicd/[a-z_]+/v1/([a-z_]+\.proto)";|import "\1";|' "$f" > "$OUT/$(basename "$f")"
done
# protobuf_serialization cannot compile the recursive google.protobuf.Struct/Value (compile-time recursion limit): for Nim the plugin
# contract is flattened with Struct fields as `bytes` (same field numbers, same wire type 2: byte-identical on the wire).
rm "$OUT/plugin.proto"
sed -E '/import "google\/protobuf\/struct.proto";/d; s/google\.protobuf\.Struct/bytes/' "$SRC/cicd/plugin/v1/plugin.proto" > "$OUT/plugin_nim.proto"
{ echo 'syntax = "proto3";'; echo 'package cicd.all;'
  for f in $(cd "$OUT" && ls *.proto | grep -v '^all.proto$'); do echo "import \"$f\";"; done; } > "$OUT/all.proto"
echo "flattened $(ls "$OUT" | wc -l) files into $OUT"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; ABS="$(cd "$OUT" && pwd)"
HASH="$(cat "$ABS"/*.proto | sha256sum | cut -d' ' -f1)"; KEPT="$(dirname "$ABS")/.protos-$(basename "$ABS")-$HASH.nim"
if [ ! -f "$KEPT" ]; then
  (cd "$ROOT" && nim c --compileOnly --hints:off --warnings:off --nimcache:"$ABS/../.protos-nimcache" -d:protoFile="$ABS/all.proto" -d:outFile="$KEPT.part" tools/proto/gen_nim_types.nim >/dev/null) && mv "$KEPT.part" "$KEPT"
  find "$(dirname "$ABS")" -maxdepth 1 -name ".protos-$(basename "$ABS")-*.nim" ! -name "$(basename "$KEPT")" -delete
fi
cp "$KEPT" "$ABS/protos.nim"
echo "made $ABS/protos.nim"
