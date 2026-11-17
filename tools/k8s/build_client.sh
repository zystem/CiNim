#!/bin/bash
# Builds the official Kubernetes C client (kubernetes-client/c) with its dependencies (libyaml, libcurl+OpenSSL) into PREFIX.
# Usage: build_client.sh PREFIX
set -e
PREFIX="$(realpath -m "${1:?prefix}")"; WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; cd "$WORK"
# Every source is fetched by the commit that is built, the comment names its tag or branch: a tag can be moved, a branch always moves, and "the newest tag" or "a head" made two builds of one
# commit of ours differ. To move a pin: look at the new source, then put its commit here (`git ls-remote <url> <tag>`; the line that ends with ^{} is the commit of an annotated tag).
fetch_commit() { git init -q "$3" && git -C "$3" fetch -q --depth 1 "$1" "$2" && git -C "$3" checkout -q FETCH_HEAD && [ "$(git -C "$3" rev-parse HEAD)" = "$2" ] || { echo "build_client: $1 $2 is not a commit (the hash of an annotated tag is not the commit: ^{})" >&2; exit 1; }; }
[ -f "$PREFIX/lib/libcurl.a" ] || {
[ -f "$PREFIX/lib/libyaml.a" ] || { fetch_commit https://github.com/yaml/libyaml 2c891fc7a770e8ba2fec34fc6b545c672beb37e6 yaml        # 0.2.5
cmake -S yaml -B yaml/b -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_TESTING=OFF -DCMAKE_INSTALL_PREFIX="$PREFIX" >/dev/null
cmake --build yaml/b -j"$(nproc)" --target install >/dev/null; }
fetch_commit https://github.com/curl/curl 3163ec065643ba20709f190111f42c3e1fe95273 curl        # curl-8_23_0
cmake -S curl -B curl/b -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCURL_USE_OPENSSL=ON \
  -DCURL_DISABLE_LDAP=ON -DCURL_USE_LIBPSL=OFF -DUSE_NGHTTP2=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBSSH=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
  -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF -DCMAKE_INSTALL_PREFIX="$PREFIX" >/dev/null
cmake --build curl/b -j"$(nproc)" --target install >/dev/null; }
[ -f "$PREFIX/lib/libwebsockets.a" ] || { fetch_commit https://github.com/warmcat/libwebsockets 3df01489ed1b24f606a48e13e892028395b48bcf lws        # the head of v4.3-stable on 2026-11-18
cmake -S lws -B lws/b -DCMAKE_BUILD_TYPE=Release -DLWS_WITH_SHARED=OFF -DLWS_WITH_STATIC=ON -DLWS_WITHOUT_TESTAPPS=ON -DLWS_WITHOUT_TEST_SERVER=ON -DLWS_WITHOUT_TEST_CLIENT=ON -DLWS_WITHOUT_TEST_PING=ON -DLWS_WITHOUT_TEST_SERVER_EXTPOLL=ON -DLWS_WITH_SSL=ON -DLWS_WITH_LIBUV=OFF -DLWS_WITH_LIBEVENT=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$PREFIX" >/dev/null
cmake --build lws/b -j"$(nproc)" --target install >/dev/null; }
fetch_commit https://github.com/kubernetes-client/c edf13194dbd50792b8ac8132d1ed7c191cecabd0 kc        # the head of the default branch on 2026-11-18 (the newest tag, v0.9.0, is older)
# K8S_STATIC=1 (tools/image/Dockerfile.deps, musl): libkubernetes as a static archive, so the controller links everything in
cmake -S kc/kubernetes -B kc/b -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  ${K8S_STATIC:+-DBUILD_STATIC_LIBS=ON} >/dev/null
cmake --build kc/b -j"$(nproc)" --target install >/dev/null
echo "installed to $PREFIX"; ls "$PREFIX/lib" | tr '\n' ' '
