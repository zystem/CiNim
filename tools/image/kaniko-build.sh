#!/bin/bash
# Builds the images of the platform in the cluster with Kaniko, as a build Pod under the admission policy of D-42 (no Docker daemon needed).
#   REGISTRY=<registry host:port as the Pods reach it, plain HTTP>  TAG=<tag>  [NS=cinim-build] [KUBECONFIG=...]  tools/image/kaniko-build.sh
# Other images: DOCKERFILE=<path in the tree> TARGETS="<stage>:<image> ..." (a `-` stage means no --target), for example the soak harness:
#   DOCKERFILE=tools/soak/Dockerfile TARGETS=-:cinim-soak REGISTRY=... TAG=... tools/image/kaniko-build.sh
# It makes the namespace (Pod Security baseline, the build-pod policy of deploy/examples/build-pods), sends the working tree as the build
# context, runs tools/image/Dockerfile.kaniko once per target (--target=core, controller, conductor; the later runs read the cache) and pushes
# <REGISTRY>/<image>:<TAG> for every target (by default cinim, cinim-controller and cinim-conductor). The namespace stays (the cache is in the registry); delete it when done.
set -euo pipefail
cd "$(dirname "$0")/../.."
REG="${REGISTRY:?registry host:port as the Pods reach it}"; TAG="${TAG:?tag}"; NS="${NS:-cinim-build}"
DOCKERFILE="${DOCKERFILE:-tools/image/Dockerfile.kaniko}"; TARGETS="${TARGETS:-core:cinim controller:cinim-controller conductor:cinim-conductor}"
K="${KUBECTL:-kubectl}"
EX=deploy/examples/build-pods
# the namespace and the policy of the example, with the namespace renamed; the policy needs the controller's account name in that namespace
sed "s/org-example/$NS/g" $EX/namespace.yaml | $K apply -f - >/dev/null
$K apply -f $EX/policy.yaml >/dev/null
sleep 2
$K -n $NS delete pod kaniko-images --ignore-not-found --wait=true >/dev/null
cat <<EOT | $K -n $NS --as=system:serviceaccount:$NS:cinim-job-controller apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: kaniko-images, labels: {cinim.io/profile: build}}
spec:
  restartPolicy: Never
  hostUsers: false
  securityContext: {runAsUser: 0, seccompProfile: {type: RuntimeDefault}}
  initContainers:
    - name: context       # waits for the build context (kubectl cp) and unpacks it
      image: busybox:1.36
      command: ["sh", "-c", "until [ -f /in/ready ]; do sleep 1; done; tar xzf /in/context.tgz -C /workspace"]
      securityContext: {capabilities: {drop: [ALL], add: [CHOWN, DAC_OVERRIDE, FOWNER]}}
      volumeMounts: [{name: in, mountPath: /in}, {name: workspace, mountPath: /workspace}]
  containers:
    - name: kaniko
      image: ghcr.io/osscontainertools/kaniko:v1.28.5-debug@sha256:d6d74217dc077acfd3094992e917c357080a2d3fdd1042a49e34e29a7e57c572
      command: ["/busybox/sh", "-c"]
      args:
        - |
          set -e
          for pair in $TARGETS; do
            t=\${pair%%:*}; n=\${pair#*:}
            tgt=""; [ "\$t" != "-" ] && tgt="--target=\$t"
            /kaniko/executor --dockerfile=/workspace/$DOCKERFILE --context=dir:///workspace \$tgt \\
              --destination=$REG/\$n:$TAG --cache=true --cache-repo=$REG/cinim-cache --insecure --insecure-pull --skip-tls-verify \\
              --skip-tls-verify-pull --use-new-run=true
          done
      securityContext: {capabilities: {drop: [ALL], add: [CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, SETFCAP]}}
      resources: {requests: {cpu: "1", memory: 2Gi}, limits: {memory: 12Gi}}
      volumeMounts: [{name: workspace, mountPath: /workspace}]
  volumes: [{name: in, emptyDir: {}}, {name: workspace, emptyDir: {}}]
EOT
T=$(mktemp); trap 'rm -f $T' EXIT
# the working tree as it is, without .git, build output and the Russian mirror
tar czf $T --exclude=.git --exclude=./build --exclude=./nimbledeps --exclude=./docs-tr --exclude=./nimcache --exclude=nimble.paths .
until $K -n $NS get pod kaniko-images -o jsonpath='{.status.initContainerStatuses[0].state.running}' 2>/dev/null | grep -q startedAt; do sleep 2; done
$K -n $NS cp $T kaniko-images:/in/context.tgz -c context
$K -n $NS exec kaniko-images -c context -- touch /in/ready
echo "context sent: $(du -h $T | cut -f1)"; echo "follow: $K -n $NS logs -f kaniko-images -c kaniko"
