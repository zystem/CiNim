#!/bin/bash
# Checks that an RSA key on the token can open what is sealed to it with RSA-OAEP, the way the PKCS#11 seal of OpenBao uses it: the encryption is done in software with the
# public key (as OpenBao does), the decryption on the token. Tries SHA-256 (the default of OpenBao's `rsa_oaep_hash`), then SHA-1.
#   [MODULE=<pkcs11 library>] [KEY_ID=<CKA_ID of the RSA key>] tools/hsm/rsa-oaep-check.sh
# The PIN: in a terminal pkcs11-tool asks for it itself (once per decryption, so up to two times); without a terminal set PIN_FILE to a file that holds it (it is then an argument of
# pkcs11-tool for a moment, as in card-check.sh). Three wrong PINs block the card.
set -euo pipefail
MODULE="${MODULE:-/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so}"
KEY_ID="${KEY_ID:-caa2194c51acc24adee0d46169c296eb2953a1e8}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PIN_ARGS=(); [ -z "${PIN_FILE:-}" ] || PIN_ARGS=(--pin "$(tr -d '\r\n' < "$PIN_FILE")")
p11() { pkcs11-tool --module "$MODULE" "$@"; }       # stderr is left alone: the PIN prompt needs the terminal
p11 --read-object --type pubkey --id "$KEY_ID" -o "$T/pub.der" >/dev/null 2>&1
openssl pkey -pubin -inform DER -in "$T/pub.der" -out "$T/pub.pem"
echo "key: $(openssl pkey -pubin -in "$T/pub.pem" -noout -text | head -1), fingerprint $(openssl dgst -sha256 -r "$T/pub.der" | cut -d' ' -f1)"
head -c 32 /dev/urandom > "$T/plain.bin"
for H in sha256 sha1; do
  openssl pkeyutl -encrypt -pubin -inkey "$T/pub.pem" -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:$H -pkeyopt rsa_mgf1_md:$H -in "$T/plain.bin" -out "$T/ct.$H.bin"
  M=$(echo $H | tr a-z A-Z); G=$M; [ "$H" = sha1 ] && M=SHA-1 G=SHA1       # the hash is called SHA-1 in pkcs11-tool, its MGF1-SHA1
  echo "OAEP with $H: decrypt on the token (the PIN is asked for)"
  s=$(date +%s.%N)
  if p11 -l "${PIN_ARGS[@]}" --decrypt --id "$KEY_ID" --mechanism RSA-PKCS-OAEP --hash-algorithm "$M" --mgf "MGF1-$G" -i "$T/ct.$H.bin" -o "$T/out.$H.bin" >/dev/null; then
    if cmp -s "$T/plain.bin" "$T/out.$H.bin"; then echo "   $H: the token returned the same 32 bytes ($(python3 -c "import sys;print('%.0f ms' % ((float(sys.argv[2])-float(sys.argv[1]))*1000))" "$s" "$(date +%s.%N)")): OK"; else echo "   $H: the bytes differ"; fi
  else
    echo "   $H: the token or the module refused (see the message above)"
  fi
done
