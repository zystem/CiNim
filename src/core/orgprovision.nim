## SHD-007: the Kubernetes objects of an organisation. Creating one is the ordered list below, each create idempotent (an object that
## exists is as good as a created one), so that a retry after a failure and the reconciliation (SHD-008) do the same thing. Nothing is
## ever deleted except by `disable` (the Ingress and the controller) and `purge` (the namespace and, with it, everything in it), both
## on the explicit request of an administrator. The objects are plain JSON: the tests compare them, the API server validates them.
import std/[json, os, strutils]
import kubeapi, orgrules

const
  controllerName* = "cinim-job-controller"      ## the ServiceAccount, the Deployment and the label of the organisation's controller
  curveSecretName* = "cinim-controller-curve"
  stateClaimName* = "cinim-job-controller-state"
  coreServiceName* = "cinim-core"               ## the Service of the core in the namespace of the shard (chart cinim-shard)

type
  ProvisionConfig* = object
    prefix*, shard*, shardNamespace*: string    ## SHD-001; the namespace of the shard is the one the core itself runs in
    controllerImage*: string                    ## "" leaves the controller out (reported, not an error)
    stateClass*: string                         ## StorageClass of the controller's state volume; "" is the cluster default
    multi*: bool                                ## `multi` mode: the core makes the Ingress of an organisation
    host*, basePath*: string                    ## of the public URL: https://<host><basePath>/<slug>/
    ingressClass*, tlsSecret*: string
    annotations*: JsonNode                      ## of the Ingress, an object or nil

  CurveKeys* = object                           ## what the controller of an organisation needs to reach the core (D-24)
    corePub*, clientPub*, clientKey*: string

  Step* = object
    name*, kind*, namespace*, objectName*: string
    obj*: JsonNode

  StepResult* = object
    name*: string
    outcome*: Outcome

  ProvisionResult* = object
    ok*: bool
    steps*: seq[StepResult]                     ## what was done, in order, up to the failure
    failedStep*, error*: string
    skipped*: seq[string]                       ## parts left out on purpose, with the reason

func orgNamespace*(cfg: ProvisionConfig; slug: string): string = namespaceName(cfg.prefix, cfg.shard, slug)

func stepRunnerRole*(cfg: ProvisionConfig): string =
  ## the ClusterRole that the chart creates once per shard, the only role the core may bind (SHD-007, T-45)
  cfg.prefix & "-" & cfg.shard & "-step-runner"

func ingressName*(slug: string): string = "org-" & slug

func coreAddress(cfg: ProvisionConfig; port: int): string =
  "tcp://" & coreServiceName & "." & cfg.shardNamespace & ".svc:" & $port

func labels(cfg: ProvisionConfig; slug: string; component = ""): JsonNode =
  result = %*{"app.kubernetes.io/part-of": "cinim", "cinim.io/shard": cfg.shard, "cinim.io/organization": slug}
  if component.len > 0: result["app.kubernetes.io/name"] = %component

func meta(cfg: ProvisionConfig; slug, name, namespace: string; component = ""): JsonNode =
  result = %*{"name": name, "labels": labels(cfg, slug, component)}
  if namespace.len > 0: result["namespace"] = %namespace

func namespaceObject(cfg: ProvisionConfig; slug: string): JsonNode =
  var l = labels(cfg, slug)
  for mode in ["enforce", "audit", "warn"]: l["pod-security.kubernetes.io/" & mode] = %"restricted"
  %*{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": orgNamespace(cfg, slug), "labels": l}}

func controllerDeployment(cfg: ProvisionConfig; slug: string): JsonNode =
  let ns = orgNamespace(cfg, slug)
  %*{"apiVersion": "apps/v1", "kind": "Deployment", "metadata": meta(cfg, slug, controllerName, ns, controllerName),
     "spec": {
       "replicas": 1,
       "strategy": {"type": "Recreate"},       # one state volume, one writer
       "selector": {"matchLabels": {"app.kubernetes.io/name": controllerName, "cinim.io/organization": slug}},
       "template": {
         "metadata": {"labels": labels(cfg, slug, controllerName)},
         "spec": {
           "serviceAccountName": controllerName,
           "securityContext": {"runAsNonRoot": true, "runAsUser": 65532, "fsGroup": 65532, "seccompProfile": {"type": "RuntimeDefault"}},
           "containers": [{
             "name": "controller",
             "image": cfg.controllerImage,
             "env": [
               {"name": "CINIM_NAMESPACE", "value": ns},
               {"name": "CINIM_CORE_ADDR", "value": coreAddress(cfg, 19740)},
               {"name": "CINIM_COLLECTOR_ADDR", "value": coreAddress(cfg, 19743)},
               {"name": "CINIM_STEPREPORT_ADDR", "value": coreAddress(cfg, 19742)},
               {"name": "CINIM_CERTS", "value": "/etc/cinim"},
               {"name": "CINIM_STATE_DIR", "value": "/state"}],
             "volumeMounts": [
               {"name": "curve", "mountPath": "/etc/cinim/curve", "readOnly": true},
               {"name": "state", "mountPath": "/state"},
               {"name": "tmp", "mountPath": "/tmp"}],
             "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}},
             "resources": {"requests": {"cpu": "20m", "memory": "64Mi"}, "limits": {"memory": "256Mi"}}}],
           "volumes": [
             {"name": "curve", "secret": {"secretName": curveSecretName, "defaultMode": 288}},   # 0440
             {"name": "state", "persistentVolumeClaim": {"claimName": stateClaimName}},
             {"name": "tmp", "emptyDir": {}}]}}}}

func stateClaim(cfg: ProvisionConfig; slug: string): JsonNode =
  result = %*{"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": meta(cfg, slug, stateClaimName, orgNamespace(cfg, slug)),
              "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}}}
  if cfg.stateClass.len > 0: result["spec"]["storageClassName"] = %cfg.stateClass

func networkPolicies(cfg: ProvisionConfig; slug: string): seq[JsonNode] =
  ## SEC-003: the Pods of steps get default-deny; DNS and the log collector and the scheduler of the shard stay open to them.
  ## The controller is not a step Pod and is left out of the egress policies: its egress goes to the API server, which a
  ## NetworkPolicy cannot name in a portable way (Cilium keeps node addresses out of `ipBlock`); its ingress is closed instead.
  let ns = orgNamespace(cfg, slug)
  let core = %*{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": cfg.shardNamespace}},
                "podSelector": {"matchLabels": {"app.kubernetes.io/name": coreServiceName}}}
  let steps = %*{"matchExpressions": [{"key": "app.kubernetes.io/name", "operator": "NotIn", "values": [controllerName]}]}
  @[%*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "default-deny", ns),
       "spec": {"podSelector": steps, "policyTypes": ["Ingress", "Egress"]}},
    %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "allow-dns-and-collector", ns),
       "spec": {"podSelector": steps, "policyTypes": ["Egress"], "egress": [
         {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                  "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
          "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
         {"to": [core], "ports": [{"protocol": "TCP", "port": 19742}, {"protocol": "TCP", "port": 19743}]}]}},
    %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "controller-no-ingress", ns),
       "spec": {"podSelector": {"matchLabels": {"app.kubernetes.io/name": controllerName}}, "policyTypes": ["Ingress"]}}]

func ingressObject(cfg: ProvisionConfig; slug: string): JsonNode =
  let base = cfg.basePath.strip(leading = false, trailing = true, chars = {'/'})
  var rule = %*{"http": {"paths": [{"path": base & "/" & slug, "pathType": "Prefix",
                                    "backend": {"service": {"name": coreServiceName, "port": {"name": "http"}}}}]}}
  if cfg.host.len > 0: rule["host"] = %cfg.host
  var m = meta(cfg, slug, ingressName(slug), cfg.shardNamespace)
  if cfg.annotations != nil and cfg.annotations.kind == JObject and cfg.annotations.len > 0: m["annotations"] = cfg.annotations
  result = %*{"apiVersion": "networking.k8s.io/v1", "kind": "Ingress", "metadata": m, "spec": {"rules": [rule]}}
  if cfg.ingressClass.len > 0: result["spec"]["ingressClassName"] = %cfg.ingressClass
  if cfg.tlsSecret.len > 0 and cfg.host.len > 0:
    result["spec"]["tls"] = %*[{"hosts": [cfg.host], "secretName": cfg.tlsSecret}]

func organizationSteps*(cfg: ProvisionConfig; slug: string; curve: CurveKeys): tuple[steps: seq[Step], skipped: seq[string]] =
  ## SHD-007 (2)..(5), in the order of the specification
  let ns = orgNamespace(cfg, slug)
  func step(name, kind, namespace, objName: string; obj: JsonNode): Step =
    Step(name: name, kind: kind, namespace: namespace, objectName: objName, obj: obj)
  result.steps.add step("namespace", "Namespace", "", ns, namespaceObject(cfg, slug))
  if cfg.controllerImage.len > 0:
    result.steps.add step("controller service account", "ServiceAccount", ns, controllerName,
      %*{"apiVersion": "v1", "kind": "ServiceAccount", "metadata": meta(cfg, slug, controllerName, ns), "automountServiceAccountToken": true})
    result.steps.add step("controller role binding", "RoleBinding", ns, controllerName,
      %*{"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": meta(cfg, slug, controllerName, ns),
         "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": stepRunnerRole(cfg)},
         "subjects": [{"kind": "ServiceAccount", "name": controllerName, "namespace": ns}]})
    result.steps.add step("controller keys", "Secret", ns, curveSecretName,
      %*{"apiVersion": "v1", "kind": "Secret", "metadata": meta(cfg, slug, curveSecretName, ns), "type": "Opaque",
         "stringData": {"core.pub": curve.corePub, "client.pub": curve.clientPub, "client.key": curve.clientKey}})
    result.steps.add step("controller state volume", "PersistentVolumeClaim", ns, stateClaimName, stateClaim(cfg, slug))
    result.steps.add step("controller", "Deployment", ns, controllerName, controllerDeployment(cfg, slug))
  else:
    result.skipped.add "job controller: CINIM_CONTROLLER_IMAGE is not set"
  result.steps.add step("resource quota", "ResourceQuota", ns, "cinim-default",
    %*{"apiVersion": "v1", "kind": "ResourceQuota", "metadata": meta(cfg, slug, "cinim-default", ns),
       "spec": {"hard": {"pods": "100", "requests.cpu": "16", "requests.memory": "32Gi", "limits.memory": "64Gi",
                         "persistentvolumeclaims": "50", "requests.storage": "500Gi"}}})
  result.steps.add step("limit range", "LimitRange", ns, "cinim-default",
    %*{"apiVersion": "v1", "kind": "LimitRange", "metadata": meta(cfg, slug, "cinim-default", ns),
       "spec": {"limits": [{"type": "Container", "default": {"memory": "1Gi"}, "defaultRequest": {"cpu": "100m", "memory": "128Mi"},
                            "max": {"memory": "32Gi"}}]}})
  for p in networkPolicies(cfg, slug):
    result.steps.add step("network policy " & p["metadata"]["name"].getStr, "NetworkPolicy", ns, p["metadata"]["name"].getStr, p)
  if cfg.multi:
    result.steps.add step("ingress", "Ingress", cfg.shardNamespace, ingressName(slug), ingressObject(cfg, slug))

proc provision*(k: KubeApi; cfg: ProvisionConfig; slug: string; curve: CurveKeys): ProvisionResult =
  ## stops at the first failure and says which step it was; what was created stays (a retry creates the rest)
  let (steps, skipped) = organizationSteps(cfg, slug, curve)
  result.skipped = skipped
  for s in steps:
    let r = k.create(s.kind, s.namespace, s.obj)
    if r.outcome == oFailed:
      result.failedStep = s.name
      result.error = r.detail
      return
    result.steps.add StepResult(name: s.name, outcome: r.outcome)
  result.ok = true

proc disable*(k: KubeApi; cfg: ProvisionConfig; slug: string): ProvisionResult =
  ## switching an organisation off: its Ingress and its controller go, the namespace and its data stay
  let ns = orgNamespace(cfg, slug)
  result.ok = true
  proc drop(name, kind, namespace, objName: string; res: var ProvisionResult) =
    if not res.ok: return
    let r = k.remove(kind, namespace, objName)
    if r.outcome == oFailed:
      res.ok = false
      res.failedStep = name
      res.error = r.detail
    else:
      res.steps.add StepResult(name: name, outcome: r.outcome)
  if cfg.multi: drop("ingress", "Ingress", cfg.shardNamespace, ingressName(slug), result)
  drop("controller", "Deployment", ns, controllerName, result)

proc purge*(k: KubeApi; cfg: ProvisionConfig; slug: string): ProvisionResult =
  ## deleting for good: the Ingress, then the namespace, which takes the controller, the volumes and the rest with it
  result = disable(k, cfg, slug)
  if not result.ok: return
  let r = k.remove("Namespace", "", orgNamespace(cfg, slug))
  if r.outcome == oFailed:
    result.ok = false
    result.failedStep = "namespace"
    result.error = r.detail
  else:
    result.steps.add StepResult(name: "namespace", outcome: r.outcome)

proc loadCurve*(certs: string): CurveKeys =
  ## the keys the core itself holds for the transport (D-24), to hand to the controller of an organisation
  let d = certs / "curve"
  CurveKeys(corePub: readFile(d / "core.pub").strip, clientPub: readFile(d / "client.pub").strip,
            clientKey: readFile(d / "client.key").strip)
