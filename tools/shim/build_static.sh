#!/bin/bash
# Builds the log-streaming shim (src/shim/shim.nim -d:shimLogging) as a fully static musl binary with
# libzmq + libsodium linked in, so it runs in any step image with no libzmq present (A.6's
# dependency-free-shim property, kept; D-24's CURVE transport, kept). Usage:
#   tools/shim/build_static.sh [OUT=build/cicd-shim-logging-static] [SRC=src/shim/shim.nim] [NIM_FLAGS=-d:shimLogging] [PACK=1]
# Any other ZeroMQ-linked service builds the same way, e.g. core (no UPX needed, no ConfigMap limit):
#   tools/shim/build_static.sh build/core-static src/core/main.nim "" 0
#
# Why a container: libzmq is C++, and the host's musl-gcc has no musl-built libstdc++. Alpine is musl
# end to end (g++, libstdc++.a), so libsodium, libzmq and the final link all happen there. The Nim side
# needs nothing special: `--dynlibOverride:zmq` makes the nim-zmq bindings call the symbols directly
# instead of dlopen()ing libzmq.so at startup, and the static archives satisfy them.
# The result is UPX-packed to fit a ConfigMap (see below).
# Uses the already-pulled nimlang/nim alpine image (same Nim as the host) and the host's nimble packages.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-build/cicd-shim-logging-static}"
SRC="${2:-src/shim/shim.nim}"
NIMFLAGS="${3--d:shimLogging}"
PACK="${4:-1}"
PREFIX="$PWD/build/zmq-static"
IMAGE="${SHIM_BUILD_IMAGE:-nimlang/nim:2.2.4-alpine}"
mkdir -p "$PREFIX" "$(dirname "$OUT")"
tools/proto/nim_flatten.sh build/nimproto > /dev/null

docker run --rm -v "$PWD:/src" -v "$HOME/.nimble/pkgs2:/root/.nimble/pkgs2:ro" -w /src \
  -e PREFIX=/src/build/zmq-static -e OUT="/src/$OUT" -e SRC="$SRC" -e NIMFLAGS="$NIMFLAGS" -e PACK="$PACK" -e HOSTUID="$(id -u)" -e HOSTGID="$(id -g)" \
  "$IMAGE" sh -euc '
  apk add --no-cache upx g++ make cmake git autoconf automake libtool linux-headers >/dev/null
  if [ ! -f "$PREFIX/lib/libzmq.a" ]; then
    W=$(mktemp -d); cd "$W"
    git clone -q --depth 1 --branch 1.0.20-RELEASE https://github.com/jedisct1/libsodium sodium
    (cd sodium && ./autogen.sh >/dev/null 2>&1 && ./configure --prefix="$PREFIX" --disable-shared --enable-static --enable-minimal >/dev/null && make -j"$(nproc)" install >/dev/null)
    git clone -q --depth 1 --branch v4.3.5 https://github.com/zeromq/libzmq zmq
    cmake -S zmq -B zmq/b -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DWITH_LIBSODIUM=ON -DWITH_LIBSODIUM_STATIC=ON -DENABLE_CURVE=ON -DBUILD_SHARED=OFF -DBUILD_STATIC=ON \
      -DBUILD_TESTS=OFF -DWITH_DOCS=OFF -DWITH_PERFTOOL=OFF -DENABLE_DRAFTS=OFF -DCMAKE_BUILD_TYPE=MinSizeRel \
      -DCMAKE_CXX_FLAGS="-ffunction-sections -fdata-sections" -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" >/dev/null
    cmake --build zmq/b -j"$(nproc)" --target install >/dev/null
    cd /src
  fi
  nim c -d:release $NIMFLAGS --opt:size --hints:off --warnings:off --dynlibOverride:zmq \
    --passC:-ffunction-sections --passC:-fdata-sections --passL:-Wl,--gc-sections \
    --passL:-static --passL:"-L$PREFIX/lib -lzmq -lsodium -lstdc++ -lm" -o:"$OUT" "$SRC"
  strip "$OUT"
  # 1.4 MiB unpacked does not fit a ConfigMap (1 MiB limit, the A.6 delivery mechanism); UPX --lzma: ~0.5 MiB
  [ "$PACK" = 1 ] && upx --best --lzma -q "$OUT" >/dev/null
  chown "$HOSTUID:$HOSTGID" "$OUT"
  chown -R "$HOSTUID:$HOSTGID" "$PREFIX" /src/build/nimproto 2>/dev/null || true
'
ls -l "$OUT"
file "$OUT" 2>/dev/null || true
