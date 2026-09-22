#!/bin/bash
# Builds the official Kubernetes C client (kubernetes-client/c) with its dependencies (libyaml, libcurl+OpenSSL) into PREFIX.
# Usage: build_client.sh PREFIX
set -e
PREFIX="$(realpath -m "${1:?prefix}")"; WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; cd "$WORK"
[ -f "$PREFIX/lib/libcurl.a" ] || { CURL_TAG=$(git ls-remote --tags --refs https://github.com/curl/curl | awk -F/ '{print $NF}' | grep -E '^curl-[0-9]+_[0-9]+_[0-9]+$' | sort -V | tail -1)
[ -f "$PREFIX/lib/libyaml.a" ] || { git clone -q --depth 1 --branch 0.2.5 https://github.com/yaml/libyaml yaml
cmake -S yaml -B yaml/b -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_TESTING=OFF -DCMAKE_INSTALL_PREFIX="$PREFIX" >/dev/null
cmake --build yaml/b -j"$(nproc)" --target install >/dev/null; }
git clone -q --depth 1 --branch "$CURL_TAG" https://github.com/curl/curl curl
cmake -S curl -B curl/b -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCURL_USE_OPENSSL=ON \
  -DCURL_DISABLE_LDAP=ON -DCURL_USE_LIBPSL=OFF -DUSE_NGHTTP2=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBSSH=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
  -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF -DCMAKE_INSTALL_PREFIX="$PREFIX" >/dev/null
cmake --build curl/b -j"$(nproc)" --target install >/dev/null; }
[ -f "$PREFIX/lib/libwebsockets.a" ] || { git clone -q --depth 1 --branch v4.3-stable https://github.com/warmcat/libwebsockets lws
cmake -S lws -B lws/b -DCMAKE_BUILD_TYPE=Release -DLWS_WITH_SHARED=OFF -DLWS_WITH_STATIC=ON -DLWS_WITHOUT_TESTAPPS=ON -DLWS_WITHOUT_TEST_SERVER=ON -DLWS_WITHOUT_TEST_CLIENT=ON -DLWS_WITHOUT_TEST_PING=ON -DLWS_WITHOUT_TEST_SERVER_EXTPOLL=ON -DLWS_WITH_SSL=ON -DLWS_WITH_LIBUV=OFF -DLWS_WITH_LIBEVENT=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$PREFIX" >/dev/null
cmake --build lws/b -j"$(nproc)" --target install >/dev/null; }
git clone -q --depth 1 https://github.com/kubernetes-client/c kc
cmake -S kc/kubernetes -B kc/b -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_POSITION_INDEPENDENT_CODE=ON >/dev/null
cmake --build kc/b -j"$(nproc)" --target install >/dev/null
echo "installed to $PREFIX"; ls "$PREFIX/lib" | tr '\n' ' '
