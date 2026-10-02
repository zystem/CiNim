#!/bin/bash
# Builds libsodium and libzmq (shared) into a prefix. Usage: build_deps.sh PREFIX
# Shared, not static: the `zmq` Nim package (src/common's dependency, see cinim.nimble) loads libzmq via
# dlopen() at runtime (zmqdll = "libzmq.so(.4|.5|)" in zmq/bindings.nim) - that is the package's own
# design, not a choice made here, and it means a static .a cannot satisfy it regardless of how libzmq
# itself is built (see A.4). Whatever runs core/job-controller/
# executor-service needs this libzmq.so (and libsodium's, if not statically folded into it) on its
# library path at runtime - e.g. LD_LIBRARY_PATH=$PREFIX/lib, or installed into a container image.
set -e
PREFIX="$(realpath -m "${1:?prefix}")"; WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SODIUM_TAG=1.0.20-RELEASE; ZMQ_TAG=v4.3.5
cd "$WORK"
git clone -q --depth 1 --branch $SODIUM_TAG https://github.com/jedisct1/libsodium sodium
cd sodium
./autogen.sh > /dev/null 2>&1
./configure --prefix="$PREFIX" --disable-static --enable-shared > /dev/null
make -j"$(nproc)" install > /dev/null
cd "$WORK"
git clone -q --depth 1 --branch $ZMQ_TAG https://github.com/zeromq/libzmq zmq
cmake -S zmq -B zmq/b -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DWITH_LIBSODIUM=ON -DWITH_LIBSODIUM_STATIC=OFF -DENABLE_CURVE=ON \
  -DBUILD_SHARED=ON -DBUILD_STATIC=OFF -DBUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build zmq/b -j"$(nproc)" --target install > /dev/null
echo "installed to $PREFIX: $(ls "$PREFIX"/lib/libzmq.so.* | head -1), $(ls "$PREFIX"/lib/libsodium.so.* | head -1)"
echo "runtime: export LD_LIBRARY_PATH=$PREFIX/lib:\$LD_LIBRARY_PATH"
