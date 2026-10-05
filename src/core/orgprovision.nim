## SHD-007: the Kubernetes objects of an organisation, and, when the shard has a build profile, of its build namespace. Creating one is the ordered list below, each create idempotent (an object that
## exists is as good as a created one), so that a retry after a failure and the reconciliation (SHD-008) do the same thing. Nothing is
## ever deleted except by `disable` (the Ingress and the controller) and `purge` (the namespace and, with it, everything in it), both
## on the explicit request of an administrator. The objects are plain JSON: the tests compare them, the API server validates them.
import std/[json, os, strutils]
import kubeapi, orgrules

const
  controllerName* = "cinim-job-controller"      ## the ServiceAccount, the Deployment and the label of the organisation's controller
  curveSecretName* = "cinim-controller-curve"
  bootstrapSecretName* = "cinim-controller-bootstrap"   ## the one-time token with which the controller enrols (IAM-003, common/ctrlauth.nim)
  stateClaimName* = "cinim-job-controller-state"
  coreServiceName* = "cinim-core"               ## the Service of the core in the namespace of the shard (chart cinim-shard)

type
  NsKind* = enum
    nkOrg,      ## the namespace of the organisation: Pod Security `restricted`, the steps of ordinary jobs
    nkBuild     ## the build profile: `<org namespace>-build`, Pod Security `baseline`, steps that build images (A.13, Q-17)

  ProvisionConfig* = object
    prefix*, shard*, shardNamespace*: string    ## SHD-001; the namespace of the shard is the one the core itself runs in
    controllerImage*: string                    ## "" leaves the controller out (reported, not an error)
    stateClass*: string                         ## StorageClass of the controller's state volume; "" is the cluster default
    multi*: bool                                ## `multi` mode: the core makes the Ingress of an organisation
    host*, basePath*: string                    ## of the public URL: https://<host><basePath>/<slug>/
    ingressClass*, tlsSecret*: string
    annotations*: JsonNode                      ## of the Ingress, an object or nil
    build*: bool                                ## the shard has a build profile: every organisation gets a build namespace too
    buildEgress*: JsonNode                      ## NetworkPolicy egress rules of the build namespace (the registry), an array or nil; none: closed
    buildInternet*: JsonNode                    ## {"ports": [...], "except": [...]}: a build may reach public addresses on these ports, the private
                                                ## ranges in `except` stay closed (package downloads: npm, deb, maven...); nil: no internet
    buildCaps*, buildMemoryLimit*: string       ## what the build controller keeps of the capabilities (comma separated) and the memory limit of a build Pod; "" is its default

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

func buildNamespace*(cfg: ProvisionConfig; slug: string): string = buildNamespaceName(cfg.prefix, cfg.shard, slug)

func kindNamespace*(cfg: ProvisionConfig; slug: string; kind: NsKind): string =
  if kind == nkBuild: buildNamespace(cfg, slug) else: orgNamespace(cfg, slug)

func ingressName*(slug: string): string = "org-" & slug

func coreAddress(cfg: ProvisionConfig; port: int): string =
  "tcp://" & coreServiceName & "." & cfg.shardNamespace & ".svc:" & $port

func labels(cfg: ProvisionConfig; slug: string; component = ""; kind = nkOrg): JsonNode =
  result = %*{"app.kubernetes.io/part-of": "cinim", "cinim.io/shard": cfg.shard, "cinim.io/organization": slug,
              "cinim.io/profile": (if kind == nkBuild: "build" else: "default")}
  if component.len > 0: result["app.kubernetes.io/name"] = %component

func meta(cfg: ProvisionConfig; slug, name, namespace: string; component = ""; kind = nkOrg): JsonNode =
  result = %*{"name": name, "labels": labels(cfg, slug, component, kind)}
  if namespace.len > 0: result["namespace"] = %namespace

func namespaceObject(cfg: ProvisionConfig; slug: string; kind: NsKind): JsonNode =
  var l = labels(cfg, slug, "", kind)
  # the build namespace is `baseline`: Kaniko needs root in its container (A.13); everything else about it is held down by the
  # capabilities the step Pod keeps, the user namespace it runs in and the network policy
  for mode in ["enforce", "audit", "warn"]: l["pod-security.kubernetes.io/" & mode] = %(if kind == nkBuild: "baseline" else: "restricted")
  %*{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": kindNamespace(cfg, slug, kind), "labels": l}}

func controllerDeployment(cfg: ProvisionConfig; slug: string; kind: NsKind): JsonNode =
  let ns = kindNamespace(cfg, slug, kind)
  var env = @[
    %*{"name": "CINIM_NAMESPACE", "value": ns},
    %*{"name": "CINIM_CORE_ADDR", "value": coreAddress(cfg, 19740)},
    %*{"name": "CINIM_COLLECTOR_ADDR", "value": coreAddress(cfg, 19743)},
    %*{"name": "CINIM_STEPREPORT_ADDR", "value": coreAddress(cfg, 19742)},
    %*{"name": "CINIM_CERTS", "value": "/etc/cinim"},
    %*{"name": "CINIM_STATE_DIR", "value": "/state"},
    %*{"name": "CINIM_BOOTSTRAP_FILE", "value": "/etc/cinim/bootstrap/token"}]
  if kind == nkBuild:
    env.add %*{"name": "CINIM_STEP_SECURITY", "value": "build"}     # the controller makes build Pods (k8s.nim)
    if cfg.buildCaps.len > 0: env.add %*{"name": "CINIM_BUILD_CAPS", "value": cfg.buildCaps}
    if cfg.buildMemoryLimit.len > 0: env.add %*{"name": "CINIM_BUILD_MEMORY_LIMIT", "value": cfg.buildMemoryLimit}
  %*{"apiVersion": "apps/v1", "kind": "Deployment", "metadata": meta(cfg, slug, controllerName, ns, controllerName, kind),
     "spec": {
       "replicas": 1,
       "strategy": {"type": "Recreate"},       # one state volume, one writer
       "selector": {"matchLabels": {"app.kubernetes.io/name": controllerName, "cinim.io/organization": slug}},
       "template": {
         "metadata": {"labels": labels(cfg, slug, controllerName, kind)},
         "spec": {
           "serviceAccountName": controllerName,
           "securityContext": {"runAsNonRoot": true, "runAsUser": 65532, "fsGroup": 65532, "seccompProfile": {"type": "RuntimeDefault"}},
           "containers": [{
             "name": "controller",
             "image": cfg.controllerImage,
             "env": env,
             "volumeMounts": [
               {"name": "curve", "mountPath": "/etc/cinim/curve", "readOnly": true},
               {"name": "bootstrap", "mountPath": "/etc/cinim/bootstrap", "readOnly": true},
               {"name": "state", "mountPath": "/state"},
               {"name": "tmp", "mountPath": "/tmp"}],
             "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}},
             "resources": {"requests": {"cpu": "20m", "memory": "64Mi"}, "limits": {"memory": "256Mi"}}}],
           "volumes": [
             {"name": "curve", "secret": {"secretName": curveSecretName, "defaultMode": 288}},   # 0440
             {"name": "bootstrap", "secret": {"secretName": bootstrapSecretName, "defaultMode": 288}},
             {"name": "state", "persistentVolumeClaim": {"claimName": stateClaimName}},
             {"name": "tmp", "emptyDir": {}}]}}}}

func stateClaim(cfg: ProvisionConfig; slug: string; kind: NsKind): JsonNode =
  result = %*{"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": meta(cfg, slug, stateClaimName, kindNamespace(cfg, slug, kind), "", kind),
              "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}}}
  if cfg.stateClass.len > 0: result["spec"]["storageClassName"] = %cfg.stateClass

func networkPolicies(cfg: ProvisionConfig; slug: string; kind: NsKind): seq[JsonNode] =
  ## SEC-003: the Pods of steps get default-deny; DNS and the log collector and the scheduler of the shard stay open to them.
  ## The controller is not a step Pod and is left out of the egress policies: its egress goes to the API server, which a
  ## NetworkPolicy cannot name in a portable way (Cilium keeps node addresses out of `ipBlock`); its ingress is closed instead.
  let ns = kindNamespace(cfg, slug, kind)
  let core = %*{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": cfg.shardNamespace}},
                "podSelector": {"matchLabels": {"app.kubernetes.io/name": coreServiceName}}}
  let steps = %*{"matchExpressions": [{"key": "app.kubernetes.io/name", "operator": "NotIn", "values": [controllerName]}]}
  result = @[%*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "default-deny", ns, "", kind),
       "spec": {"podSelector": steps, "policyTypes": ["Ingress", "Egress"]}},
    %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "allow-dns-and-collector", ns, "", kind),
       "spec": {"podSelector": steps, "policyTypes": ["Egress"], "egress": [
         {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                  "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
          "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
         {"to": [core], "ports": [{"protocol": "TCP", "port": 19742}, {"protocol": "TCP", "port": 19743}]}]}},
    %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "controller-no-ingress", ns, "", kind),
       "spec": {"podSelector": {"matchLabels": {"app.kubernetes.io/name": controllerName}}, "policyTypes": ["Ingress"]}}]
  if kind == nkBuild and cfg.buildInternet != nil and cfg.buildInternet.kind == JObject:
    # a build downloads packages all the time (npm, deb, maven, go modules, git): it may reach the public internet, on the ports given,
    # and nothing inside: the private ranges (the cluster's pods and services, the LAN, the link-local metadata address) are excepted
    var ports = newJArray()
    if cfg.buildInternet.hasKey("ports"):
      for p in cfg.buildInternet["ports"]: ports.add %*{"protocol": "TCP", "port": p}
    var peer = %*{"ipBlock": {"cidr": "0.0.0.0/0", "except": (if cfg.buildInternet.hasKey("except"): cfg.buildInternet["except"] else: newJArray())}}
    var rule = %*{"to": [peer]}
    if ports.len > 0: rule["ports"] = ports
    result.add %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "allow-build-internet", ns, "", kind),
                  "spec": {"podSelector": steps, "policyTypes": ["Egress"], "egress": [rule]}}
  if kind == nkBuild and cfg.buildEgress != nil and cfg.buildEgress.kind == JArray and cfg.buildEgress.len > 0:
    # what a build may reach beyond DNS and the collector: the registry that holds the base images and receives the result, set by
    # the operator; with nothing set a build can reach nothing else
    result.add %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "allow-build-egress", ns, "", kind),
                  "spec": {"podSelector": steps, "policyTypes": ["Egress"], "egress": cfg.buildEgress}}

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

func namespaceSteps(cfg: ProvisionConfig; slug: string; kind: NsKind; curve: CurveKeys; bootstrapToken: string): tuple[steps: seq[Step], skipped: seq[string]] =
  ## the objects of one namespace of an organisation, SHD-007 (2)..(4), in the order of the specification; the names of the steps of the
  ## build namespace start with "build"
  let ns = kindNamespace(cfg, slug, kind)
  let tag = if kind == nkBuild: "build " else: ""
  func step(name, kind, namespace, objName: string; obj: JsonNode): Step =
    Step(name: name, kind: kind, namespace: namespace, objectName: objName, obj: obj)
  result.steps.add step(tag & "namespace", "Namespace", "", ns, namespaceObject(cfg, slug, kind))
  if cfg.controllerImage.len > 0:
    result.steps.add step(tag & "controller service account", "ServiceAccount", ns, controllerName,
      %*{"apiVersion": "v1", "kind": "ServiceAccount", "metadata": meta(cfg, slug, controllerName, ns, "", kind), "automountServiceAccountToken": true})
    result.steps.add step(tag & "controller role binding", "RoleBinding", ns, controllerName,
      %*{"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": meta(cfg, slug, controllerName, ns, "", kind),
         "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": stepRunnerRole(cfg)},
         "subjects": [{"kind": "ServiceAccount", "name": controllerName, "namespace": ns}]})
    result.steps.add step(tag & "controller keys", "Secret", ns, curveSecretName,
      %*{"apiVersion": "v1", "kind": "Secret", "metadata": meta(cfg, slug, curveSecretName, ns, "", kind), "type": "Opaque",
         "stringData": {"core.pub": curve.corePub, "client.pub": curve.clientPub, "client.key": curve.clientKey}})
    result.steps.add step(tag & "controller bootstrap token", "Secret", ns, bootstrapSecretName,
      %*{"apiVersion": "v1", "kind": "Secret", "metadata": meta(cfg, slug, bootstrapSecretName, ns, "", kind), "type": "Opaque",
         "stringData": {"token": bootstrapToken}})
    result.steps.add step(tag & "controller state volume", "PersistentVolumeClaim", ns, stateClaimName, stateClaim(cfg, slug, kind))
    result.steps.add step(tag & "controller", "Deployment", ns, controllerName, controllerDeployment(cfg, slug, kind))
  else:
    result.skipped.add tag & "job controller: CINIM_CONTROLLER_IMAGE is not set"
  result.steps.add step(tag & "resource quota", "ResourceQuota", ns, "cinim-default",
    %*{"apiVersion": "v1", "kind": "ResourceQuota", "metadata": meta(cfg, slug, "cinim-default", ns, "", kind),
       "spec": {"hard": {"pods": "100", "requests.cpu": "16", "requests.memory": "32Gi", "limits.memory": "64Gi",
                         "persistentvolumeclaims": "50", "requests.storage": "500Gi"}}})
  # a build Pod gets a roomier default than an ordinary step: an image build is the memory-hungry step
  let defaults = if kind == nkBuild: %*{"default": {"memory": "4Gi"}, "defaultRequest": {"cpu": "250m", "memory": "512Mi"}, "max": {"memory": "32Gi"}}
                 else: %*{"default": {"memory": "1Gi"}, "defaultRequest": {"cpu": "100m", "memory": "128Mi"}, "max": {"memory": "32Gi"}}
  defaults["type"] = %"Container"
  result.steps.add step(tag & "limit range", "LimitRange", ns, "cinim-default",
    %*{"apiVersion": "v1", "kind": "LimitRange", "metadata": meta(cfg, slug, "cinim-default", ns, "", kind), "spec": {"limits": [defaults]}})
  for p in networkPolicies(cfg, slug, kind):
    result.steps.add step(tag & "network policy " & p["metadata"]["name"].getStr, "NetworkPolicy", ns, p["metadata"]["name"].getStr, p)

func organizationSteps*(cfg: ProvisionConfig; slug: string; curve: CurveKeys; bootstrapToken: string;
                        buildToken = ""): tuple[steps: seq[Step], skipped: seq[string]] =
  ## SHD-007 (2)..(5) for the namespace of the organisation, its Ingress in the `multi` mode, and, when the shard has a build
  ## profile, the same objects for the build namespace with its own controller and its own bootstrap token
  result = namespaceSteps(cfg, slug, nkOrg, curve, bootstrapToken)
  if cfg.multi:
    result.steps.add Step(name: "ingress", kind: "Ingress", namespace: cfg.shardNamespace, objectName: ingressName(slug), obj: ingressObject(cfg, slug))
  if cfg.build:
    let b = namespaceSteps(cfg, slug, nkBuild, curve, buildToken)
    result.steps.add b.steps
    result.skipped.add b.skipped

proc provision*(k: KubeApi; cfg: ProvisionConfig; slug: string; curve: CurveKeys; bootstrapToken: string;
                buildToken = ""): ProvisionResult =
  ## stops at the first failure and says which step it was; what was created stays (a retry creates the rest)
  let (steps, skipped) = organizationSteps(cfg, slug, curve, bootstrapToken, buildToken)
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
  if cfg.build: drop("build controller", "Deployment", buildNamespace(cfg, slug), controllerName, result)

proc purge*(k: KubeApi; cfg: ProvisionConfig; slug: string): ProvisionResult =
  ## deleting for good: the Ingress, then the namespace, which takes the controller, the volumes and the rest with it
  result = disable(k, cfg, slug)
  if not result.ok: return
  for (name, ns) in [("namespace", orgNamespace(cfg, slug)), ("build namespace", buildNamespace(cfg, slug))]:
    if name == "build namespace" and not cfg.build: continue
    let r = k.remove("Namespace", "", ns)
    if r.outcome == oFailed:
      result.ok = false
      result.failedStep = name
      result.error = r.detail
      return
    result.steps.add StepResult(name: name, outcome: r.outcome)

proc coreSecret*(certs: string): string =
  ## the core's own secret key: the master of the controller identities (common/ctrlauth.nim); it leaves the core nowhere
  readFile(certs / "curve" / "core.key").strip

proc loadCurve*(certs: string): CurveKeys =
  ## the keys the core itself holds for the transport (D-24), to hand to the controller of an organisation
  let d = certs / "curve"
  CurveKeys(corePub: readFile(d / "core.pub").strip, clientPub: readFile(d / "client.pub").strip,
            clientKey: readFile(d / "client.key").strip)

proc renewBootstrapSecret*(k: KubeApi; cfg: ProvisionConfig; slug, bootstrapToken: string; kind = nkOrg): ProvisionResult =
  ## after a rotation of the controller's identity: the Secret with the new bootstrap token replaces the old one (the core may
  ## create and delete Secrets, not read or change them)
  let ns = kindNamespace(cfg, slug, kind)
  let gone = k.remove("Secret", ns, bootstrapSecretName)
  if gone.outcome == oFailed:
    return ProvisionResult(ok: false, failedStep: "remove the old bootstrap token", error: gone.detail)
  let made = k.create("Secret", ns, %*{"apiVersion": "v1", "kind": "Secret", "metadata": meta(cfg, slug, bootstrapSecretName, ns, "", kind),
                                       "type": "Opaque", "stringData": {"token": bootstrapToken}})
  if made.outcome == oFailed:
    return ProvisionResult(ok: false, failedStep: "create the new bootstrap token", error: made.detail)
  ProvisionResult(ok: true, steps: @[StepResult(name: "controller bootstrap token", outcome: made.outcome)])
