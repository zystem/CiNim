#!/bin/bash
# Builds the log-streaming shim (src/shim/shim.nim -d:shimLogging) as a fully static musl binary with
# nghttp2 (gRPC, docs/shim-grpc.md) and zlib linked in, so it runs in any step image (A.6's dependency-free-shim
# property). Usage:
#   tools/shim/build_static.sh [OUT=build/cicd-shim-logging-static] [SRC=src/shim/shim.nim] [NIM_FLAGS=-d:shimLogging] [PACK=1]
# Any other service of the platform builds the same way, e.g. core (no UPX needed, no ConfigMap limit; -d:ssl links OpenSSL in, libsodium is linked for the secrets):
#   tools/shim/build_static.sh build/core-static src/core/main.nim "-d:ssl" 0
#
# Why a container: Alpine is musl end to end, so libsodium, nghttp2 and the final link all happen there. The packages of nimble (nimgrpc, bearssl, chronos ...) are the host's `~/.nimble/pkgs2`
# (`nimble install -d` in the repository). The result is UPX-packed to fit a ConfigMap (see below).
# Uses the Nim of the image given by SHIM_BUILD_IMAGE (the one of the platform: github.com/zystem/nim-alpine) and the host's nimble packages.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-build/cicd-shim-logging-static}"
SRC="${2:-src/shim/shim.nim}"
NIMFLAGS="${3--d:shimLogging}"
PACK="${4:-1}"
PREFIX="$PWD/build/static-deps"
IMAGE="${SHIM_BUILD_IMAGE:-ghcr.io/zystem/nim:2.2.12-alpine}"
mkdir -p "$PREFIX" "$(dirname "$OUT")"
tools/proto/nim_flatten.sh build/nimproto > /dev/null

docker run --rm -v "$PWD:/src" -v "$HOME/.nimble/pkgs2:/root/.nimble/pkgs2:ro" -w /src \
  -e PREFIX=/src/build/static-deps -e OUT="/src/$OUT" -e SRC="$SRC" -e NIMFLAGS="$NIMFLAGS" -e PACK="$PACK" -e HOSTUID="$(id -u)" -e HOSTGID="$(id -g)" \
  "$IMAGE" sh -euc '
  apk add --no-cache upx g++ make cmake git curl xz autoconf automake libtool linux-headers zlib-dev zlib-static >/dev/null
  # -d:ssl (TLS clients such as the core calling a router over https): a static OpenSSL 3, linked in instead of dlopen()ed
  SSL_LIBS=""; SSL_NIM=""
  case "$NIMFLAGS" in *-d:ssl*)
    apk add --no-cache openssl-dev openssl-libs-static >/dev/null
    SSL_LIBS="-lssl -lcrypto"; SSL_NIM="-d:useOpenssl3 --dynlibOverride:ssl --dynlibOverride:crypto";;
  esac
  # renovate: datasource=github-releases depName=nghttp2/nghttp2 extractVersion=^v(?<version>.+)$
  NGHTTP2_VERSION=1.68.0
  if [ ! -f "$PREFIX/lib/libnghttp2.a" ] || [ ! -f "$PREFIX/lib/libsodium.a" ]; then
    W=$(mktemp -d); cd "$W"
    git clone -q --depth 1 --branch 1.0.20-RELEASE https://github.com/jedisct1/libsodium sodium
    (cd sodium && ./autogen.sh >/dev/null 2>&1 && ./configure --prefix="$PREFIX" --disable-shared --enable-static --enable-minimal >/dev/null && make -j"$(nproc)" install >/dev/null)
    curl -fsSL "https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.xz" | tar xJ
    cmake -S "nghttp2-${NGHTTP2_VERSION}" -B ng -DENABLE_LIB_ONLY=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DCMAKE_BUILD_TYPE=MinSizeRel \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" >/dev/null
    cmake --build ng -j"$(nproc)" --target install >/dev/null
    cd /src
  fi
  nim c -d:release $NIMFLAGS --opt:size --hints:off --warnings:off $SSL_NIM -d:nghttp2Prefix="$PREFIX" -d:zlibStatic -d:zlibLib=/usr/lib/libz.a \
    --passC:-ffunction-sections --passC:-fdata-sections --passL:-Wl,--gc-sections \
    --passL:-static --passL:"-L$PREFIX/lib -lsodium $SSL_LIBS -lm" -o:"$OUT" "$SRC"
  strip "$OUT"
  # 1.4 MiB unpacked does not fit a ConfigMap (1 MiB limit, the A.6 delivery mechanism); UPX --lzma: ~0.5 MiB
  [ "$PACK" = 1 ] && upx --best --lzma -q "$OUT" >/dev/null
  chown "$HOSTUID:$HOSTGID" "$OUT"
  chown -R "$HOSTUID:$HOSTGID" "$PREFIX" /src/build/nimproto 2>/dev/null || true
'
ls -l "$OUT"
file "$OUT" 2>/dev/null || true
