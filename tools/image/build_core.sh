#!/bin/bash
# Builds the image of the shard: the static core (with TLS), in a scratch image with the CA certificates.
#   tools/image/build_core.sh <registry>/cinim:<tag>
# The binaries are built in an Alpine container (tools/shim/build_static.sh); the CA bundle comes from the same Alpine image.
set -euo pipefail
cd "$(dirname "$0")/../.."
TAG="${1:?usage: build_core.sh <image:tag>}"
CTX=build/core-image
mkdir -p "$CTX"
tools/shim/build_static.sh "$CTX/core-static" src/core/main.nim "-d:ssl" 0
docker run --rm "${SHIM_BUILD_IMAGE:-nimlang/nim:2.2.4-alpine}" sh -c 'apk add --no-cache ca-certificates >/dev/null && cat /etc/ssl/certs/ca-certificates.crt' > "$CTX/ca-certificates.crt"
docker build -f deploy/core/Dockerfile -t "$TAG" "$CTX"
