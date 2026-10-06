## SHD-007: the Kubernetes objects of an organisation. Creating one is the ordered list below, each create idempotent (an object that
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
  ProvisionConfig* = object
    prefix*, shard*, shardNamespace*: string    ## SHD-001; the namespace of the shard is the one the core itself runs in
    controllerImage*: string                    ## "" leaves the controller out (reported, not an error)
    stateClass*: string                         ## StorageClass of the controller's state volume; "" is the cluster default
    multi*: bool                                ## `multi` mode: the core makes the Ingress of an organisation
    host*, basePath*: string                    ## of the public URL: https://<host><basePath>/<slug>/
    ingressClass*, tlsSecret*: string
    annotations*: JsonNode                      ## of the Ingress, an object or nil
    build*: bool                                ## the shard has a build profile (D-42): the namespace is `baseline` under the build-pod policy, and steps that
                                                ## ask for `profile = "build"` run as build Pods in it
    buildEgress*: JsonNode                      ## NetworkPolicy egress rules of the build Pods (the registry, a Nexus, ...), an array or nil (none: closed);
                                                ## the string "all": build Pods may reach any address, private ones too
    buildInternet*: JsonNode                    ## {"ports": [...], "except": [...]}: a build may reach public addresses on these ports, the private
                                                ## ranges in `except` stay closed (package downloads: npm, deb, maven...); nil: no internet
    buildIngressAll*: bool                      ## build Pods may be reached from any address (`build.ingress: all`); the other steps stay closed
    buildCaps*, buildMemoryLimit*: string       ## what the controller keeps of the capabilities of a build Pod (comma separated) and its memory limit; "" is its default
    egressOpen*, ingressOpen*: bool             ## the simple mode for a small organisation (SHD-009): its step Pods may reach any address / be reached from any;
                                                ## the default is closed both ways, with the openings of the build profile
    buildSeccomp*: string                       ## `RuntimeDefault` (Kaniko) or `Localhost` (rootless BuildKit and Buildah, deploy/seccomp); "" is the controller's default

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
  ## `cinim.io/profile=build` is not among them: it marks a build Pod, which only the job controller may make (the admission policy)
  result = %*{"app.kubernetes.io/part-of": "cinim", "cinim.io/shard": cfg.shard, "cinim.io/organization": slug}
  if component.len > 0: result["app.kubernetes.io/name"] = %component

func meta(cfg: ProvisionConfig; slug, name, namespace: string; component = ""): JsonNode =
  result = %*{"name": name, "labels": labels(cfg, slug, component)}
  if namespace.len > 0: result["namespace"] = %namespace

func namespaceObject(cfg: ProvisionConfig; slug: string): JsonNode =
  var l = labels(cfg, slug)
  if cfg.build:
    # D-42: `baseline` by label, because a build Pod needs root in its container (A.13), and the ValidatingAdmissionPolicy of the chart
    # (selected by the label below) gives every Pod but a build Pod what `restricted` has over `baseline`. `audit` and `warn` stay
    # at `restricted`: what the policy would not allow shows up there.
    l["pod-security.kubernetes.io/enforce"] = %"baseline"
    l["cinim.io/build-pod-policy"] = %"on"
  else:
    l["pod-security.kubernetes.io/enforce"] = %"restricted"
  for mode in ["audit", "warn"]: l["pod-security.kubernetes.io/" & mode] = %"restricted"
  %*{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": orgNamespace(cfg, slug), "labels": l}}

func controllerDeployment(cfg: ProvisionConfig; slug: string): JsonNode =
  let ns = orgNamespace(cfg, slug)
  var env = @[
    %*{"name": "CINIM_NAMESPACE", "value": ns},
    %*{"name": "CINIM_CORE_ADDR", "value": coreAddress(cfg, 19740)},
    %*{"name": "CINIM_COLLECTOR_ADDR", "value": coreAddress(cfg, 19743)},
    %*{"name": "CINIM_STEPREPORT_ADDR", "value": coreAddress(cfg, 19742)},
    %*{"name": "CINIM_CERTS", "value": "/etc/cinim"},
    %*{"name": "CINIM_STATE_DIR", "value": "/state"},
    %*{"name": "CINIM_BOOTSTRAP_FILE", "value": "/etc/cinim/bootstrap/token"}]
  if cfg.build:
    env.add %*{"name": "CINIM_BUILD", "value": "on"}     # the controller makes a build Pod of a step of the build profile (k8s.nim)
    if cfg.buildSeccomp.len > 0: env.add %*{"name": "CINIM_BUILD_SECCOMP", "value": cfg.buildSeccomp}
    if cfg.buildCaps.len > 0: env.add %*{"name": "CINIM_BUILD_CAPS", "value": cfg.buildCaps}
    if cfg.buildMemoryLimit.len > 0: env.add %*{"name": "CINIM_BUILD_MEMORY_LIMIT", "value": cfg.buildMemoryLimit}
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
  result = @[%*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "default-deny", ns),
       "spec": {"podSelector": steps, "policyTypes": ["Ingress", "Egress"]}},
    %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "allow-dns-and-collector", ns),
       "spec": {"podSelector": steps, "policyTypes": ["Egress"], "egress": [
         {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                  "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
          "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
         {"to": [core], "ports": [{"protocol": "TCP", "port": 19742}, {"protocol": "TCP", "port": 19743}]}]}},
    %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "controller-no-ingress", ns),
       "spec": {"podSelector": {"matchLabels": {"app.kubernetes.io/name": controllerName}}, "policyTypes": ["Ingress"]}}]
  # the simple mode: one more policy each, which adds to the default-deny (policies are only ever added together), for every step Pod. The
  # controller is not among them: it keeps its own closed ingress.
  if cfg.egressOpen:
    result.add %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "allow-all-egress", ns),
                  "spec": {"podSelector": steps, "policyTypes": ["Egress"], "egress": [{}]}}
  if cfg.ingressOpen:
    result.add %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "allow-all-ingress", ns),
                  "spec": {"podSelector": steps, "policyTypes": ["Ingress"], "ingress": [{}]}}
  let builds = %*{"matchLabels": {"cinim.io/profile": "build"}}     # the build Pods only: the other steps of the organisation get none of this
  if cfg.build and cfg.buildIngressAll and not cfg.ingressOpen:
    result.add %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "allow-build-ingress", ns),
                  "spec": {"podSelector": builds, "policyTypes": ["Ingress"], "ingress": [{}]}}
  let buildAll = cfg.buildEgress != nil and cfg.buildEgress.kind == JString and cfg.buildEgress.getStr == "all"
  # with every address open (for all step Pods, or for the build Pods) the internet rule of the build profile says nothing more
  if cfg.build and not cfg.egressOpen and not buildAll and cfg.buildInternet != nil and cfg.buildInternet.kind == JObject:
    # a build downloads packages all the time (npm, deb, maven, go modules, git): it may reach the public internet, on the ports given,
    # and nothing inside: the private ranges (the cluster's pods and services, the LAN, the link-local metadata address) are excepted
    var ports = newJArray()
    if cfg.buildInternet.hasKey("ports"):
      for p in cfg.buildInternet["ports"]: ports.add %*{"protocol": "TCP", "port": p}
    var peer = %*{"ipBlock": {"cidr": "0.0.0.0/0", "except": (if cfg.buildInternet.hasKey("except"): cfg.buildInternet["except"] else: newJArray())}}
    var rule = %*{"to": [peer]}
    if ports.len > 0: rule["ports"] = ports
    result.add %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "allow-build-internet", ns),
                  "spec": {"podSelector": builds, "policyTypes": ["Egress"], "egress": [rule]}}
  if cfg.build and not cfg.egressOpen and buildAll:
    result.add %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "allow-build-egress", ns),
                  "spec": {"podSelector": builds, "policyTypes": ["Egress"], "egress": [{}]}}
  elif cfg.build and not cfg.egressOpen and cfg.buildEgress != nil and cfg.buildEgress.kind == JArray and cfg.buildEgress.len > 0:
    # what a build may reach beyond DNS and the collector: the registry that holds the base images and receives the result, set by
    # the operator; with nothing set a build can reach nothing else
    result.add %*{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(cfg, slug, "allow-build-egress", ns),
                  "spec": {"podSelector": builds, "policyTypes": ["Egress"], "egress": cfg.buildEgress}}

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

func organizationSteps*(cfg: ProvisionConfig; slug: string; curve: CurveKeys; bootstrapToken: string): tuple[steps: seq[Step], skipped: seq[string]] =
  ## SHD-007 (2)..(5): the objects of the namespace of the organisation, in the order of the specification, and its Ingress in the `multi` mode.
  ## Builds (D-42) need none of their own: a build Pod is made by the same controller, in the same namespace.
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
    result.steps.add step("controller bootstrap token", "Secret", ns, bootstrapSecretName,
      %*{"apiVersion": "v1", "kind": "Secret", "metadata": meta(cfg, slug, bootstrapSecretName, ns), "type": "Opaque",
         "stringData": {"token": bootstrapToken}})
    result.steps.add step("controller state volume", "PersistentVolumeClaim", ns, stateClaimName, stateClaim(cfg, slug))
    result.steps.add step("controller", "Deployment", ns, controllerName, controllerDeployment(cfg, slug))
  else:
    result.skipped.add "job controller: CINIM_CONTROLLER_IMAGE is not set"
  result.steps.add step("resource quota", "ResourceQuota", ns, "cinim-default",
    %*{"apiVersion": "v1", "kind": "ResourceQuota", "metadata": meta(cfg, slug, "cinim-default", ns),
       "spec": {"hard": {"pods": "100", "requests.cpu": "16", "requests.memory": "32Gi", "limits.memory": "64Gi",
                         "persistentvolumeclaims": "50", "requests.storage": "500Gi"}}})
  # a build Pod sets its own memory request and limit (k8s.nim); the defaults are those of an ordinary step
  result.steps.add step("limit range", "LimitRange", ns, "cinim-default",
    %*{"apiVersion": "v1", "kind": "LimitRange", "metadata": meta(cfg, slug, "cinim-default", ns), "spec": {"limits": [
      {"type": "Container", "default": {"memory": "1Gi"}, "defaultRequest": {"cpu": "100m", "memory": "128Mi"}, "max": {"memory": "32Gi"}}]}})
  for p in networkPolicies(cfg, slug):
    result.steps.add step("network policy " & p["metadata"]["name"].getStr, "NetworkPolicy", ns, p["metadata"]["name"].getStr, p)
  if cfg.multi:
    result.steps.add Step(name: "ingress", kind: "Ingress", namespace: cfg.shardNamespace, objectName: ingressName(slug), obj: ingressObject(cfg, slug))

proc provision*(k: KubeApi; cfg: ProvisionConfig; slug: string; curve: CurveKeys; bootstrapToken: string): ProvisionResult =
  ## stops at the first failure and says which step it was; what was created stays (a retry creates the rest)
  let (steps, skipped) = organizationSteps(cfg, slug, curve, bootstrapToken)
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
    return
  result.steps.add StepResult(name: "namespace", outcome: r.outcome)

proc coreSecret*(certs: string): string =
  ## the core's own secret key: the master of the controller identities (common/ctrlauth.nim); it leaves the core nowhere
  readFile(certs / "curve" / "core.key").strip

proc loadCurve*(certs: string): CurveKeys =
  ## the keys the core itself holds for the transport (D-24), to hand to the controller of an organisation
  let d = certs / "curve"
  CurveKeys(corePub: readFile(d / "core.pub").strip, clientPub: readFile(d / "client.pub").strip,
            clientKey: readFile(d / "client.key").strip)

proc renewBootstrapSecret*(k: KubeApi; cfg: ProvisionConfig; slug, bootstrapToken: string): ProvisionResult =
  ## after a rotation of the controller's identity: the Secret with the new bootstrap token replaces the old one (the core may
  ## create and delete Secrets, not read or change them)
  let ns = orgNamespace(cfg, slug)
  let gone = k.remove("Secret", ns, bootstrapSecretName)
  if gone.outcome == oFailed:
    return ProvisionResult(ok: false, failedStep: "remove the old bootstrap token", error: gone.detail)
  let made = k.create("Secret", ns, %*{"apiVersion": "v1", "kind": "Secret", "metadata": meta(cfg, slug, bootstrapSecretName, ns),
                                       "type": "Opaque", "stringData": {"token": bootstrapToken}})
  if made.outcome == oFailed:
    return ProvisionResult(ok: false, failedStep: "create the new bootstrap token", error: made.detail)
  ProvisionResult(ok: true, steps: @[StepResult(name: "controller bootstrap token", outcome: made.outcome)])
