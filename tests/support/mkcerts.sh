#!/bin/sh
# Certificates for tests/unit/thsmgate_tls.nim, with the openssl command: two CAs (the service's clients' and one nobody trusts), the service's server certificate
# (127.0.0.1), a client certificate of the right CA with the name the service knows (core.crt), one with a name it does not know (stranger.crt) and one from the other CA (rogue.crt).
set -eu
d=$1
mkdir -p "$d"
cd "$d"
ec() { openssl ecparam -name prime256v1 -genkey -noout -out "$1" 2>/dev/null; }
ca() { ec "$1.key"; openssl req -x509 -new -key "$1.key" -subj "/CN=$1" -days 2 -out "$1.crt" 2>/dev/null; }
leaf() {  # name, subject, ca, extension
  ec "$1.key"
  openssl req -new -key "$1.key" -subj "/CN=$2" -out "$1.csr" 2>/dev/null
  printf '%s\n' "$4" > "$1.ext"
  openssl x509 -req -in "$1.csr" -CA "$3.crt" -CAkey "$3.key" -CAcreateserial -days 2 -extfile "$1.ext" -out "$1.crt" 2>/dev/null
}
ca clients-ca
ca server-ca
ca rogue-ca
leaf server hsmgate server-ca "subjectAltName=IP:127.0.0.1
extendedKeyUsage=serverAuth"
leaf core core clients-ca "extendedKeyUsage=clientAuth"
leaf stranger stranger clients-ca "extendedKeyUsage=clientAuth"
leaf rogue core rogue-ca "extendedKeyUsage=clientAuth"
