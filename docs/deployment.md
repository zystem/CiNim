# Deploying CiNim

A shard is one Helm release of the chart `deploy/charts/cinim-shard`. The chart installs the core, the rights for
creating organisations (SHD-007) and the Ingress of the shard, and brings rqlite and the log circuit (two VictoriaLogs nodes and vlagent) as
subcharts from their official charts: one `helm install`, no helmfile. In the `multi` mode the router of the cluster
(`deploy/charts/cinim-router`) is a second, separate release, installed once per cluster.

## Before the first install

```bash
helm repo add rqlite https://rqlite.github.io/helm-charts
helm repo add vm https://victoriametrics.github.io/helm-charts
helm dependency build deploy/charts/cinim-shard     # downloads the subcharts into charts/
```

The transport keys (D-24) are a Secret with four Z85 files: `core.pub`, `core.key`, `client.pub`, `client.key`. The core gets the first two,
the controllers and conductors of the organisations the other two and `core.pub`. `tools/zmq/gen_curve_keys.sh` makes a test pair; a real installation issues its own keys.

```bash
kubectl create namespace cinim-001
kubectl -n cinim-001 create secret generic cinim-curve \
  --from-file=core.pub --from-file=core.key --from-file=client.pub --from-file=client.key
```

## One shard (`single` mode)

The release is installed into the namespace `<namespacePrefix>-<shard>`; the chart refuses any other namespace, because the subcharts put
their objects into the namespace of the release and the rights of the core are built on that name.

```bash
helm install cinim-001 deploy/charts/cinim-shard -n cinim-001 \
  --set-string shard=001 \
  --set image.repository=registry.example.com/cinim --set image.tag=1.0.0 \
  --set domain=ci.example.com --set curve.secretName=cinim-curve
```

Quote the shard name (`--set-string`, `"001"` in a values file): YAML reads an unquoted `001` as a number and the chart rejects it. A second
release in the cluster is refused: in `single` mode the chart creates a cluster-scoped marker with a fixed name, and a second `single`
release fails with a conflict of ownership (and its Ingress for the same host and path is rejected by a validating ingress controller).

The persistent volumes of the subcharts use the cluster's default StorageClass. Without a default one set the classes:

```bash
  --set rqlite.persistence.storageClassName=fast \
  --set victorialogs-0.server.persistentVolume.storageClassName=fast \
  --set victorialogs-1.server.persistentVolume.storageClassName=fast \
  --set vlagent.persistentVolume.storageClassName=fast
```

## Many shards (`multi` mode)

Once per cluster, with a key of at least 16 characters shared by the router and every core:

```bash
helm install cinim-router deploy/charts/cinim-router -n cinim --create-namespace \
  --set image.repository=registry.example.com/cinim-router --set domain=ci.example.com --set routerKey=...
```

Every shard, in this or another cluster, is then a release with `mode=multi` and the router's address and key. The shard name differs in
every cluster:

```bash
helm install cinim-002 deploy/charts/cinim-shard -n cinim-002 --create-namespace \
  --set-string shard=002 --set mode=multi \
  --set routerUrl=http://cinim-router.cinim.svc --set routerKey=... \
  --set image.repository=registry.example.com/cinim --set domain=ci.example.com --set curve.secretName=cinim-curve
```

`routerUrl` is the in-cluster address of the router for a shard in the same cluster, or its public `https://<domain><basePath>` for a shard in
another one (the core must then be built with `-d:ssl`, see settings.md).

## Your own database or log nodes

`rqlite.enabled=false` and `logs.enabled=false` turn the subcharts off; `rqliteUrl`, `logs.victoriaLogsUrls` (in the order of vlagent's
remoteWrite list) and `logs.vlagentUrl` then point at what you run. Production runs two independent VictoriaLogs nodes (DAT-010).

## Monitoring

`metrics.enabled=false` turns `/metrics` of the core off (and `metrics.enabled` of the router chart that of the router). With
`metrics.monitor.enabled=true` the charts create the scrape objects of a monitoring operator whose CRDs must be installed:
`metrics.monitor.operator` is `prometheus` (a ServiceMonitor, and a PodMonitor for rqlite) or `victoriametrics` (a VMServiceScrape and a
VMPodScrape). A ServiceMonitor is used wherever there is a Service with the port (the core, the router), because a Service lists only ready
Pods; rqlite's chart has two Services over the same Pods, so its Pods are scraped directly. The VictoriaLogs and vlagent subcharts have their
own switches (`victorialogs-0.server.serviceMonitor.enabled`, `vlagent.serviceMonitor.enabled`, ...), which create Prometheus ServiceMonitors only.

## A second test cluster, in place of the main one

A single-node k3s cluster (or any other) can stand in for the main test cluster when that one is not available. What it needs, and what was measured
on one (k3s 1.36, containerd 2.3, kernel 6.17, one node of 8 CPUs and 32 GiB):

1. **Access.** `deploy/examples/test-cluster/claude-access.yaml` makes a ServiceAccount and a ClusterRole for building and testing CiNim (it is as good as an
   administrator of the cluster: a test cluster only). Its token, in a kubeconfig that holds no CA when the API is published through a tunnel with a
   public certificate, goes into the environment as a single line.
2. **A registry.** `deploy/registry/values-single-node.yaml`: a NodePort, no Ingress. Build Pods push to `registry-docker-registry.registry.svc:5000`; the
   node pulls `localhost:30500/<image>` over plain HTTP, which containerd allows for `localhost` without any change to the node.
3. **The images**, built in the cluster: `REGISTRY=registry-docker-registry.registry.svc:5000 TAG=<tag> tools/image/kaniko-build.sh` (about 6 minutes cold).
4. **The shard**: the chart with `image.repository=localhost:30500/cinim`, `build.enabled=true`,
   a `build.egress` rule for the namespace `registry` port 5000 and `rqlite.replicaCount=1`; the default StorageClass (`local-path`) is enough.

Checked end to end there: an organisation, an ordinary step, a step of the build profile (Kaniko built an image and pushed it), the log API. User namespaces
(`hostUsers: false`) work, and `seccompDefault` is off. **What differs from the main cluster:** the NetworkPolicy controller of k3s (kube-router) blocks a step's way to
the internet (`default-deny` works) but **not its way to other Pods of the cluster**: a step of a closed organisation reached the core, and rqlite, by their Pod
addresses and through the Service. A test of the isolation between an organisation and the shard therefore does not hold there (it holds on Cilium, as measured on
the main cluster); run it on a cluster with a network plugin that enforces it. The rootless classes (`build.seccompProfile=Localhost`) need the file `profiles/cinim-userns.json` on the node,
which cannot be put there through the API.

### The 72 h soak in a cluster

`deploy/examples/soak72/soak72.yaml` runs the soak (NFR-013, `tools/soak/run72.sh`: the release harness continuously and the ASan/LSan harness in hourly runs) as a Job with
a volume for the results, from the image of `tools/soak/Dockerfile` (`DOCKERFILE=tools/soak/Dockerfile TARGETS=-:cinim-soak tools/image/kaniko-build.sh`). It can run
next to the soak host. `backoffLimit: 0`: a Pod that dies (a node restart, an OOM kill) ends the run, because a soak that starts again from zero is not a 72 h soak, and the
volume keeps what was written. Read the result with `tools/soak/summarize.sh`:

```bash
kubectl -n cinim-soak exec job/soak72 -- /cinim/tools/soak/summarize.sh /out        # while it runs, or after: kubectl cp from a Pod that mounts the claim
```

The CPU and memory that other work on the same node takes do not change the RSS growth that is measured, but a restart of the node does end the run.

## The registry of the MVP stand

Until the images are released to ghcr by the CI, the stand uses the plain Docker registry (the image `registry`) from the chart
`twuni/docker-registry`, with the values in `deploy/registry/values.yaml`: a release in the namespace `registry` and an Ingress for
a host of your own (an A record to the ingress controller; `registry.example.com` below). It has no authentication and speaks plain HTTP, so it is for the LAN test
cluster only, and the node's containerd and the workstation's Docker must accept it as an insecure registry.

```bash
helm repo add twuni https://twuni.github.io/docker-registry.helm
helm install registry twuni/docker-registry -n registry --create-namespace -f deploy/registry/values.yaml \
  --set 'ingress.hosts[0]=registry.example.com'
tools/image/build_core.sh registry.example.com/cinim:dev && docker push registry.example.com/cinim:dev
```

The image is built by `tools/image/build_core.sh`: the core (with TLS) is a static binary in a `scratch` image of about 8 MB
with the CA certificates, so the image needs no libraries (`deploy/core/Dockerfile`). The image of the job controller is built by
`tools/image/build_controller.sh <image:tag>` (`deploy/controller/Dockerfile`): the static controller, with the Kubernetes C client, libcurl,
OpenSSL, libzmq, libsodium and SQLite linked in, and the static shim that it hands to every step Pod, in a `scratch` image of about 8 MB.

## Runs and organisations

`POST /api/v1/runs` takes the slug of an organisation (`organization`): the run belongs to it, and its steps run in the namespace of the
organisation, through the controller that the core made for it. A controller says which namespace it serves in every poll, and the core
gives it the steps of that namespace only; a controller proves the namespace it serves with the credential below (IAM-003, T-46); the transport key itself is still shared (T-08).
An organisation that does not exist is a 404 and a switched-off one a 409. The controller proves which namespace it serves: the core starts its Pod with a one-time token in its environment (`CINIM_BOOTSTRAP_TOKEN`, no Secret), the controller exchanges it for a credential that it keeps in memory and sends in every poll, and a poll without it is refused. A refusal says why (`PollResponse.refusal`, also in the log of the core). The core looks after the rest (D-62): a controller that has not enrolled, or has not been heard from, or has an identity that is not the current one, is deleted and another is started with a new token, so nothing is done by hand; To lock out a credential that leaked, delete the controller's Pod: the core makes another, with a new generation of the identity, and the old credential stops working. Without `organization` a run belongs to the shard's default
tenant and profile (single-tenant setups). The settings of docs/settings.md are per organisation: `GET/PUT /api/v1/profile?organization=<slug>`.

## Image builds (the build profile)

With `build.enabled=true` the namespace of every organisation is Pod Security `baseline` by label, and the chart's ValidatingAdmissionPolicy
(`<prefix>-<shard>-build-pods`, D-42) gives every Pod in it but a build Pod what `restricted` has over `baseline`: so the organisation's ordinary
steps and its controller stay as strict as before, and there is one namespace, one controller and one identity per organisation. A job asks for a
build with `profile = "build"`; the controller of the organisation then makes that step a **build Pod**: label `cinim.io/profile=build`, a user
namespace of its own (`hostUsers: false`, root is not root on the node), and one of two classes, chosen for the shard with `build.seccompProfile`:

- `RuntimeDefault` (Kaniko): root in the container, the default seccomp profile, every capability dropped but those in `build.capabilities`. The
  image of the job is the `-debug` image of the maintained Kaniko fork, `ghcr.io/osscontainertools/kaniko:v1.28.5-debug@sha256:d6d74217dc077acfd3094992e917c357080a2d3fdd1042a49e34e29a7e57c572`
  (D-43; Google archived the original in June 2025), which has the shell that the shim needs. It needs nothing on the nodes. Pin the image by digest.
- `Localhost` (rootless BuildKit and Buildah): user 1000 under the seccomp profile `profiles/cinim-userns.json`, which must exist on every node
  (below). It needs the images' own `subuid`/`subgid` files adjusted for a user namespace of a Pod (`deploy/examples/build-pods`).

The policy lets a build Pod through only when the job controller of the namespace made it, with `hostUsers: false`, one of those two seccomp
profiles and none of the capabilities beyond the six. A build downloads packages all the time (npm, deb, maven, go modules, git), so build Pods
(and only they) may reach the public internet on ports 80, 443 and 22 (`build.internet`) and nothing inside: the cluster's pods and services, the
LAN and the metadata address stay closed (`build.internet.except`), as does everything else of the organisation's network rules (DNS and the log
collector are open). It needs Kubernetes 1.30 or later (admission policies).

It needs `user.max_user_namespaces` raised on the nodes (Talos: `machine.sysctls`). A registry or a package proxy at a private address, which
`build.internet` keeps closed, is opened with `build.egress`, a list of NetworkPolicy egress rules. For a registry in the cluster:

```yaml
build:
  enabled: true
  egress:
    - to:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: registry}}
      ports: [{protocol: TCP, port: 5000}]
```

```lua
ci.job({image = "ghcr.io/osscontainertools/kaniko:v1.28.5-debug@sha256:d6d74217dc077acfd3094992e917c357080a2d3fdd1042a49e34e29a7e57c572", profile = "build"}, function(j)
  j:sh("/kaniko/executor --dockerfile=Dockerfile --context=dir:///cicd/workspace --destination=registry.example.com/team/app:1.0")
end)
```

A step may publish to several sinks at the same time, for example an image to a registry and a package to a Nexus: `build.egress` is a list, and
every rule in it (a registry in the cluster, a Nexus at a private address, a package proxy) is open to build Pods together, on their ports. The
rules apply to **build Pods only** (`profile = "build"`): an ordinary step has DNS and the log collector and nothing else, so a step that
publishes has to be a build step, or the organisation has no way to reach the sink (a rule for ordinary steps is not built, Q-18).

What a build needs beyond the six capabilities (installing packages, setting file capabilities) is not measured (A.13, Q-17). A registry on a
public address needs no rule; one on a private address (in the cluster, in the LAN) needs a `build.egress` rule, and `build.internet.enabled=false`
closed every address but those. The internet rule is an `ipBlock` over all addresses minus the private ranges: with a network plugin that does
not count pods and nodes as private addresses (Cilium does not) keep the cluster's own ranges in `build.internet.except`.

## Deploying from a pipeline (the deploy profile)

A job asks for it with `profile = "deploy"` (D-48). Its steps are ordinary Pods in every respect of security (non-root, `restricted`, no user namespace), and differ from the other
steps of the organisation by a label, `cinim.io/profile=deploy`, which selects the network policies below. By default every step is closed (SEC-003): DNS and the platform's collector
and nothing else, and a build Pod additionally reaches the internet and `build.egress`. A deploy Pod reaches only what the operator lists, so that a step that publishes or rolls out has a way
to its target and an ordinary step has none. What the step may *do* there is not decided by the platform but by the credential it is given, as a step secret (docs/secrets-masking.md):
a token of a ServiceAccount, a kubeconfig, an API key of a registry.

```yaml
deploy:
  enabled: true
  kubeApiServer: true      # the Kubernetes API server of this cluster, with a CiliumNetworkPolicy
  egress:                  # NetworkPolicy egress rules for the rest: another cluster, a registry, an artifact store (or the string `all`)
    - to: [{ipBlock: {cidr: 203.0.113.0/24}}]
      ports: [{protocol: TCP, port: 6443}]
```

**The API server under Cilium.** From a Pod of the organisation the cluster's own API server (`kubernetes.default.svc`) cannot be reached through the default-deny policy, and a NetworkPolicy
cannot open it. Measured on the TESTING cluster (Cilium, `kubeProxyReplacement`): `helm` and `kubectl` from a build step timed out (`dial tcp 100.80.0.1:443: i/o timeout`); an `ipBlock` rule on the addresses of the three
control-plane nodes, port 6443, changed nothing, because Cilium sees the API server at the addresses of the nodes and gives them an identity of their own that `ipBlock` does not select; a
`CiliumNetworkPolicy` with the entity `kube-apiserver` for the Pods of the profile let `kubectl get deployments` list them and `helm` reach the API (it was then refused only for a right the token did not have).
With `deploy.kubeApiServer: true` the core makes that policy in the namespace of every organisation (`allow-deploy-kube-apiserver`); it needs the right to make `ciliumnetworkpolicies` there
(the chart adds it to the core's ClusterRole and to its admission policy only then, T-45). On a cluster without Cilium leave the flag off and list the API server's address in `deploy.egress`. The Pods of the
other profiles stay closed: the policy selects the label.

The pipeline of the repository is `.ci/pipeline.lua` and its credential is `deploy/examples/self-build/deployer.yaml`: a ServiceAccount with **extended rights**, which is what this profile is for. It may change everything the shard chart and the storage chart own in the namespace of the shard (the Deployments, the StatefulSet of rqlite, the Services, the Secrets that hold the Helm releases) and the cluster-wide objects of the shard chart (its ClusterRoles and the admission policy), `escalate` and `bind` included: keep its token a step secret of the one organisation that builds the platform. The last step of the pipeline (`DEPLOY=true`) uses it, kept as the step secrets `DEPLOY_TOKEN` and `DEPLOY_CA`, to run `helm upgrade --atomic --wait` of the storage module and of the shard at the new tag (`--reset-then-reuse-values --set image.tag`: the values the release was made with, over the defaults of the chart as it is at that commit), then looks at the Deployments (the image and a ready replica) and, if anything failed, brings **both** releases back to the revisions they had (`helm rollback`). The controllers and the conductors follow the core by themselves: the next pass of the reconciliation sees that a controller Pod carries another fingerprint and replaces it (D-62), and a conductor of another image is drained when it is idle and made again.

Checked on the TESTING cluster, through the API alone: with `deploy.enabled` and `deploy.kubeApiServer` the core made `allow-deploy-kube-apiserver` in the namespace of a new organisation; the run of `self-build.lua` with `BUILD=false`,
`DEPLOY=true` and the tag of the previous build ran the fourth step as an ordinary Pod (non-root), the step fetched `DEPLOY_TOKEN` and `DEPLOY_CA`, patched the core, and the cluster ran the other image a few seconds
later (the core's `CINIM_CONTROLLER_IMAGE` and `CINIM_CONDUCTOR_IMAGE` too). The run was then ended by the older executor, which replayed the script and did not know the profile: a rollout to a version that does not know what the script uses ends the run, so a pipeline that
rolls out its own platform should not be replayed by an older executor. The whole chain, in one run (`BUILD` and `DEPLOY` both true): the clone of the repository's main branch, the two Kaniko builds (the second from the cache of the first) and the deploy step took about five minutes with warm caches; all four steps succeeded, the core and the executor were then running the images that the run had built, and a pipeline of four steps (an ordinary step, a build step, an ordinary step) ran on them. The deploy step of the first attempt did not start: the init container of the volume refused a directory that a build step had made (the shim now leaves a directory that is already open). Not checked: a cluster without Cilium.

## CiNim builds itself

The pipeline of the repository, `.ci/pipeline.lua`, builds the images of the platform side by side, runs the tests, and rolls the result out (it is described in its header; before D-63 it was `deploy/examples/self-build/self-build.lua` and was kept as text in a trigger): a job `prep` keeps a bare mirror of the repository as a cache of the
organisation (`git-<commit>`) and finds the commit, a job makes the image of the libraries once (`cinim-deps:<hash>`, `tools/image/Dockerfile.deps`, pushed to the registry
and found there by the next run), and the images of the components are built by `ci.matrix` with `fail_fast`, each build in a volume of its own (`workspace = "isolated"`) that it clones the commit
into from the mirror, and each from `DEPS_IMAGE` so that none makes the libraries. (This replaces the three build steps in a row that shared the run's volume; the text that follows is of the first form.)
The registry address and the tag are launch parameters (`REGISTRY`, `TAG`, also `REPO` and `REF`): `POST /api/v1/runs` with `"params": {"REGISTRY": "<host:port>", "TAG": "dev-1"}`. The clone is a build step
too, because only build Pods reach the internet. Checked on the TESTING cluster through the API alone: an organisation, a run of that script; the images `cinim` and `cinim-controller` appeared in the registry
(the second build read the cache of the first), and an earlier run of the same kind had been upgraded to run on its images. Kaniko needs one step per build, since it works on one Dockerfile and target at a time. A step that exits
with a non-zero code fails the job and the run (`ignore_failure = true` returns the code to the script instead, PIP-018). The registry here is the plain
in-cluster one of `deploy/registry`: its address is the one the Pods reach it at, which is not always the name the nodes pull from.

### By the clock, every night

The same script as a **schedule trigger** of the organisation (docs/triggers.md): the platform then builds its own images every night without anyone starting it. The trigger names the
repository (the conductor reads `.ci/pipeline.lua` at the `ref` at every firing) and holds the parameters (the registry; no `TAG`), `"schedule": "0 2 * * *"` (UTC) and `"concurrency": "cancel_newest"`, so that a night is skipped while the last one is still running:

```bash
curl -X POST .../api/v1/organizations/<slug>/triggers -H "Authorization: Bearer $ADMIN" -d '{"name": "self-build-nightly", "kind": "schedule", "schedule": "0 2 * * *",
  "concurrency": "cancel_newest", "repository": "https://github.com/zystem/CiNim.git", "ref": "main", "params": {"REGISTRY": "<host:port the Pods push to>", "PULL_REGISTRY": "<the name the nodes pull from>"}}'
```

With no `TAG` the images are tagged `<date>-<commit>` (`20261009-eefb939`): the clone step writes `IMAGE_TAG` to `$CICD_ENV` and the later steps of the run read it, so a night's images are not the last night's.
`DEPLOY` stays false for a nightly build: the images are built and pushed, and rolling the shard out to them is a decision (set `DEPLOY` true and give the organisation the secrets of the deploy step to roll out every night). Checked on the
TESTING cluster: a trigger set for two minutes ahead fired by itself (`last_result: started`, the run carries `trigger_id`), the run took about five minutes with warm caches, all three steps succeeded and both images appeared under the
tag of that day and the head of `main`; the trigger was then replaced by the nightly one.

### On every push: the tests, the rollout, the webhook

A **webhook trigger** with a repository (D-63) is the push: the git server calls `POST /api/v1/hooks/<id>` with the secret of the trigger as the bearer token and `{"commit": "<sha>"}` (a call made by hand, or by a few lines of the server's own hook; GitHub's signature header is not supported, TRG-002). A conductor of the organisation reads `.ci/pipeline.lua` at that commit, and the run:

1. mirrors the repository (a cache of the organisation) and finds the commit, the tag of the images and the hashes of the two images below,
2. makes `cinim-deps:<hash>` (the libraries) and `cinim-test:<hash>` (`tools/image/Dockerfile.test`: those and `rqlited`) once, and finds them in the registry afterwards,
3. side by side, the first failure stopping the other: the four images, and **the tests** (`TEST=true`): `tools/test/run.sh -j $TEST_JOBS` in a Pod of the test image (a build-profile Pod, so root of a user namespace: the nimble packages are in the home of root). The integration tests need a scratch rqlite each; with no Docker, or with `CINIM_RQLITE_BIN=<rqlited>`, `run.sh` starts its own `rqlited` processes (ports 24600+N, data in `/dev/shm`) and stops them at the end, so the Pod needs nothing but the image. The same works on a workstation without Docker,
4. when `DEPLOY=true`: `helm upgrade --atomic --wait` of both charts at the new tag, a look at what runs, and a rollback of both releases if anything failed (above).

```bash
curl -X POST .../api/v1/organizations/<slug>/triggers -H "Authorization: Bearer $ADMIN" -d '{"name": "main-push", "kind": "webhook", "concurrency": "cancel_previous",
  "repository": "https://github.com/zystem/CiNim.git", "ref": "main",
  "params": {"REGISTRY": "<host:port the Pods push to>", "PULL_REGISTRY": "<the name the nodes pull from>", "DEPLOY": true}}'
curl -X POST .../api/v1/hooks/<id> -H "Authorization: Bearer <the secret>" -d '{"commit": "<sha>"}'
```

`cancel_previous` makes the newest commit the one that is built when pushes come quickly. The conductors of the organisation must reach the git server: the chart's `conductor.internet` (default: the public internet on ports 80 and 443, the private ranges closed) and `conductor.egress` (a list of NetworkPolicy rules for a git server inside the cluster or the LAN, or `all`). The registry has no TLS and no login here (the plain in-cluster registry above), and a private repository cannot be read (the conductor has no credentials).

## Examples of build Pods

`deploy/examples/build-pods` has the namespace, the policy (the same text as the chart's) and one Pod per tool, and `test.sh` that builds an image
with each and prints what the policy refuses (A.13). Use it to try a cluster by hand; the core and the chart do the same thing for every organisation.

## A seccomp profile for rootless builders

A rootless builder (BuildKit, Buildah) makes its own user and mount namespaces, which the default seccomp profile of the runtime forbids; the
only way to allow it without `Unconfined` (which `baseline` refuses) is a `Localhost` profile that exists as a file on every node.
`deploy/seccomp/cinim-userns.json` is Docker's default profile (as an unprivileged container with the capabilities of the build profile gets it)
plus `unshare`, `setns`, `clone` without a flag filter, `mount`, `umount`, `umount2`, `pivot_root`, `chroot`, `sethostname`, `setdomainname`, the new
mount calls (`fsopen`, `fsconfig`, `fsmount`, `fspick`, `move_mount`, `open_tree`, `mount_setattr`) and `keyctl`. It still forbids `bpf`,
`perf_event_open`, `quotactl`, `syslog`, `fanotify_init`, the kernel-module, reboot, time and raw-I/O calls. Rootless BuildKit and Buildah built
an image under it, as user 1000 in a `baseline` namespace, with Docker and on the TESTING cluster (A.13). On Talos the profile is a machine config field:

```bash
talosctl -n <node>,<node>,... patch machineconfig --mode=no-reboot --patch @deploy/seccomp/talos-patch.yaml
talosctl -n <node> get seccompprofiles
talosctl -n <node> read /var/lib/kubelet/seccomp/profiles/cinim-userns.json
```

A Pod uses it with `securityContext: {seccompProfile: {type: Localhost, localhostProfile: profiles/cinim-userns.json}}`. Regenerate the files with
`tools/build-test/seccomp-userns.py <Docker's default.json> > deploy/seccomp/cinim-userns.json` after a change of the capability list.

## The master key of the step secrets

The step secrets (docs/secrets-masking.md) are sealed in the database with data keys that a master key wraps. **Back the master key up apart from the database** and keep it
apart from it: a database restored without it holds nothing readable. It is a file of 64 hexadecimal digits (`secrets.keySecret`, `CINIM_SECRETS_KEY_FILE`) or, when none
is given, it is derived from the core's CURVE key (`curve.secretName`), which then also has to be kept: a changed CURVE key loses the secrets. To keep the master key on
a SmartCard-HSM instead, see docs/hardware-key.md (the hardware, the key and the backup; the core already speaks to a key service, the service for the card is planned).

## API tokens

Every route of the REST API but `/metrics` and `/healthz` wants `Authorization: Bearer <token>` (IAM-003, D-44; the Helm value `auth.enabled`, on by
default). At the first start the core makes the user `admin` and writes its password and token to its log, once, in a line a script can read; **the password has to be changed
after the first login**, and until then nothing else is allowed:

```bash
kubectl -n cinim-001 logs deploy/cinim-core | grep '^cinim-credentials'
# cinim-credentials user=admin role=admin password=<64 hex> token=cnm_<id>_<64 hex>
curl -X POST .../api/v1/login -d '{"user":"admin","password":"<the password>"}'      # a token for 8 hours; the answer says "password_change_required": true
curl -X PUT .../api/v1/users/admin/password -H "Authorization: Bearer <the token>" -d '{"current_password":"<the generated one>","password":"<a new one, 16 or more characters>"}'
kubectl -n cinim-001 exec deploy/cinim-core -- /core admin-password-reset            # the administrator's lost password: a new line, the old tokens are revoked, to be changed again
```

**Roles and users (IAM-001, D-50).** The roles of the shard, which every organisation inherits: `admin` may do everything, `rw` is almost an administrator (everything but the users, the roles, the API tokens and the object store), `dev` does what a developer does
(reads, starts and stops runs, also by a manual trigger), `ro` reads (the list is in the specification, IAM-001). The administrator makes the other users and deletes them:

```bash
curl -X POST .../api/v1/users -H "Authorization: Bearer $ADMIN" -d '{"name":"ann","role":"dev","password":"<16 or more characters>"}'
curl -X DELETE .../api/v1/users/ann -H "Authorization: Bearer $ADMIN"
curl .../api/v1/roles -H "Authorization: Bearer $ADMIN"
curl -X POST .../api/v1/login -d '{"user":"ann","password":"..."}'                    # a token for 8 hours, with the roles of the user
```

A user changes their own password (with the current one), an administrator anyone's, at least 16 characters:

A new password is refused when it is too simple (a few characters, a repeated group, a run like `1234…` or `qwerty…`, only common words and digits: `weak_password`) or when it
appears in known data breaches (`pwned_password`): the core asks Have I Been Pwned (Pwned Passwords) and sends only the first five digits of the SHA-1 of the password. If the
service cannot be reached from the core's Pod, the simple rules alone decide and the answer says `"breach_check": "local"`; a shard with no way out sets `auth.pwnedCheck: "off"`
(or a mirror in `auth.pwnedUrl`).

```bash
curl -X PUT .../api/v1/users/ann/password -H "Authorization: Bearer <the token of ann>" -d '{"current_password":"<the old one>","password":"<a new one, 16 or more characters>"}'
curl -X PUT .../api/v1/users/ann/password -H "Authorization: Bearer $ADMIN" -d '{"password":"<a new one>"}'      # an administrator needs no current password
```

Nothing is generated by the chart, so helmfile and `helm template` render the same every time. If you would rather give a token yourself (from your secret
store), set `auth.adminToken` (or `auth.adminTokenSecret`, a Secret with the key `token`): it cannot be rotated by the API. The tokens
for people and organisations:

```bash
# a token for the CI of one organisation: it may start and read the runs of acme and do nothing else; it expires in 90 days
curl -X POST .../api/v1/tokens -H "Authorization: Bearer $ADMIN" -d '{"name": "acme-ci", "scope": "org:acme", "ttl_seconds": 7776000}'
curl .../api/v1/tokens -H "Authorization: Bearer $ADMIN"          # the list, without secrets and hashes
curl -X DELETE .../api/v1/tokens/<id> -H "Authorization: Bearer $ADMIN"
```

The token is in the answer once and only its hash is kept. The Kubernetes API server proxy (`kubectl proxy`, `/api/v1/namespaces/.../services/.../proxy`)
takes the `Authorization` header for itself, so reach the core through the Ingress or `kubectl port-forward svc/cinim-core 8080:80`. With
`auth.enabled: false` the API is open (development only).

## The simple mode: a small organisation, open egress or ingress

By default the step Pods are closed both ways. For a small organisation or an easy case, `network.egress: open` lets every step Pod reach any
address (including the cluster's own services and the LAN) and `network.ingress: open` lets any address reach them; both are defaults of the shard.
An organisation can ask for its own when it is created, and what it leaves out is the shard's default:

```bash
curl -X POST .../api/v1/organizations -d '{"slug": "acme", "name": "Acme", "network": {"egress": "open", "ingress": "open"}}'
```

For build Pods only there are narrower switches, `build.egress: all` (they may reach any address, private ones too) and `build.ingress: all` (any
address may reach them; by default a build Pod is closed to every inbound connection). Like `build.egress`, `build.ingress` is also a list of rules and takes several peers and ports, and the other steps stay closed. The controller of the organisation keeps its closed ingress in every mode. The simple modes give up the isolation of SEC-003 for
convenience (T-48); keep the default for an organisation that runs untrusted pipelines.

## Building the images in the cluster

`tools/image/kaniko-build.sh` makes a namespace under the build-pod policy (the files of `deploy/examples/build-pods`), sends the working tree to a
Kaniko build Pod and builds the images of the components, each from its own `tools/image/Dockerfile.<component>` and from the image of the libraries (`Dockerfile.deps`, pushed as `cinim-deps:<hash>` and found there by the next build):

```bash
REGISTRY=<registry host:port as the Pods reach it, plain HTTP> TAG=1.0.0 tools/image/kaniko-build.sh
```

A cold build takes about 12 minutes (it builds libzmq, the Kubernetes C client and every binary); a rebuild after a change of the sources about 3.

Every component has a Dockerfile of its own (`tools/image/Dockerfile.core`, `.storage`, `.conductor`, `.controller` with the shim, `.kekd-emu`, `.caddy-store`) that starts from the image of the libraries, and the binaries are compiled by `tools/image/build-static.sh`, which has the flags they share; a target builds only its own: `TARGETS="storage:cinim-storage"` compiles the module and nothing else. Do not build Go (the Caddy image) in a build Pod on a node that also runs rqlite; it starved the node once.

### Building on this machine (the quick way for iterations)

`tools/image/build-local.sh <tag> [target ...]` compiles the binaries in a container of the dependencies image `cinim-deps:local` (`tools/image/Dockerfile.deps`: libzmq, libsodium, the Kubernetes client with libcurl, the nimble packages; made once, 3-4 minutes) with the working tree mounted and Nim's C files kept in `build/nimcache/<binary>`, so that the next build recompiles only what changed, then puts the images together from `tools/image/Dockerfile.local`, and with `REGISTRY=<host>` pushes them with `skopeo` (plain HTTP). Measured on a 32-core workstation: the module 3 s after a change of one file, the core 23 s, the controller with the shim and the conductor together 42 s with the push. It builds the working tree as it is, so for a release use the build Pod.

```bash
REGISTRY=registry.example.com tools/image/build-local.sh h84 core storage controller conductor
```

### Memory of the core

Measured on the TESTING cluster (the core's `VmRSS` read through an ephemeral container) and by a tool that has gone with the path (`tools/bench/ingestmem.nim`, deleted 2026-10-18 when the bytes stopped going through the core):

* **At start** 27-31 MiB with 34 threads (8 API threads) or 86 (64).
* **The threads of the API.** Every thread of the HTTP server has a heap of its own that keeps what it has had: about 1 MiB at its first request, more after a big answer. 100 requests spread over 64 threads cost about 60 MiB, over 8 threads 8 MiB. After the same load (100 requests, two runs with a 20 MB artifact, a run with a cache) the core was at 134 MiB with 64 threads and 79 MiB with 8. `core.apiThreads` (`CINIM_API_THREADS`) is 8 by default.
* **The path of the artifacts.** One thread serves all the shims, and it keeps the high-water mark of its heap: a block of 8 MiB lives in four copies at once (the message from ZeroMQ, the request decoded from Protobuf with its temporary buffer, the string made of it for the store), 33 MiB at the peak and 41 MiB kept; it appeared once, with the first big upload, and a later one did not add to it. The direct transfer from the shim (docs/storage-module.md, D-61) takes the bytes out of the core: with it on, three 20 MB runs up and down and two cache runs left the core at 34-36 MiB (it was at 71-79 MiB after the first one before), and the memory went to the module (31 MiB after six such runs, the reads streamed).
* The limit of the core's Pod, 512 MiB, is enough with room to spare.

## The storage module (the chart `cinim-storage`)

The object stores of a shard are the storage module's (D-60, docs/storage-module.md); the chart `deploy/charts/cinim-storage` installs it into the namespace of the shard, with Garage (D-46), Caddy nodes (D-58), both, or neither (stores that are already there are listed in `stores.external`). Images: `TARGETS="storage:cinim-storage caddy-store:cinim-store-dav" tools/image/kaniko-build.sh`.

```bash
helm install cinim-storage deploy/charts/cinim-storage -n cinim-001 \
  --set image.repository=<registry>/cinim-storage --set image.tag=<tag> \
  --set secrets.shards.001=<16+ characters> --set secrets.adminToken=<16+> --set secrets.sealKey=<16+> \
  --set stores.garage.enabled=true \
  --set stores.caddy.enabled=true --set stores.caddy.image.repository=<registry>/cinim-store-dav --set secrets.nodeToken=<8..256>
```

Then the shard's chart is pointed at it: `storage.url=http://cinim-storage:18090`, `storage.tokenSecret.name=cinim-storage`, `storage.tokenSecret.key=shard-001`, and `storage.directUrl=http://cinim-storage.<namespace of the shard>.svc:18091` (required with `storage.url`: the shims send their bytes straight to the module, D-61, and there is no other way); the namespaces of organisations that exist already need the new rule of the network policy: delete their `allow-dns-and-collector` and the core makes it again. Garage is one node on one volume (`replication_factor = 1`: the volume is the only copy, so back it up; a production store needs three nodes in three zones, which the chart does not make); its secrets are made on the volume at the first start. Keep `secrets.sealKey` apart from the database and its backups: a database restored without it holds stores whose secrets cannot be opened. A step Pod never reaches a store; only the module does, and the chart's network policies let only the core and the chart's own Pods reach the module. Tried on the TESTING cluster on 2026-10-17 (docs/storage-module.md, "Phase 4 as done"); give the module at least 1 GiB of memory (the default).

## Health of the components

Every long-running component has a probe of the kind that can tell its trouble, and the probe of a component that depends on a database does not restart it for the database's sake.

| Component | Alive (a failure restarts it) | Ready (a failure takes it out of the Service) |
|---|---|---|
| core | `/healthz`: none of the threads that take the log, the reports and the artifacts, or the push channel, the watchdog, the triggers, the reconciler and the log gate has missed its round by more than its limit (`core/health.nim`: 60 s for the push channel, 120-180 s for the ingest servers, 300-900 s for the slow loops); 20 s x 6 | `/readyz`: the database answers a read through the leader in 2 s (`common/dbready.nim`, kept for 2 s); 10 s x 3 |
| job controller | none in Kubernetes: the core is its supervisor (D-62) and deletes it when it has not enrolled within 3 minutes or has not been heard from for 2 minutes; the Pod is `restartPolicy: Never` | none (it has no Service) |
| conductor | `conductor --healthcheck`: the core answered a hello within 90 s (the hello goes every 5 s; the file is in `/tmp`, an `emptyDir`); 20 s x 3 after 30 s | none |
| storage module | `/healthz` | `/readyz`: its database answers |
| Caddy node of the store | `/__health` | `/__health` |
| Garage | admin API `/health` on 3903, 20 s x 9 | TCP 3900 |
| rqlite | `/readyz?noleader` (the node's API answers; a node without a leader is not restarted), 20 s x 15 after 60 s | `/readyz` |
| VictoriaLogs nodes | the chart's | the chart's |
| vlagent | none (the chart of the agent has no probe) | none |
| key service emulator | TCP 8443 (the example) | TCP 8443 |

A conductor that is cut off from the core is **alive** to Kubernetes in the ordinary sense and useless; the heartbeat makes that visible, and the restart that follows loses nothing (a conductor's runs are replayed from the journal). A controller is not left to Kubernetes at all: the core judges it by the reports it receives and kills it when they stop, and the Pod it makes next carries a new token. A core that is not ready is still alive and still takes what reaches it.

## The volume the steps of a run share

The steps of a run see one `/cicd/workspace` (STO-001, STO-002): the controller of an organisation makes a PersistentVolumeClaim `cicd-run-<run id>` before the first
Pod of the run and mounts it in the Pod of every step, its `workspace/` at `/cicd/workspace` and its `state/` at `/cicd/state` (the env file of `$CICD_ENV`, STO-003). A
file that one step writes is there for the next; so is a variable it writes to `$CICD_ENV`. The step's own files (`$CICD_OUTPUT`, `$CICD_MASK`) are in an `emptyDir` at
`/cicd/run`, so that two steps of a run never write the same one. Artifacts (docs/artifacts.md) are for what must outlive the run or reach people; the volume is for
what the steps of one run hand to each other.

A job with `workspace = "isolated"` (STO-002) has a volume of its own, `cicd-job-<job id>`, made at its first step and mounted in its steps only; it is deleted with the run's volume. The
Pods of such a job are kept on one node (ReadWriteOnce), the Pods of different jobs are not tied to each other, so the jobs of one run (the builds of `ci.parallel`) spread over the nodes.
It has a `state/` of its own as well: `$CICD_ENV` does not reach other jobs, pass values with `env = {...}` of `ci.job` or `outputs`. A job that clones with one tool and builds with
another runs its steps in different images (`j:sh(cmd, {image = ...})`). The size is that of the run's volume, so a run of N isolated jobs holds N+1 claims of `runStorage.size`.

```yaml
runStorage:
  size: 5Gi                      # the request of a run's claim
  storageClass: ""               # empty is the cluster's default class
  accessMode: ReadWriteOnce      # ReadWriteMany if the class has it
  retention: {succeeded: 0, failed: 86400}
```

With `ReadWriteOnce`, which most classes of local or block storage give, the volume can be attached to one node, so the Pods of a run are kept on one node (a pod affinity term over
the run label; the first Pod of a run matches its own term, which Kubernetes allows). That limits the steps of one run to the resources of that node; with `ReadWriteMany`
they spread. An init container (`cicd-shim --prepare-volume`, from the step's own image, with the step's own security context) makes the two directories before the step, because
the kubelet would make a missing `subPath` as root and a step that is not root could not write there; the directories are open to every user of the run, since a build Pod is
root of its user namespace while an ordinary step is user 1000.

**`ReadWriteMany` and the build profile.** A class that gives `ReadWriteMany` as an NFS export (LINSTOR's `linstor-rwx` does: the CSI driver exports a replicated volume with NFS-Ganesha,
`deploy/examples/linstor`) works for the ordinary steps of a run and **not for a build step**. A build Pod runs in a user namespace of its own (`hostUsers: false`, D-42), and the container runtime then mounts
every volume as an idmapped mount, which NFS does not support: the Pod stays in `Init:StartError` with `failed to set MOUNT_ATTR_IDMAP ... maybe the filesystem used doesn't support idmapped mounts`, and the run ends
as an infrastructure error. So: **an organisation whose pipelines have build steps (and so the self-build) uses a block, `ReadWriteOnce` class for the run volume**; `ReadWriteMany` fits pipelines that only have ordinary steps, where it is the way
for steps on different nodes to share one workspace (parallel jobs, `ci.parallel`, which is not built yet). The class is a value of the shard (`runStorage.storageClass`), not of a run, so a shard has one of the two; a choice per run or per organisation
is not built.

When the run is over and `retention` seconds have passed, the claim is deleted: the core names the run in the poll of the organisation's controller, again and again, until the controller
answers that the claim is gone (`runs.storage_released`; a run that never had a volume counts as released). So a lost answer or a restarted controller costs nothing, and a claim
is not left behind by a controller that was not there at the end of a run. The namespace's quota counts the claims (50) and their size (500 Gi).

Checked on the TESTING cluster (class `directpv-min-io`, `ReadWriteOnce`), through the API alone: a run of four steps in one organisation. The first step (user 1000) wrote a file, a file in a subdirectory
and a variable to `$CICD_ENV`; the second (user 1000, another Pod) read both files and the variable; a step of the build profile (root of a user namespace, `hostUsers: false`) read what the others wrote and wrote a
file of its own; the last step (user 1000) read the file of the build step. The directories of the volume were `drwxrwxrwx` owned by user 1000, and `$CICD_WORKSPACE` was `/cicd/workspace`. The run succeeded, and the claim was deleted a few seconds
after the controller removed the last Pod. A run whose step exited with 3 kept its claim (the retention for a failed run is a day). The first claim on a node showed one failed provisioning
(`VolumeBinding`) that the scheduler retried by itself; on a cluster whose node disks had no room left for a claim the Pod waited in `Pending` (the scheduler does not know DirectPV's free space) until it chose
a node with room or `start_timeout` ended the attempt and the step was repeated. The same run, with the working directory change of the shim (every step printed `pwd` as `/cicd/workspace` and used relative paths), succeeded on the second test cluster (k3s, `local-path`, `ReadWriteOnce`), build step included. Checked with `ReadWriteMany` (LINSTOR over NFS, two replicas and a tiebreaker): the first two, ordinary, steps of a run shared files and `$CICD_ENV` as on `ReadWriteOnce`, the third, a build step, did not start (above). Not checked: the parallel steps of one run (`ci.parallel` is not built, so the pod affinity of `ReadWriteOnce` was only
checked for being accepted), a class without `fsGroup` support, a controller restarted while a run was going.

A step's command starts in `/cicd/workspace` (the shim changes to it before the command runs; the working directory of the image is not used), so relative paths mean files on the shared volume. If the directory is missing the command starts in the image's own directory.

## Reconciliation and retention

At start and every `organizations.reconcileInterval` seconds (300) the core compares the organisations in its database with their Kubernetes objects
and makes again what is missing, with the same content: a deleted NetworkPolicy, a lost Deployment, the whole namespace after a restore into a new
cluster. A switched-off organisation is expected without its controller and its Ingress. The controller of an organisation is a Pod that the core makes and supervises (D-62): it lists the controller Pods of the namespace and deletes the ones it does not know or that are not healthy, and when none is good it
makes one with the token of the current generation of the identity (a new generation first when the identity was used). Apart from the controller's Pod and a NetworkPolicy that differs from what the core makes now (every policy carries the
fingerprint of the object, `cinim.io/spec-hash`; one with another or none is deleted and made again, `policies_replaced` says which), the reconciliation
deletes nothing: a namespace of this shard that no organisation owns, or whose policy labels differ from what the core would make (Pod Security,
the build-pod policy), is an alert. The core reads only namespaces and the controller Pods, so a Secret or a NetworkPolicy that was
changed by hand is not noticed, only one that is missing.

```bash
GET  /api/v1/organizations:reconcile      # the last pass: what was made again, the alerts, what the retention deleted, the interval and the retention
POST /api/v1/organizations:reconcile      # run a pass now
```

**Upgrading the controller of an existing organisation.** The Pod of the controller carries the fingerprint of what the core makes (`cinim.io/controller-spec`: the SHA-256 of the Pod made with no generation and no token: the image, its environment, its resources; the settings of the shard are not in it, they reach a controller in the answers to its poll). At every pass the core compares it with what it would make now, and a Pod with another one (after `helm upgrade` gave the core a new controller image) is **deleted and made again** with a new token. The state of a controller is on its volume and the Pods of the steps that are running are adopted by the new one (D-29), so a running step does not notice. `GET /api/v1/organizations:reconcile` says which controllers were replaced (`controller_replaced`) and why each Pod was deleted (`controller_removed`). The controller replaces the ConfigMap that carries the shim at every start, so the new image brings its shim to the Pods of the steps that start after that.

A switched-off organisation is kept `organizations.retention` seconds (14 days) from the moment it was switched off, then deleted for good: its namespace
with the volumes and its record. `0` deletes it at once and a negative value never; `DELETE ?purge=true&force=true` deletes it earlier.

## What the core makes for an organisation

`POST /api/v1/organizations` makes the namespace, the controller (its ServiceAccount, RoleBinding, Secret with the transport keys, state
volume and Deployment), the quota, the limit range, the network policies and, in the `multi` mode, the Ingress of the organisation (SHD-007);
`DELETE` switches an organisation off and `DELETE ?purge=true` deletes it. The job controller runs from its own image, `<image.repository>-controller:<image.tag>`, and a conductor from `<image.repository>-conductor:<image.tag>`; neither has a value of its own in the chart.
The chart expects `/core` in `image.repository`, the controller's and the conductor's images next to it; no pipeline publishes the images by itself yet (`tools/image` builds them, see above).
A volume of the controller needs a StorageClass: set `controller.stateStorageClass` when the cluster has no default one.
