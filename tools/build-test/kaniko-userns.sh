#!/bin/bash
# Builds an image with Kaniko in Pods with `hostUsers: false` in namespaces of different Pod Security levels (A.13, Q-17):
#   tools/build-test/kaniko-userns.sh <registry-host:port reachable from the cluster> <insecure-registry flag: yes|no>
# It creates three scratch namespaces (restricted, baseline, and a baseline one without the user namespace for comparison), a
# default-deny policy that opens only DNS and the registry, builds the same three-line Dockerfile in each, prints the verdicts and
# deletes the namespaces. It needs a cluster with `user.max_user_namespaces` raised (Talos: machine.sysctls) and a base image
# `base/alpine:3.20` in the registry. KUBECTL_CONTEXT picks the cluster.
set -uo pipefail
REG="${1:?registry host:port, as the cluster resolves it}"
HOST="${REG%%:*}"
K="kubectl ${KUBECTL_CONTEXT:+--context $KUBECTL_CONTEXT}"
PFX="kaniko-userns"
RS=registry   # the namespace of the registry (for the network policy)
[ -n "${REGISTRY_NAMESPACE:-}" ] && RS="$REGISTRY_NAMESPACE"
mk() {  # mk <namespace> <pod-security level>
  $K create namespace "$1" >/dev/null
  $K label namespace "$1" "pod-security.kubernetes.io/enforce=$2" "kubernetes.io/metadata.name=$1" --overwrite >/dev/null
  $K -n "$1" create configmap ctx --from-literal=Dockerfile="FROM $REG/base/alpine:3.20
RUN echo built-by-ci > /built && addgroup -S x && adduser -S -G x y
COPY hello.txt /hello.txt
" --from-literal=hello.txt=hello >/dev/null
  $K -n "$1" apply -f - >/dev/null <<EOT
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny}
spec: {podSelector: {}, policyTypes: [Ingress, Egress]}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-dns-registry}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}, podSelector: {matchLabels: {k8s-app: kube-dns}}}]
      ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
    - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: $RS}}}]
      ports: [{protocol: TCP, port: ${REG##*:}}]
EOT
}
pod() {  # pod <name> <namespace> <hostUsers: true|false> <security-context yaml for the pod> <container security context>
  cat <<EOT
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $2}
spec:
  hostUsers: $3
  restartPolicy: Never
  securityContext: $4
  containers:
    - name: k
      image: gcr.io/kaniko-project/executor:v1.23.2
      args: ["--dockerfile=/workspace/Dockerfile", "--context=dir:///workspace", "--destination=$REG/bt/$1:t", "--insecure", "--insecure-pull"]
      securityContext: $5
      resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 1Gi}}
      volumeMounts: [{name: ctx, mountPath: /workspace}]
  volumes: [{name: ctx, configMap: {name: ctx}}]
EOT
}
verdict() {  # verdict <name> <namespace> <apply output>
  if echo "$3" | grep -qi "forbidden"; then echo "$1: REFUSED by the namespace policy: $(echo "$3" | grep -o 'violates PodSecurity[^"]*' | head -1 | cut -c1-200)"; return; fi
  local ph=""
  for _ in $(seq 1 48); do ph=$($K -n "$2" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null); case "$ph" in Succeeded|Failed) break;; esac; sleep 5; done
  if [ "$ph" = Succeeded ]; then echo "$1: WORKS"; else echo "$1: FAILED ($ph): $($K -n "$2" logs "$1" 2>&1 | head -2 | tr '\n' ' ' | cut -c1-240; $K -n "$2" describe pod "$1" 2>/dev/null | grep -m1 -E 'Warning' | cut -c1-240)"; fi
}
mk $PFX-restricted restricted; mk $PFX-baseline baseline
run() { out=$(pod "$1" "$2" "$3" "$4" "$5" | $K apply -f - 2>&1); verdict "$1" "$2" "$out"; }
# K1: root in a user-namespaced Pod, default capabilities, default seccomp, baseline
run k1-root-userns-baseline $PFX-baseline false '{seccompProfile: {type: RuntimeDefault}}' '{runAsUser: 0}' &
# K2: the same without the user namespace (the earlier measurement, for comparison)
run k2-root-host-baseline $PFX-baseline true '{seccompProfile: {type: RuntimeDefault}}' '{runAsUser: 0}' &
# K3: the same Pod in the restricted namespace (root is refused)
run k3-root-userns-restricted $PFX-restricted false '{seccompProfile: {type: RuntimeDefault}}' '{runAsUser: 0}' &
# K4: user 1000 in a user-namespaced Pod, restricted settings
run k4-user-userns-restricted $PFX-restricted false '{runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, seccompProfile: {type: RuntimeDefault}}' '{allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}' &
# K5: root in a user-namespaced Pod with every capability dropped and only the ones Kaniko needs added back, baseline
run k5-root-userns-fewcaps-baseline $PFX-baseline false '{seccompProfile: {type: RuntimeDefault}}' '{runAsUser: 0, capabilities: {drop: ["ALL"], add: ["CHOWN", "DAC_OVERRIDE", "FOWNER", "SETUID", "SETGID", "FSETID", "SETFCAP", "MKNOD"]}}' &
# K6, K7: fewer capabilities added back, to find what Kaniko really needs
run k6-root-userns-6caps-baseline $PFX-baseline false '{seccompProfile: {type: RuntimeDefault}}' '{runAsUser: 0, capabilities: {drop: ["ALL"], add: ["CHOWN", "DAC_OVERRIDE", "FOWNER", "SETUID", "SETGID", "SETFCAP"]}}' &
run k7-root-userns-3caps-baseline $PFX-baseline false '{seccompProfile: {type: RuntimeDefault}}' '{runAsUser: 0, capabilities: {drop: ["ALL"], add: ["CHOWN", "DAC_OVERRIDE", "FOWNER"]}}' &
# K8: no capability added back at all
run k8-root-userns-nocaps-baseline $PFX-baseline false '{seccompProfile: {type: RuntimeDefault}}' '{runAsUser: 0, capabilities: {drop: ["ALL"]}}' &
wait
$K delete namespace $PFX-restricted $PFX-baseline --wait=false >/dev/null
