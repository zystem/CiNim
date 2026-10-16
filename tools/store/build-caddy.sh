#!/bin/bash
# build/caddy-store: Caddy with the WebDAV module of the CiNim fork (github.com/zystem/caddy-webdav), the node of the store (docs/store.md).
# Built by xcaddy in a container; needs Docker and the network. CADDY_WEBDAV_REF is the branch or tag of the fork (default cinim-store).
set -euo pipefail
cd "$(dirname "$0")/../.."
ref="${CADDY_WEBDAV_REF:-cinim-store}"
mkdir -p build
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e GOCACHE=/tmp/gocache -e GOPATH=/tmp/gopath -e GOPROXY=direct -e XCADDY_SETCAP=0 -v "$PWD/build:/out" caddy:builder \
  xcaddy build --with "github.com/zystem/caddy-webdav@${ref}" --output /out/caddy-store
build/caddy-store version
