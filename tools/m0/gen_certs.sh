#!/bin/bash
# Test-only CA plus server and client certificates (mTLS spike). Not for production use.
set -e
D="$(dirname "$0")/../../tests/certs"; mkdir -p "$D"; cd "$D"
[ -f ca.pem ] && exit 0
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 3650 -subj "/CN=cinim-test-ca" 2>/dev/null
mk() { # name cn san
  openssl req -newkey rsa:2048 -nodes -keyout $1.key -out $1.csr -subj "/CN=$2" 2>/dev/null
  printf "subjectAltName=$3\nextendedKeyUsage=serverAuth,clientAuth\n" > $1.ext
  openssl x509 -req -in $1.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out $1.pem -days 3650 -extfile $1.ext 2>/dev/null
}
mk server localhost "DNS:localhost,IP:127.0.0.1"
mk client scheduler-1 "DNS:scheduler-1"
# a second CA whose client cert must be rejected
openssl req -x509 -newkey rsa:2048 -nodes -keyout rogue-ca.key -out rogue-ca.pem -days 3650 -subj "/CN=rogue-ca" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout rogue.key -out rogue.csr -subj "/CN=rogue" 2>/dev/null
openssl x509 -req -in rogue.csr -CA rogue-ca.pem -CAkey rogue-ca.key -CAcreateserial -out rogue.pem -days 3650 2>/dev/null
rm -f *.csr *.ext *.srl
