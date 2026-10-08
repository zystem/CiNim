#!/bin/bash
# Checks that a token (SmartCard-HSM through OpenSC, or SoftHSM2 as a stand-in) can do what the master key of the step secrets needs: an EC P-256 key pair
# that never leaves the token, and ECDH on it. See docs/hardware-key.md.
#   CARD_PIN=<user PIN> [MODULE=<pkcs11 library>] [KEY_ID=01] [SLOT_ARGS="--slot-index 0"] tools/hsm/card-check.sh
# It does not create or change keys: the key with KEY_ID must exist already (docs/hardware-key.md, step 4). It takes the token's public key, makes a
# throw-away key pair in software, asks the token for the shared secret with the throw-away public key and compares it with the software result.
set -euo pipefail
MODULE="${MODULE:-/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so}"
KEY_ID="${KEY_ID:-01}"
SLOT_ARGS="${SLOT_ARGS:-}"
: "${CARD_PIN:?set CARD_PIN (the user PIN) in the environment; do not put it on the command line}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
p11() { pkcs11-tool --module "$MODULE" $SLOT_ARGS "$@" 2> >(grep -v "^Using slot" >&2); }
echo "1. the token and its mechanisms"
p11 -L | sed -n 1,12p
p11 -M | grep -q "ECDH1-DERIVE" && echo "   ECDH1-DERIVE: offered" || { echo "   ECDH1-DERIVE is NOT offered: this token cannot do what is needed"; exit 1; }
echo "2. the public key $KEY_ID"
p11 -l --pin "$CARD_PIN" --read-object --type pubkey --id "$KEY_ID" -o "$T/kek.pub.der" >/dev/null
openssl ec -pubin -inform DER -in "$T/kek.pub.der" -noout -text 2>/dev/null | head -1
echo "   fingerprint (SHA-256 of the public key): $(openssl dgst -sha256 -r "$T/kek.pub.der" | cut -d' ' -f1)"
echo "3. ECDH on the token against a throw-away key"
openssl ecparam -name prime256v1 -genkey -noout -out "$T/peer.pem" 2>/dev/null
openssl ec -in "$T/peer.pem" -pubout -outform DER -out "$T/peer.pub.der" 2>/dev/null
p11 -l --pin "$CARD_PIN" --derive --mechanism ECDH1-DERIVE --id "$KEY_ID" --input-file "$T/peer.pub.der" -o "$T/shared-token.bin" >/dev/null
openssl pkeyutl -derive -inkey "$T/peer.pem" -peerkey "$T/kek.pub.der" -peerform DER -out "$T/shared-sw.bin"
if cmp -s "$T/shared-token.bin" "$T/shared-sw.bin"; then echo "   the token's shared secret equals the software one ($(wc -c < "$T/shared-token.bin") bytes): OK"; else echo "   MISMATCH"; exit 1; fi
echo "4. timing of ten ECDH operations"
s=$(date +%s.%N); for _ in $(seq 1 10); do p11 -l --pin "$CARD_PIN" --derive --mechanism ECDH1-DERIVE --id "$KEY_ID" --input-file "$T/peer.pub.der" -o "$T/x.bin" >/dev/null; done
python3 -c "import sys;print('   %.0f ms per call, including the start of pkcs11-tool and the login' % ((float(sys.argv[2])-float(sys.argv[1]))*100))" "$s" "$(date +%s.%N)"
echo "OK: this token can hold the master key of the step secrets."
