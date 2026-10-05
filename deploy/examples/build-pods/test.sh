#!/bin/bash
# Applies namespace.yaml and policy.yaml, then (1) builds an image with Kaniko, rootless BuildKit and rootless Buildah as build Pods made by the
# job controller's account, and (2) checks what the policy refuses. Deletes the namespace and the policy at the end.
#   REGISTRY=<registry host:port as the Pods reach it, plain HTTP>  KUBECTL_CONTEXT=<context>  ./test.sh
# Needs: Kubernetes 1.30+, user.max_user_namespaces on the nodes, the seccomp profile of deploy/seccomp on the nodes (for BuildKit and Buildah),
# and the base image `base/alpine:3.20` in REGISTRY.
set -uo pipefail
cd "$(dirname "$0")"
REG="${REGISTRY:?registry host:port as the Pods reach it}"
K="kubectl ${KUBECTL_CONTEXT:+--context $KUBECTL_CONTEXT}"
NS=org-example
AS="--as=system:serviceaccount:$NS:cinim-job-controller"
$K apply -f namespace.yaml -f policy.yaml >/dev/null
sleep 3
$K -n $NS create configmap ctx --from-literal=Dockerfile="FROM $REG/base/alpine:3.20
RUN echo built-as-a-build-pod > /built && addgroup -S x && adduser -S -G x y
" >/dev/null
$K -n $NS create configmap bkcfg --from-literal=buildkitd.toml="[registry.\"$REG\"]
  http = true
  insecure = true
" >/dev/null
# the account of the "another account" case may make Pods, so that its refusal comes from the policy and not from RBAC
$K -n $NS create rolebinding default-pods --role=step-pods --serviceaccount=$NS:default >/dev/null
$K -n $NS create configmap subid --from-literal=subuid="user:2000:60000" --from-literal=subgid="user:2000:60000" >/dev/null

echo "== build Pods, made by the job controller's account"
for f in kaniko buildkit-rootless buildah-rootless; do
  name=${f%-rootless}
  sed "s#REGISTRY#$REG#g" $f.yaml | $K $AS apply -f - >/dev/null 2>/tmp/bp-$f.err || { echo "$name: REFUSED: $(grep -v '^Warning' /tmp/bp-$f.err | head -1 | cut -c1-200)"; continue; }
  ph=""; for _ in $(seq 1 90); do ph=$($K -n $NS get pod $name -o jsonpath='{.status.phase}' 2>/dev/null); case "$ph" in Succeeded|Failed) break;; esac; sleep 4; done
  if [ "$ph" = Succeeded ]; then echo "$name: built and pushed"; else echo "$name: $ph: $($K -n $NS logs $name 2>&1 | grep -iE 'error|denied|not permitted' | head -2 | tr '\n' ' ' | cut -c1-200)"; fi
done

echo "== what the policy refuses (server-side dry run)"
try() { # title as yaml
  out=$($K -n $NS create --dry-run=server $2 -f - 2>&1 <<EOT
$3
EOT
); if echo "$out" | grep -q "created (server dry run)"; then printf '  admitted %s\n' "$1"; else printf '  refused  %-58s %s\n' "$1" "$(echo "$out" | grep -v '^Warning' | head -1 | sed 's/.*denied request: //; s/.*violates //' | cut -c1-110)"; fi; }
pod() { printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: %s, labels: {%s}}\nspec:\n  %s\n' "$1" "$2" "$3"; }
OK='securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers: [{name: c, image: alpine, securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}}]'
BP='hostUsers: false
  securityContext: {runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers: [{name: c, image: alpine}]'
try "an ordinary Pod with the restricted settings (admitted)" "$AS" "$(pod t-a 'app: demo' "$OK")"
try "an ordinary Pod as root with no restrictions" "$AS" "$(pod t-b 'app: demo' 'containers: [{name: c, image: alpine}]')"
try "an ordinary Pod that keeps its capabilities" "$AS" "$(pod t-c 'app: demo' 'securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers: [{name: c, image: alpine, securityContext: {allowPrivilegeEscalation: false}}]')"
try "an ordinary Pod with user 0 and runAsNonRoot" "$AS" "$(pod t-d 'app: demo' 'securityContext: {runAsNonRoot: true, runAsUser: 0, seccompProfile: {type: RuntimeDefault}}
  containers: [{name: c, image: alpine, securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}}]')"
try "an ordinary Pod with an NFS volume" "$AS" "$(pod t-e 'app: demo' 'securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers: [{name: c, image: alpine, securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}, volumeMounts: [{name: v, mountPath: /v}]}]
  volumes: [{name: v, nfs: {server: nfs.example.com, path: /x}}]')"
try "an ordinary Pod that asks for the build label's freedom without it" "$AS" "$(pod t-f 'app: demo' 'hostUsers: false
  securityContext: {runAsUser: 0}
  containers: [{name: c, image: alpine}]')"
try "a build Pod made by another account" "--as=system:serviceaccount:$NS:default" "$(pod t-g 'cinim.io/profile: build' "$BP")"
try "a build Pod without hostUsers: false" "$AS" "$(pod t-h 'cinim.io/profile: build' 'securityContext: {runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers: [{name: c, image: alpine}]')"
try "a build Pod with Unconfined seccomp" "$AS" "$(pod t-i 'cinim.io/profile: build' 'hostUsers: false
  securityContext: {runAsUser: 1000, seccompProfile: {type: Unconfined}}
  containers: [{name: c, image: alpine}]')"
try "a build Pod with another Localhost profile" "$AS" "$(pod t-j 'cinim.io/profile: build' 'hostUsers: false
  securityContext: {runAsUser: 1000, seccompProfile: {type: Localhost, localhostProfile: profiles/other.json}}
  containers: [{name: c, image: alpine}]')"
try "a build Pod adding SYS_ADMIN" "$AS" "$(pod t-k 'cinim.io/profile: build' 'hostUsers: false
  securityContext: {runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers: [{name: c, image: alpine, securityContext: {capabilities: {add: [SYS_ADMIN]}}}]')"
try "a build Pod that is privileged" "$AS" "$(pod t-l 'cinim.io/profile: build' 'hostUsers: false
  securityContext: {runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers: [{name: c, image: alpine, securityContext: {privileged: true}}]')"
try "a build Pod with a hostPath volume" "$AS" "$(pod t-m 'cinim.io/profile: build' 'hostUsers: false
  securityContext: {runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers: [{name: c, image: alpine, volumeMounts: [{name: h, mountPath: /h}]}]
  volumes: [{name: h, hostPath: {path: /}}]')"
try "a build Pod on the host network" "$AS" "$(pod t-n 'cinim.io/profile: build' 'hostUsers: false
  hostNetwork: true
  securityContext: {runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers: [{name: c, image: alpine}]')"

$K delete -f policy.yaml >/dev/null; $K delete namespace $NS --wait=false >/dev/null
