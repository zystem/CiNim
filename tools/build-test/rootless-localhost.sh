#!/bin/bash
# Builds an image with rootless BuildKit and rootless Buildah in a namespace with Pod Security `baseline`, using the `Localhost` seccomp
# profile profiles/cinim-userns.json (deploy/seccomp, A.13, Q-17): the profile must be installed on the nodes first.
#   tools/build-test/rootless-localhost.sh <registry host:port as the cluster resolves it>
# Needs a base image `base/alpine:3.20` in that (plain HTTP) registry, `user.max_user_namespaces` raised on the nodes, and KUBECTL_CONTEXT
# to pick the cluster. It creates one scratch namespace and deletes it.
set -uo pipefail
REG="${1:?registry host:port}"
K="kubectl ${KUBECTL_CONTEXT:+--context $KUBECTL_CONTEXT}"
NS=rootless-localhost
$K create namespace $NS >/dev/null
$K label namespace $NS pod-security.kubernetes.io/enforce=baseline kubernetes.io/metadata.name=$NS --overwrite >/dev/null
$K -n $NS create configmap ctx --from-literal=Dockerfile="FROM $REG/base/alpine:3.20
RUN echo built-rootless > /built && addgroup -S x && adduser -S -G x y
" >/dev/null
$K -n $NS create configmap bkcfg --from-literal=buildkitd.toml="[registry.\"$REG\"]
  http = true
  insecure = true
" >/dev/null
SEC='{runAsUser: 1000, runAsGroup: 1000, seccompProfile: {type: Localhost, localhostProfile: profiles/cinim-userns.json}}'
$K -n $NS apply -f - >/dev/null <<EOT
apiVersion: v1
kind: Pod
metadata: {name: buildkit}
spec:
  restartPolicy: Never
  securityContext: $SEC
  containers:
    - name: b
      image: moby/buildkit:rootless
      env: [{name: BUILDKITD_FLAGS, value: "--oci-worker-no-process-sandbox --config /etc/buildkit/buildkitd.toml"}]
      command: ["buildctl-daemonless.sh"]
      args: ["build","--frontend","dockerfile.v0","--local","context=/workspace","--local","dockerfile=/workspace","--output","type=image,name=$REG/bt/rootless-buildkit:t,push=true,registry.insecure=true"]
      resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 2Gi}}
      volumeMounts: [{name: ctx, mountPath: /workspace}, {name: bk, mountPath: /etc/buildkit}, {name: state, mountPath: /home/user/.local/share/buildkit}]
  volumes: [{name: ctx, configMap: {name: ctx}}, {name: bk, configMap: {name: bkcfg}}, {name: state, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata: {name: buildah}
spec:
  restartPolicy: Never
  securityContext: $SEC
  containers:
    - name: b
      image: quay.io/buildah/stable:latest
      env: [{name: HOME, value: /tmp/home}]
      command: ["sh", "-c"]
      args:
        - |
          mkdir -p /tmp/home
          buildah --storage-driver=vfs --root /tmp/root --runroot /tmp/run bud --tls-verify=false -f /workspace/Dockerfile -t $REG/bt/rootless-buildah:t /workspace || exit 1
          buildah --storage-driver=vfs --root /tmp/root --runroot /tmp/run push --tls-verify=false $REG/bt/rootless-buildah:t
      resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 2Gi}}
      volumeMounts: [{name: ctx, mountPath: /workspace}, {name: tmp, mountPath: /tmp}]
  volumes: [{name: ctx, configMap: {name: ctx}}, {name: tmp, emptyDir: {}}]
EOT
for p in buildkit buildah; do
  ph=""; for _ in $(seq 1 60); do ph=$($K -n $NS get pod $p -o jsonpath='{.status.phase}' 2>/dev/null); case "$ph" in Succeeded|Failed) break;; esac; sleep 5; done
  if [ "$ph" = Succeeded ]; then echo "$p: WORKS under the Localhost profile in a baseline namespace"
  else echo "$p: FAILED ($ph): $($K -n $NS logs $p 2>&1 | grep -iE 'error|denied|not permitted|seccomp' | head -2 | tr '\n' ' ' | cut -c1-260; $K -n $NS describe pod $p | grep -m1 -E 'Warning|Error' | cut -c1-260)"; fi
done
$K delete namespace $NS --wait=false >/dev/null
