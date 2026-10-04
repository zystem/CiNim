#!/bin/bash
# Builds the image of the job controller: the static controller (the official Kubernetes C client, libcurl, libwebsockets, libyaml and
# OpenSSL linked in, with ZeroMQ, libsodium and SQLite) and the static log-streaming shim, in a scratch image.
#   tools/image/build_controller.sh <registry>/cinim-controller:<tag>
set -euo pipefail
cd "$(dirname "$0")/../.."
TAG="${1:?usage: build_controller.sh <image:tag>}"
CTX=build/controller-image
IMAGE="${SHIM_BUILD_IMAGE:-nimlang/nim:2.2.4-alpine}"
mkdir -p "$CTX" build/k8s-static
tools/shim/build_static.sh "$CTX/cicd-shim" src/shim/shim.nim "-d:shimLogging" 1     # also builds libzmq and libsodium into build/zmq-static
docker run --rm -v "$PWD:/src" -v "$HOME/.nimble/pkgs2:/root/.nimble/pkgs2:ro" -w /src \
  -e ZMQ=/src/build/zmq-static -e K8S=/src/build/k8s-static -e HOSTUID="$(id -u)" -e HOSTGID="$(id -g)" "$IMAGE" sh -euc '
  apk add --no-cache bash coreutils g++ make cmake git linux-headers openssl-dev openssl-libs-static zlib-dev zlib-static sqlite-dev sqlite-static >/dev/null
  [ -f "$K8S/lib/libkubernetes.a" ] || K8S_STATIC=1 tools/k8s/build_client.sh "$K8S" >/dev/null
  nim c -d:release --opt:size --hints:off --warnings:off -d:k8sPrefix="$K8S" -d:k8sStatic --dynlibOverride:zmq --dynlibOverride:sqlite3 \
    --passC:-ffunction-sections --passC:-fdata-sections --passL:-Wl,--gc-sections --passL:-static \
    --passL:"-L$ZMQ/lib -lzmq -lsodium -lsqlite3 -lstdc++ -lm" -o:/src/build/controller-image/controller-static src/jobcontroller/main.nim
  strip /src/build/controller-image/controller-static
  chown -R "$HOSTUID:$HOSTGID" /src/build/controller-image /src/build/k8s-static /src/build/nimproto 2>/dev/null || true'
docker build -f deploy/controller/Dockerfile -t "$TAG" "$CTX"
