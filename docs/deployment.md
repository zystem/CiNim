# Deploying CiNim

A shard is one Helm release of the chart `deploy/charts/cinim-shard`. The chart installs the core, the pipeline executor, the rights for
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
the executor the other two and `core.pub`. `tools/zmq/gen_curve_keys.sh` makes a test pair; a real installation issues its own keys.

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
4. **The shard**: the chart with `image.repository=localhost:30500/cinim`, `controller.image=localhost:30500/cinim-controller:<tag>`, `build.enabled=true`,
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

The image is built by `tools/image/build_core.sh`: the core (with TLS) and the executor are static binaries in a `scratch` image of about 8 MB
with the CA certificates, so the image needs no libraries (`deploy/core/Dockerfile`). The image of the job controller is built by
`tools/image/build_controller.sh <image:tag>` (`deploy/controller/Dockerfile`): the static controller, with the Kubernetes C client, libcurl,
OpenSSL, libzmq, libsodium and SQLite linked in, and the static shim that it hands to every step Pod, in a `scratch` image of about 8 MB.

## Runs and organisations

`POST /api/v1/runs` takes the slug of an organisation (`organization`): the run belongs to it, and its steps run in the namespace of the
organisation, through the controller that the core made for it. A controller says which namespace it serves in every poll, and the core
gives it the steps of that namespace only; a controller proves the namespace it serves with the credential below (IAM-003, T-46); the transport key itself is still shared (T-08).
An organisation that does not exist is a 404 and a switched-off one a 409. The controller proves which namespace it serves: the core makes a one-time bootstrap token with the namespace (a Secret), the controller exchanges it for a credential that it keeps on its state volume and sends in every poll, and a poll without it is refused. If the state volume is lost or the credential leaks, `POST /api/v1/organizations/<slug>:rotate-controller-credential` locks the old one out and the controller enrols again. Without `organization` a run belongs to the shard's default
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

## CiNim builds itself

`deploy/examples/self-build/self-build.lua` is a pipeline of two build steps that builds the two images of the platform from git with Kaniko and pushes
them to the registry (`tools/image/Dockerfile.kaniko`). Checked on the TESTING cluster through the API alone: a shard of this chart, an organisation,
`POST /api/v1/runs` with that script; both steps ran as build Pods, the images `cinim` and `cinim-controller` appeared in the registry, and the shard was
then upgraded to run on them. Kaniko clones a git context into a fixed directory, so two builds in one Pod need two steps (two `ci.job`). A step that exits
with a non-zero code fails the job and the run (`ignore_failure = true` returns the code to the script instead, PIP-018). The registry here is the plain
in-cluster one of `deploy/registry`: its address is the one the Pods reach it at, which is not always the name the nodes pull from.

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

## API tokens

Every route of the REST API but `/metrics` and `/healthz` wants `Authorization: Bearer <token>` (IAM-003, D-44; the Helm value `auth.enabled`, on by
default). The first administrator token is made the way TeamCity makes its super user token: at the first start the core writes it to its log, once, and the
first use must change it:

```bash
kubectl -n cinim-001 logs deploy/cinim-core | grep "FIRST START"
ADMIN=<the token from the log>
curl -X POST .../api/v1/token:rotate -H "Authorization: Bearer $ADMIN"       # the answer holds the new token, shown once; the old one is revoked
# until it is changed, every other route answers 403 token_change_required
ADMIN=<the new token>
kubectl -n cinim-001 exec deploy/cinim-core -- /core admin-token-reset        # a lost token: a new first token, to be changed the same way
```

Nothing is generated by the chart, so helmfile and `helm template` render the same every time. If you would rather give a token yourself (from your secret
store), set `auth.adminToken` (or `auth.adminTokenSecret`, a Secret with the key `token`): it needs no change and cannot be rotated by the API. The tokens
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
Kaniko build Pod and builds both images from `tools/image/Dockerfile.kaniko`, the second one from the layer cache in the registry:

```bash
REGISTRY=<registry host:port as the Pods reach it, plain HTTP> TAG=1.0.0 tools/image/kaniko-build.sh
```

A cold build takes about 12 minutes (it builds libzmq, the Kubernetes C client and every binary); a rebuild after a change of the sources about 3.

## Reconciliation and retention

At start and every `organizations.reconcileInterval` seconds (300) the core compares the organisations in its database with their Kubernetes objects
and makes again what is missing, with the same content: a deleted NetworkPolicy, a lost Deployment, the whole namespace after a restore into a new
cluster. A switched-off organisation is expected without its controller and its Ingress. When the namespace is new or the state volume of a controller is
gone, the identity of that controller is renewed (a new generation, a new bootstrap token) and the controller enrols again. The reconciliation
deletes nothing: a namespace of this shard that no organisation owns, or whose policy labels differ from what the core would make (Pod Security,
the build-pod policy), is an alert. The core reads only namespaces and the state volume of a controller, so a Secret or a Deployment that was
changed by hand is not noticed, only one that is missing.

```bash
GET  /api/v1/organizations:reconcile      # the last pass: what was made again, the alerts, what the retention deleted, the interval and the retention
POST /api/v1/organizations:reconcile      # run a pass now
```

**Upgrading the controller of an existing organisation.** `helm upgrade` changes what the core makes for new organisations (its image, `CINIM_BUILD*`),
not the Deployment that an organisation already has: the core creates objects and never changes them. To move an organisation to the new controller
image, delete its Deployment (`kubectl -n <prefix>-<shard>-<org> delete deployment cinim-job-controller`); the next pass of the reconciliation makes it again
from the current settings. The controller replaces the ConfigMap that carries the shim at every start, so the new image brings its shim to the Pods
of the steps that start after that.

A switched-off organisation is kept `organizations.retention` seconds (14 days) from the moment it was switched off, then deleted for good: its namespace
with the volumes and its record. `0` deletes it at once and a negative value never; `DELETE ?purge=true&force=true` deletes it earlier.

## What the core makes for an organisation

`POST /api/v1/organizations` makes the namespace, the controller (its ServiceAccount, RoleBinding, Secret with the transport keys, state
volume and Deployment), the quota, the limit range, the network policies and, in the `multi` mode, the Ingress of the organisation (SHD-007);
`DELETE` switches an organisation off and `DELETE ?purge=true` deletes it. The job controller runs from its own image, `<image.repository>-controller:<image.tag>` unless `controller.image` says otherwise.
The chart expects `/core` and `/executor` in `image.repository`; no pipeline publishes the images by itself yet (`tools/image` builds them, see above).
A volume of the controller needs a StorageClass: set `controller.stateStorageClass` when the cluster has no default one.
