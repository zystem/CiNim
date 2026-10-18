#!/bin/sh
# Compiles one binary of the platform as a static executable: tools/image/build-static.sh <output> <source.nim> [more flags of nim]. The flags every binary has are here, the rest
# (the libraries to link, -d:ssl, -d:shimLogging ...) are the component's own, in its Dockerfile. Run in an image of tools/image/Dockerfile.deps with the tree in /src.
set -eu
out=$1; src=$2; shift 2
cd /src
tools/proto/nim_flatten.sh build/nimproto >/dev/null
exec nim c -d:release ${CINIM_NIM_FLAGS:-} --opt:size --hints:off --warnings:off --dynlibOverride:zmq --passC:-ffunction-sections --passC:-fdata-sections --passL:-Wl,--gc-sections --passL:-static "$@" -o:"$out" "$src"
