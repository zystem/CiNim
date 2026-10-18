#!/bin/bash
# Builds images on this machine, much faster than a build Pod for the next build after a change: the dependencies (libzmq, libsodium, the Kubernetes C client, libcurl, the nimble packages)
# are one image, `cinim-deps:local`, made once from tools/image/Dockerfile.deps; every binary is compiled in a container of it with the source mounted and the
# C files of Nim kept in build/nimcache/<binary>, so that a change recompiles what it touches and nothing else; the images are put together from tools/image/Dockerfile.local.
#   tools/image/build-local.sh <tag> [target ...]       targets: core storage conductor controller kekd-emu caddy-store   (default: core)
#   REGISTRY=<host[:port]> tools/image/build-local.sh h82 core storage     also pushes <REGISTRY>/<image>:<tag> with skopeo (plain HTTP registry, as in docs/deployment.md)
# The images are `cinim` (core), `cinim-storage`, `cinim-conductor`, `cinim-controller` (with the shim), `cinim-kekd-emu`, `cinim-store-dav` (the Caddy node; needs build/caddy-store from
# tools/store/build-caddy.sh). `FORCE_DEPS=1` makes `cinim-deps:local` again (it is also made again when cinim.nimble or tools/k8s/build_client.sh changed).
# For a release use the build Pod (tools/image/kaniko-build.sh): this image is built from the working tree as it is.
set -euo pipefail
cd "$(dirname "$0")/../.."
TAG="${1:?usage: build-local.sh <tag> [target ...]}"; shift
TARGETS=("$@"); [ ${#TARGETS[@]} -gt 0 ] || TARGETS=(core)
DEPSFILE=tools/image/Dockerfile.deps
declare -A IMAGE=([core]=cinim [storage]=cinim-storage [conductor]=cinim-conductor [controller]=cinim-controller [kekd-emu]=cinim-kekd-emu [caddy-store]=cinim-store-dav)
# the binaries of a target: the file of the component and the stage of it that compiles the binary (tools/image/Dockerfile.<component>)
declare -A BINS=([core]="core" [storage]="storage" [conductor]="conductor" [controller]="controller-static shim" [kekd-emu]="kekd-emu" [caddy-store]="")
declare -A STAGE=([core]="Dockerfile.core build" [storage]="Dockerfile.storage build" [conductor]="Dockerfile.conductor build" [controller-static]="Dockerfile.controller build-controller" [shim]="Dockerfile.controller build-shim" [kekd-emu]="Dockerfile.kekd-emu build")

# 1. the dependencies image
want=$(cat cinim.nimble tools/k8s/build_client.sh "$DEPSFILE" | sha256sum | cut -c1-16)
have=$(docker image inspect cinim-deps:local --format '{{index .Config.Labels "cinim.deps"}}' 2>/dev/null || true)
if [ "${FORCE_DEPS:-}" = 1 ] || [ "$want" != "$have" ]; then
  echo "== cinim-deps:local (libzmq, libsodium, the Kubernetes client, nimble packages: a few minutes the first time)"
  CTX=$(mktemp -d); mkdir -p "$CTX/tools/k8s"; cp cinim.nimble "$CTX/"; cp tools/k8s/build_client.sh "$CTX/tools/k8s/"
  docker build -q -f "$DEPSFILE" --label "cinim.deps=$want" -t cinim-deps:local "$CTX" >/dev/null
  rm -rf "$CTX"
fi

# 2. the binaries
stage_cmd() {   # the RUN of the stage $2 of tools/image/$1, as a shell command
  awk -v st="$2" '$0 ~ "^FROM .* AS " st "$" {on=1; next} on && /^FROM / {exit} on && /^RUN / {run=1; sub(/^RUN /, "")} on && run {print}' "tools/image/$1" | sed 's/\\$//' | tr '\n' ' '
}
build_bin() {
  local b=$1 out=build/image-out/$1
  local file stage; read -r file stage <<<"${STAGE[$b]}"
  mkdir -p "$out" "build/nimcache/$b"
  local cmd; cmd=$(stage_cmd "$file" "$stage")
  echo "== compile $b"
  docker run --rm -v "$PWD:/src" -v "$PWD/$out:/out" -w /src -e HOSTUID="$(id -u)" -e HOSTGID="$(id -g)" -e CINIM_NIM_FLAGS="--nimcache:/src/build/nimcache/$b --parallelBuild:0" cinim-deps:local sh -c "trap 'chown -R \$HOSTUID:\$HOSTGID /out /src/build/nimcache /src/build/nimproto 2>/dev/null' EXIT; rm -f /out/*; $cmd"
}
for t in "${TARGETS[@]}"; do
  [ -n "${IMAGE[$t]:-}" ] || { echo "unknown target $t"; exit 2; }
  for b in ${BINS[$t]}; do build_bin "$b"; done
done

# 3. the images
for t in "${TARGETS[@]}"; do
  ctx=build/image-ctx/$t; rm -rf "$ctx"; mkdir -p "$ctx"
  case "$t" in
    core) cp build/image-out/core/core-static build/image-out/core/ca-certificates.crt "$ctx/";;
    storage) cp build/image-out/storage/storage-static build/image-out/storage/ca-certificates.crt "$ctx/";;
    conductor) cp build/image-out/conductor/conductor-static "$ctx/";;
    controller) cp build/image-out/controller-static/controller-static build/image-out/shim/cicd-shim "$ctx/";;
    kekd-emu) cp build/image-out/kekd-emu/kekd-emu "$ctx/";;
    caddy-store) [ -x build/caddy-store ] || tools/store/build-caddy.sh; cp build/caddy-store "$ctx/";;
  esac
  echo "== image ${IMAGE[$t]}:$TAG"
  docker build -q -f tools/image/Dockerfile.local --target "$t" -t "${IMAGE[$t]}:$TAG" "$ctx" >/dev/null
  if [ -n "${REGISTRY:-}" ]; then
    skopeo copy --quiet --dest-tls-verify=false "docker-daemon:${IMAGE[$t]}:$TAG" "docker://$REGISTRY/${IMAGE[$t]}:$TAG"
    echo "   pushed $REGISTRY/${IMAGE[$t]}:$TAG"
  fi
done
