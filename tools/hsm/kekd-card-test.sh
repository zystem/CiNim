#!/bin/bash
# Runs the real key service (build/kekd) on the real card and checks the whole way: info, wrap (no card needed), unwrap (the card's ECDH, the one login), a wrong additional
# data refused, and the audit. The PIN is read by kekd from a file that you make yourself in your own terminal; this script never sees it:
#   umask 077; read -rs -p 'PIN: ' p; echo "$p" > ~/.cinim-card-pin; unset p
#   PIN_FILE=~/.cinim-card-pin tools/hsm/kekd-card-test.sh
# The PIN is tried once: if the card refuses it (3 wrong tries block the card) kekd stays locked and this script fails without trying again. Remove the PIN file afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${PIN_FILE:?set PIN_FILE to a file that holds the user PIN}"
KEY_ID="${KEY_ID:-5ded83a1871a7f6f79cd33ae681b2f5ce9c2fe81}"
PORT="${PORT:-18794}"
[ -x build/kekd ] || nim c --hints:off --warnings:off -p:src -o:build/kekd src/kekd/main.nim
T=$(mktemp -d)
trap 'kill "$PID" 2>/dev/null || true; rm -rf "$T"' EXIT
build/kekd --key-id "$KEY_ID" --pin-file "$PIN_FILE" --port "$PORT" --audit-file "$T/audit" > "$T/out" 2>&1 &
PID=$!
sleep 2
cat "$T/out"
U="http://127.0.0.1:$PORT"
DEK=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
AAD='cinim/dek/v1|card-test'
echo "1. info:   $(curl -s "$U/v1/info")"
W=$(curl -s -XPOST "$U/v1/wrap" -d "{\"plain\":\"$DEK\",\"aad\":\"$AAD\"}" | sed -n 's/.*"wrapped":"\([^"]*\)".*/\1/p')
[ -n "$W" ] || { echo "wrap failed"; exit 1; }
echo "2. wrapped: ${W:0:40}... (${#W} characters; it does not contain the data key: $([[ "$W" != *"$DEK"* ]] && echo yes || echo NO))"
S=$(date +%s.%N)
R=$(curl -s -w ' %{http_code}' -XPOST "$U/v1/unwrap" -d "{\"wrapped\":\"$W\",\"aad\":\"$AAD\"}")
E=$(date +%s.%N)
echo "3. unwrap on the card: $(python3 -c "import sys;print('%.0f ms' % ((float(sys.argv[2])-float(sys.argv[1]))*1000))" "$S" "$E"), answer ${R##* }"
if [ "$R" = "{\"plain\":\"$DEK\"} 200" ]; then echo "   the data key came back equal: OK"; else echo "   NOT EQUAL or refused: ${R:0:80}"; echo "   info now: $(curl -s "$U/v1/info")"; exit 1; fi
echo "4. another additional data:  $(curl -s -w ' %{http_code}' -XPOST "$U/v1/unwrap" -d "{\"wrapped\":\"$W\",\"aad\":\"cinim/dek/v1|other\"}")   (422 damaged expected)"
echo "5. not a data key's own:     $(curl -s -w ' %{http_code}' -XPOST "$U/v1/unwrap" -d "{\"wrapped\":\"$W\",\"aad\":\"nope\"}")   (422 bad_aad expected)"
echo "6. ten unwraps in a row on the card:"
S=$(date +%s.%N)
for _ in $(seq 1 10); do curl -s -XPOST "$U/v1/unwrap" -d "{\"wrapped\":\"$W\",\"aad\":\"$AAD\"}" | grep -q "\"plain\":\"$DEK\"" || { echo "   one failed"; exit 1; }; done
python3 -c "import sys;print('   %.0f ms per unwrap' % ((float(sys.argv[2])-float(sys.argv[1]))*100))" "$S" "$(date +%s.%N)"
echo "7. the audit (no key in it):"; sed 's/^/   /' "$T/audit"
grep -q "$DEK" "$T/audit" && { echo "   THE KEY IS IN THE AUDIT"; exit 1; }
echo "OK: the key service works on this card."
