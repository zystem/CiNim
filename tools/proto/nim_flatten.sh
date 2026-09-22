#!/bin/bash
# protobuf_serialization resolves non-google imports relative to the importing file, while buf needs module-root paths.
# This builds a flat copy of proto/cicd/** (imports rewritten to bare file names) plus all.proto that imports everything,
# so one `import_proto3 ".../all.proto"` gives Nim every message. Usage: nim_flatten.sh OUTDIR
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
