#!/bin/sh
# Makes the keys of the shim's gRPC channels (src/common/corechannel.nim, src/core/grpcserve.nim) in DIR/tls: ca.pem (the CA, its key is not kept), core.pem and core.key (the core's server
# certificate, DNS name cinim-core, which is what the shims check), client.pem and client.key (the one identity of the shims, as curve/client.* was). EC P-256, valid for 2 years by default.
# Usage: tools/grpc/gen_tls.sh DIR [DAYS]. The core needs core.* and ca.pem; a step Pod gets ca.pem, client.pem and client.key and never core.key.
set -eu
dir=${1:?usage: gen_tls.sh DIR [DAYS]}
days=${2:-730}
out=$dir/tls
mkdir -p "$out"
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT
key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null; }
key "$w/ca.key"
openssl req -x509 -new -key "$w/ca.key" -subj "/CN=cinim shim CA" -days "$days" -out "$out/ca.pem" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
leaf() {   # name subject extfile-lines
  key "$out/$1.key"
  openssl req -new -key "$out/$1.key" -subj "$2" -out "$w/$1.csr" 2>/dev/null
  printf '%s\n' "$3" > "$w/$1.ext"
  openssl x509 -req -in "$w/$1.csr" -CA "$out/ca.pem" -CAkey "$w/ca.key" -CAserial "$w/ca.srl" -CAcreateserial -days "$days" -extfile "$w/$1.ext" -out "$out/$1.pem" 2>/dev/null
}
leaf core "/CN=cinim-core" "subjectAltName=DNS:cinim-core
extendedKeyUsage=serverAuth
keyUsage=digitalSignature"
leaf client "/CN=cinim-shim" "extendedKeyUsage=clientAuth
keyUsage=digitalSignature"
chmod 600 "$out"/*.key
