#!/bin/bash
# Test-only CURVE keypairs for the ZeroMQ transport. Not for production use: a real deployment needs its own key issuance/
# distribution (e.g. Kubernetes Secrets), not files checked into a test fixture directory.
set -e
D="$(dirname "$0")/../../tests/certs/curve"; mkdir -p "$D"
# .pub files are tracked in git, .key files are gitignored (see .gitignore) - on a fresh checkout the
# .pub half exists but the .key half does not, so checking core.pub alone would wrongly skip
# regeneration and leave no secret keys at all. Check all four.
[ -f "$D/core.pub" ] && [ -f "$D/core.key" ] && [ -f "$D/client.pub" ] && [ -f "$D/client.key" ] && exit 0
GEN="$(mktemp -d)"; trap 'rm -rf "$GEN"' EXIT
cat > "$GEN/gen.nim" <<'EOF'
import zmq
doAssert hasCurve(), "libzmq was not built with CURVE (libsodium) support"
for name in ["core", "client"]:
  let (pub, sec) = curveKeypair()
  writeFile(name & ".pub", pub)
  writeFile(name & ".key", sec)
EOF
(cd "$D" && nim c -r --hints:off --warnings:off "$GEN/gen.nim" > /dev/null)
echo "generated $D/{core,client}.{pub,key}"
