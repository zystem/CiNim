#!/bin/bash
# Image builders against each other on one workload (A.13, Q-17): Kaniko, rootless BuildKit and rootless Buildah (with vfs, and with the native overlay if it works) as
# build Pods on the same node, each doing the same three builds of the Dockerfile next to this file:
#   a  cold, no cache                      b  cold, exporting the cache to the registry                 c  the last layer changed, importing the cache from the registry
# and printing the seconds each container ran (from its start to its end, the image pull and the generation of the context not counted).
#   KUBECTL="kubectl --kubeconfig ... --tls-server-name=..."  REGISTRY=<host:port as the Pods reach it, plain HTTP>  [NS=bench-builders] [TOOLS="kaniko ..."] [FILES=40000] ./bench.sh
# This is about speed, not about the admission policy of the build profile (D-42): the namespace has none, and BuildKit and Buildah run with Unconfined seccomp and AppArmor profiles (the node's AppArmor stops a user namespace in a container otherwise).
set -uo pipefail
cd "$(dirname "$0")"
K="${KUBECTL:-kubectl}"
REG="${REGISTRY:?registry host:port as the Pods reach it, plain HTTP}"
NS="${NS:-bench-builders}"
TOOLS="${TOOLS:-kaniko kaniko-tuned buildkit buildah-vfs buildah-overlay}"
DIRS="${DIRS:-200}"; PER="${PER:-200}"          # DIRS x PER small files (40 000 by default)
KANIKO="${KANIKO_IMAGE:-ghcr.io/osscontainertools/kaniko:v1.28.5@sha256:738807f0e31daf07743f89260a95956dcc6ee4f62553f4f6344c990cabab8675}"
BUILDKIT="${BUILDKIT_IMAGE:-moby/buildkit:rootless}"
BUILDAH="${BUILDAH_IMAGE:-quay.io/buildah/stable:latest}"
OUT="${OUT:-/tmp/bench-builders.txt}"
BLOB1="${BLOB1:-150000000}"; BLOB2="${BLOB2:-100000000}"
$K get ns $NS >/dev/null 2>&1 || $K create ns $NS >/dev/null
$K -n $NS create configmap dockerfile --from-file=Dockerfile --dry-run=client -o yaml | $K -n $NS apply -f - >/dev/null
$K -n $NS create configmap bkcfg --from-literal=buildkitd.toml="[registry.\"$REG\"]
  http = true
  insecure = true
" --dry-run=client -o yaml | $K -n $NS apply -f - >/dev/null
# the Pod's user namespace has the ids 0..65535, the image's /etc/subuid names 100000..165535: a range inside the Pod's own (build-pods/README.md, "Things that cost time")
$K -n $NS create configmap subid --from-literal=subuid="user:2000:60000" --from-literal=subgid="user:2000:60000" --dry-run=client -o yaml | $K -n $NS apply -f - >/dev/null

pod() { # name  main-container-yaml  extra-volume-mounts-yaml-indented  volumes-extra
cat <<EOT
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $NS}
spec:
  restartPolicy: Never
  hostUsers: $HU
  securityContext: {$5}
  initContainers:
    - name: ctx
      image: alpine:3.20
      securityContext: {runAsUser: 0}
      command: ["sh", "-c"]
      args:
        - |
          cp /df/Dockerfile /workspace/Dockerfile
          mkdir -p /workspace/tree && cd /workspace/tree
          i=0; while [ \$i -lt $DIRS ]; do mkdir d\$i; j=0; while [ \$j -lt $PER ]; do echo "\$i-\$j-\$(( i * j ))" > d\$i/f\$j; j=\$((j+1)); done; i=\$((i+1)); done
          head -c $BLOB1 /dev/urandom > /workspace/blob1.bin
          head -c $BLOB2 /dev/zero > /workspace/blob2.bin
          chmod -R a+rwX /workspace
      volumeMounts: [{name: ctx, mountPath: /workspace}, {name: df, mountPath: /df}]
  containers:
    - name: main
$2
      resources: {requests: {cpu: "2"}, limits: {cpu: "8", memory: 8Gi}}
      volumeMounts:
        - {name: ctx, mountPath: /workspace}
$3
  volumes:
    - {name: ctx, emptyDir: {}}
    - {name: df, configMap: {name: dockerfile}}
$4
EOT
}

# $1 tool  $2 scenario (a|b|c)  -> the yaml of the Pod
build_pod() {
  local tool=$1 sc=$2 name="b-$1-$2" tag="$REG/bench/$1:$2" cache="$REG/bench/$1-cache" rev=1
  [ "$sc" = c ] && rev=2
  HU=false
  case $tool in
    kaniko|kaniko-tuned)
      local extra=""
      [ $tool = kaniko-tuned ] && extra=', "--snapshot-mode=redo", "--use-new-run", "--compressed-caching=false"'
      [ $sc != a ] && extra="$extra"', "--cache=true", "--cache-repo='$cache'"'
      pod $name "      image: $KANIKO
      args: [\"--dockerfile=/workspace/Dockerfile\", \"--context=dir:///workspace\", \"--destination=$tag\", \"--insecure\", \"--insecure-pull\", \"--build-arg=REV=$rev\"$extra]
      securityContext: {capabilities: {drop: [ALL], add: [CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, SETFCAP]}}" "" "" "runAsUser: 0, seccompProfile: {type: RuntimeDefault}";;
    buildkit|buildkit-overlayfs|buildkit-native)
      local cacheopts="" snap=""
      [ $tool = buildkit-overlayfs ] && snap=" --oci-worker-snapshotter=overlayfs"
      [ $tool = buildkit-native ] && snap=" --oci-worker-snapshotter=native"
      [ $sc != a ] && cacheopts=', "--export-cache", "type=registry,ref='$cache',mode=max,registry.insecure=true"'
      [ $sc = c ] && cacheopts="$cacheopts"', "--import-cache", "type=registry,ref='$cache',registry.insecure=true"'
      pod $name "      image: $BUILDKIT
      env: [{name: BUILDKITD_FLAGS, value: \"--oci-worker-no-process-sandbox --config /etc/buildkit/buildkitd.toml$snap${BUILDKITD_EXTRA:+ $BUILDKITD_EXTRA}\"}]
      command: [\"buildctl-daemonless.sh\"]
      args: [\"build\", \"--frontend\", \"dockerfile.v0\", \"--local\", \"context=/workspace\", \"--local\", \"dockerfile=/workspace\", \"--opt\", \"build-arg:REV=$rev\", \"--output\", \"type=image,name=$tag,push=true,registry.insecure=true\"$cacheopts]" "        - {name: cfg, mountPath: /etc/buildkit}
        - {name: state, mountPath: /home/user/.local/share/buildkit}
        - {name: subid, mountPath: /etc/subuid, subPath: subuid}
        - {name: subid, mountPath: /etc/subgid, subPath: subgid}" "    - {name: cfg, configMap: {name: bkcfg}}
    - {name: state, emptyDir: {}}
    - {name: subid, configMap: {name: subid}}" "runAsUser: 1000, runAsGroup: 1000, seccompProfile: {type: Unconfined}, appArmorProfile: {type: Unconfined}";;
    buildkit-rootful)
      # as a CI agent usually runs it: a privileged Pod, root, the image's buildkitd with its own overlayfs, the state on an emptyDir (the namespace has no admission policy)
      local cacheopts=""
      [ $sc != a ] && cacheopts=', "--export-cache", "type=registry,ref='$cache',mode=max,registry.insecure=true"'
      [ $sc = c ] && cacheopts="$cacheopts"', "--import-cache", "type=registry,ref='$cache',registry.insecure=true"'
      HU=true
      pod $name "      image: ${BUILDKIT_ROOTFUL_IMAGE:-moby/buildkit:latest}
      securityContext: {privileged: true, runAsUser: 0}
      env: [{name: BUILDKITD_FLAGS, value: \"--config /etc/buildkit/buildkitd.toml\"}]
      command: [\"buildctl-daemonless.sh\"]
      args: [\"build\", \"--frontend\", \"dockerfile.v0\", \"--local\", \"context=/workspace\", \"--local\", \"dockerfile=/workspace\", \"--opt\", \"build-arg:REV=$rev\", \"--output\", \"type=image,name=$tag,push=true,registry.insecure=true\"$cacheopts]" "        - {name: cfg, mountPath: /etc/buildkit}
        - {name: state, mountPath: /var/lib/buildkit}" "    - {name: cfg, configMap: {name: bkcfg}}
    - {name: state, emptyDir: {}}" "runAsUser: 0";;
    buildah-rootful-vfs|buildah-rootful-overlay)
      # as a CI agent usually runs it: privileged, root, `--isolation=chroot`, the storage on an emptyDir
      local drv=vfs; [ $tool = buildah-rootful-overlay ] && drv=overlay
      local lay=""; [ $sc != a ] && lay="--layers --cache-to $cache"
      [ $sc = c ] && lay="$lay --cache-from $cache"
      HU=true
      pod $name "      image: $BUILDAH
      securityContext: {privileged: true, runAsUser: 0}
      command: [\"sh\", \"-c\"]
      args:
        - |
          buildah --storage-driver=$drv bud --tls-verify=false --isolation=chroot $lay --build-arg REV=$rev -f /workspace/Dockerfile -t $tag /workspace || exit 1
          buildah --storage-driver=$drv push --tls-verify=false $tag" "        - {name: store, mountPath: /var/lib/containers}" "    - {name: store, emptyDir: {}}" "runAsUser: 0";;
    buildah-vfs|buildah-overlay)
      local drv=vfs; [ $tool = buildah-overlay ] && drv=overlay
      local lay=""; [ $sc != a ] && lay="--layers --cache-to $cache"
      [ $sc = c ] && lay="$lay --cache-from $cache"
      pod $name "      image: $BUILDAH
      env: [{name: HOME, value: /tmp/home}]
      command: [\"sh\", \"-c\"]
      args:
        - |
          mkdir -p /tmp/home
          buildah --storage-driver=$drv --root /tmp/root --runroot /tmp/run bud --tls-verify=false $lay --build-arg REV=$rev -f /workspace/Dockerfile -t $tag /workspace || exit 1
          buildah --storage-driver=$drv --root /tmp/root --runroot /tmp/run push --tls-verify=false $tag" "        - {name: tmp, mountPath: /tmp}" "    - {name: tmp, emptyDir: {}}" "runAsUser: 1000, runAsGroup: 1000, seccompProfile: {type: Unconfined}, appArmorProfile: {type: Unconfined}";;
  esac
}

run() {
  local tool=$1 sc=$2 name="b-$1-$2"
  $K -n $NS delete pod $name --ignore-not-found --wait=true >/dev/null 2>&1
  if ! build_pod $tool $sc | $K apply -f - >/dev/null 2>/tmp/bench-apply.err; then echo "$tool $sc: REFUSED: $(head -1 /tmp/bench-apply.err | cut -c1-200)" | tee -a $OUT; return; fi
  local ph=""
  for _ in $(seq 1 600); do ph=$($K -n $NS get pod $name -o jsonpath='{.status.phase}' 2>/dev/null); case "$ph" in Succeeded|Failed) break;; esac; sleep 5; done
  local s e secs
  s=$($K -n $NS get pod $name -o jsonpath='{.status.containerStatuses[0].state.terminated.startedAt}' 2>/dev/null)
  e=$($K -n $NS get pod $name -o jsonpath='{.status.containerStatuses[0].state.terminated.finishedAt}' 2>/dev/null)
  if [ -n "$s" ] && [ -n "$e" ]; then secs=$(( $(date -d "$e" +%s) - $(date -d "$s" +%s) )); else secs=-1; fi
  printf '%-16s %s  %-9s %5s s\n' "$tool" "$sc" "$ph" "$secs" | tee -a $OUT
  if [ "$ph" != Succeeded ]; then $K -n $NS logs $name -c main 2>&1 | tail -4 | cut -c1-200 | sed 's/^/    /' | tee -a $OUT; fi
  if [ -n "${VERBOSE:-}" ]; then $K -n $NS logs $name -c main 2>&1 | grep -iE 'snapshotter|overlay|native|fuse|using' | head -8 | cut -c1-200 | sed 's/^/    log: /' | tee -a $OUT; fi
  $K -n $NS delete pod $name --wait=false >/dev/null 2>&1
}

echo "== $(date -u +%FT%TZ) $DIRS x $PER small files + 250 MB, registry $REG" | tee -a $OUT
for tool in $TOOLS; do for sc in ${SCENARIOS:-a b c}; do run $tool $sc; done; done
echo "== done" | tee -a $OUT
