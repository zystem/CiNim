# Deploying CiNim

A shard is one Helm release of the chart `deploy/charts/cinim-shard`. The chart installs the core, the pipeline executor, the rights for
creating organisations (SHD-007) and the Ingress of the shard, and brings rqlite and the log circuit (two VictoriaLogs nodes and vlagent) as
subcharts from their official charts: one `helm install`, no helmfile. In the `multi` mode the router of the cluster
(`deploy/charts/cinim-router`) is a second, separate release, installed once per cluster.

## Before the first install

```bash
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
with the CA certificates, so the image needs no libraries (`deploy/core/Dockerfile`).

## What is not in the chart yet

The core does not create the namespaces, controllers and Ingress objects of the organisations yet (SHD-007 steps 2 to 5, SHD-008): the chart
only grants the rights and the admission policy for them, and the job controller is not installed by the chart. The images are not built by
a pipeline yet: the chart expects `/core` and `/executor` in `image.repository`.
