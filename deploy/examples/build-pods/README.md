# Build Pods in the namespace of an organisation (variant 1 of A.13 / Q-17)

Image builds without a second namespace: the organisation keeps one namespace, and a **build Pod** in it is allowed the few settings an image
build needs by an admission policy, while every other Pod is held to Pod Security `restricted`. Kaniko runs with the runtime's default seccomp
profile; rootless BuildKit and rootless Buildah need the `Localhost` seccomp profile of `deploy/seccomp`.

## How it works

| Piece | What it does |
|---|---|
| `namespace.yaml` | the namespace is labelled Pod Security `baseline` (enforced) and `restricted` (audit and warn), and `cinim.io/build-pod-policy=on`; it also holds the job controller's ServiceAccount and the right to make Pods |
| `policy.yaml` | a ValidatingAdmissionPolicy for the namespaces with that label: every Pod must meet what `restricted` adds to `baseline` (no privilege escalation, `drop ALL`, non-root, no user 0, seccomp set, the volume types of `restricted`), **except** a Pod labelled `cinim.io/profile=build`, which must instead be made by the job controller's account, run in a user namespace (`hostUsers: false`), use the `RuntimeDefault` seccomp profile or `profiles/cinim-userns.json`, and add no capability but `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`, `SETFCAP` |
| `kaniko.yaml` | Kaniko: root of the Pod's user namespace, the six capabilities, `RuntimeDefault` |
| `buildkit-rootless.yaml` | rootless BuildKit: user 1000, the `Localhost` profile, a user namespace of its own, sub-id ranges that fit it |
| `buildah-rootless.yaml` | rootless Buildah: user 1000, the `Localhost` profile, a user namespace of its own, `vfs` storage |
| `test.sh` | applies all of it, builds an image with the three tools and prints what the policy refuses |

Pod Security `baseline` stays as the floor: it refuses `privileged`, `hostPath`, host namespaces, `Unconfined` seccomp and any capability beyond its
list for every Pod, a build Pod included. The policy adds only what `restricted` has over it. A build Pod cannot ask for more than the policy
lists, whatever its creator wants; and only the job controller can make one, so a pipeline step cannot.

## What the nodes and the cluster need

* Kubernetes 1.30 or later (ValidatingAdmissionPolicy), 1.33 or later for `hostUsers: false` on by default.
* `user.max_user_namespaces` above zero on the nodes (Talos: `machine.sysctls`), for `hostUsers: false`.
* For BuildKit and Buildah only: the seccomp profile `profiles/cinim-userns.json` on every node (`deploy/seccomp/talos-patch.yaml`). Kaniko needs no profile.

## Run it

```bash
REGISTRY=<registry host:port as the Pods reach it, plain HTTP>  KUBECTL_CONTEXT=<context>  ./test.sh
```

It needs the base image `base/alpine:3.20` in that registry. Measured on the TESTING cluster (Talos, Kubernetes 1.34): Kaniko, rootless BuildKit
and rootless Buildah each built and pushed an image as a build Pod, and the policy refused thirteen deviations, among them a build Pod from another
account, one without `hostUsers: false`, one with another seccomp profile, an ordinary Pod as root, with its capabilities, with user 0 or with an
NFS volume; `privileged`, `hostPath` and `Unconfined` seccomp are refused by Pod Security `baseline` itself.

## Things that cost time

* **Rootless BuildKit in a Pod with `hostUsers: false` fails with `newuidmap: write to uid_map failed`** with the image's own `/etc/subuid`,
  which names ids 100000..165535: the Pod's user namespace has only 0..65535. The ConfigMap `subid` replaces `/etc/subuid` and `/etc/subgid`
  with `user:2000:60000`, a range inside the Pod's ids. Buildah worked without it.
* **YAML 1.1 reads `y` and `n` as booleans**: a Pod named `n`, or a label `x: y`, is not what it looks like (the first versions of the test
  took a decode error for an admitted Pod).
* **`hostNetwork: true` with `hostUsers: false` is refused by the API itself.**
* **Pod Security `restricted` no longer enforces on such a namespace**; the policy replaces it, so it has to be kept in step with the
  `restricted` controls of the Kubernetes version in use (the audit and warn labels still name violations of the real `restricted`).
