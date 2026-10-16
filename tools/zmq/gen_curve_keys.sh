#!/bin/bash
# Test-only CURVE keypairs for the ZeroMQ transport. Not for production use: a real deployment needs its own key issuance/
# distribution (e.g. Kubernetes Secrets), not files checked into a test fixture directory.
set -e
D="$(dirname "$0")/../../tests/certs/curve"; mkdir -p "$D"
# .pub files are tracked in git, .key files are gitignored (see .gitignore) - on a fresh checkout the
# .pub half exists but the .key half does not, so checking core.pub alone would wrongly skip
# regeneration and leave no secret keys at all. Check all four.
# Only the pairs that are missing are made (the store's pair came later than the core's and the client's).
missing=""
for n in core client store; do
  [ -f "$D/$n.pub" ] && [ -f "$D/$n.key" ] || missing="$missing $n"
done
[ -z "$missing" ] && exit 0
GEN="$(mktemp -d)"; trap 'rm -rf "$GEN"' EXIT
cat > "$GEN/gen.nim" <<'EOF'
import std/os
import zmq
doAssert hasCurve(), "libzmq was not built with CURVE (libsodium) support"
for name in commandLineParams():
  let (pub, sec) = curveKeypair()
  writeFile(name & ".pub", pub)
  writeFile(name & ".key", sec)
EOF
(cd "$D" && nim c -r --hints:off --warnings:off "$GEN/gen.nim" $missing > /dev/null)
echo "generated $D/:$missing"
