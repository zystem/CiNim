#!/bin/bash
# Builds mbedTLS and NNG (static) into a prefix. Usage: build_deps.sh PREFIX [musl]
# `musl` uses musl-gcc so that binaries linked against the result can be fully static.
set -e
PREFIX="$(realpath -m "${1:?prefix}")"; WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MBED_TAG=mbedtls-3.6.2; NNG_TAG=v1.12.4
[ "$2" = "musl" ] && export CC=musl-gcc
cd "$WORK"
git clone -q --depth 1 --branch $MBED_TAG https://github.com/Mbed-TLS/mbedtls mbedtls
git -C mbedtls submodule update -q --init --depth 1
# NNG handshakes run on several threads: mbedTLS 3.6 (PSA state) needs its threading support (spike 6 finding)
python3 mbedtls/scripts/config.py --file mbedtls/include/mbedtls/mbedtls_config.h set MBEDTLS_THREADING_C
python3 mbedtls/scripts/config.py --file mbedtls/include/mbedtls/mbedtls_config.h set MBEDTLS_THREADING_PTHREAD
cmake -S mbedtls -B mbedtls/b -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_POSITION_INDEPENDENT_CODE=ON > /dev/null
cmake --build mbedtls/b -j"$(nproc)" --target install > /dev/null
git clone -q --depth 1 --branch $NNG_TAG https://github.com/nanomsg/nng nng
cmake -S nng -B nng/b -DNNG_ENABLE_TLS=ON -DNNG_TLS_ENGINE=mbed -DCMAKE_PREFIX_PATH="$PREFIX" -DNNG_TESTS=OFF \
  -DNNG_TOOLS=OFF -DNNG_ENABLE_NNGCAT=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" > /dev/null
cmake --build nng/b -j"$(nproc)" --target install > /dev/null
echo "installed to $PREFIX: $(ls "$PREFIX"/lib/libnng.a)"
