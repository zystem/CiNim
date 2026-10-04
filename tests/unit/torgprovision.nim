## SHD-007: the Kubernetes objects of an organisation and the order they are made in, against a fake API (no cluster).
import std/[unittest, json, strutils, tables, sequtils]
import ../../src/core/[kubeapi, orgprovision]

type Fake = ref object
  calls: seq[string]                 ## "METHOD path"
  bodies: Table[string, JsonNode]    ## path of the POSTed collection -> the last body
  exists: seq[string]                ## collection paths that answer 409
  fail: string                       ## a collection path that answers 403
  absent: seq[string]                ## object paths that answer 404 on DELETE

proc api(f: Fake): KubeApi =
  KubeApi(transport: proc (meth, path, body: string): tuple[code: int, body: string] =
    f.calls.add meth & " " & path
    if meth == "POST":
      f.bodies[path] = parseJson(body)
      if path == f.fail: return (403, $(%*{"kind": "Status", "message": "namespaces is forbidden: nope"}))
      if path in f.exists: return (409, "{}")
      return (201, "{}")
    if path in f.absent: return (404, "{}")
    (200, "{}"))

let curve = CurveKeys(corePub: "CP", clientPub: "LP", clientKey: "LK")
proc cfg(multi = false, image = "reg/ctl:1"): ProvisionConfig =
  ProvisionConfig(prefix: "cinim", shard: "001", shardNamespace: "cinim-001", controllerImage: image, multi: multi,
                  host: "ci.example.com", basePath: "/", ingressClass: "nginx", annotations: %*{"a/b": "c"})

suite "SHD-007 the objects of an organisation":
  test "the namespace is <prefix>-<shard>-<slug> with Pod Security restricted and the labels of the shard":
    let ns = organizationSteps(cfg(), "acme", curve, "BT").steps[0].obj
    check ns["metadata"]["name"].getStr == "cinim-001-acme"
    for m in ["enforce", "audit", "warn"]: check ns["metadata"]["labels"]["pod-security.kubernetes.io/" & m].getStr == "restricted"
    check ns["metadata"]["labels"]["cinim.io/shard"].getStr == "001" and ns["metadata"]["labels"]["cinim.io/organization"].getStr == "acme"
  test "the controller's role binding gives the step role of the shard in that namespace only":
    var rb: JsonNode
    for s in organizationSteps(cfg(), "acme", curve, "BT").steps:
      if s.kind == "RoleBinding": rb = s.obj
    check rb["kind"].getStr == "RoleBinding" and rb["roleRef"]["kind"].getStr == "ClusterRole"
    check rb["roleRef"]["name"].getStr == "cinim-001-step-runner"
    check rb["subjects"][0]["namespace"].getStr == "cinim-001-acme" and rb["metadata"]["namespace"].getStr == "cinim-001-acme"
  test "the controller reaches the core of the shard and keeps its state on a volume":
    var d: JsonNode
    for s in organizationSteps(cfg(), "acme", curve, "BT").steps:
      if s.kind == "Deployment": d = s.obj
    let c = d["spec"]["template"]["spec"]["containers"][0]
    check c["image"].getStr == "reg/ctl:1"
    var env = initTable[string, string]()
    for e in c["env"]: env[e["name"].getStr] = e["value"].getStr
    check env["CINIM_NAMESPACE"] == "cinim-001-acme"
    check env["CINIM_CORE_ADDR"] == "tcp://cinim-core.cinim-001.svc:19740"
    check env["CINIM_COLLECTOR_ADDR"] == "tcp://cinim-core.cinim-001.svc:19743" and env["CINIM_STEPREPORT_ADDR"] == "tcp://cinim-core.cinim-001.svc:19742"
    check d["spec"]["strategy"]["type"].getStr == "Recreate"
    var claim = ""
    for v in d["spec"]["template"]["spec"]["volumes"]:
      if v.hasKey("persistentVolumeClaim"): claim = v["persistentVolumeClaim"]["claimName"].getStr
    check claim == "cinim-job-controller-state"
    check c["securityContext"]["readOnlyRootFilesystem"].getBool and d["spec"]["template"]["spec"]["securityContext"]["runAsNonRoot"].getBool
  test "the keys of the transport go into a Secret of the namespace, the core's secret key stays out":
    var s: JsonNode
    for st in organizationSteps(cfg(), "acme", curve, "BT").steps:
      if st.objectName == "cinim-controller-curve": s = st.obj
    check s["stringData"]["core.pub"].getStr == "CP" and s["stringData"]["client.key"].getStr == "LK"
    check not s["stringData"].hasKey("core.key")
  test "the one-time bootstrap token is a Secret of the namespace, mounted where the controller looks for it":
    let steps = organizationSteps(cfg(), "acme", curve, "BT-TOKEN").steps
    var secret, d: JsonNode
    var secretAt, deploymentAt = -1
    for i, st in steps:
      if st.objectName == "cinim-controller-bootstrap": (secret = st.obj; secretAt = i)
      if st.kind == "Deployment": (d = st.obj; deploymentAt = i)
    check secret["stringData"]["token"].getStr == "BT-TOKEN" and secret["metadata"]["namespace"].getStr == "cinim-001-acme"
    check secretAt >= 0 and secretAt < deploymentAt       # before the Deployment that mounts it
    let c = d["spec"]["template"]["spec"]["containers"][0]
    var file = ""
    for e in c["env"]:
      if e["name"].getStr == "CINIM_BOOTSTRAP_FILE": file = e["value"].getStr
    check file == "/etc/cinim/bootstrap/token"
    var mounted = false
    for m in c["volumeMounts"]:
      if m["mountPath"].getStr == "/etc/cinim/bootstrap": mounted = true
    check mounted
  test "a quota, a limit range and three network policies, default-deny first":
    let steps = organizationSteps(cfg(), "acme", curve, "BT").steps
    var kinds: seq[string]
    for s in steps: kinds.add s.kind
    check "ResourceQuota" in kinds and "LimitRange" in kinds and kinds.count("NetworkPolicy") == 3
    var deny: JsonNode
    for s in steps:
      if s.objectName == "default-deny": deny = s.obj
    check deny["spec"]["policyTypes"].len == 2
    # the policies that restrict egress select the Pods of steps, never the controller (its way to the API server stays open)
    for s in steps:
      if s.kind == "NetworkPolicy" and "Egress" in $s.obj["spec"]["policyTypes"]:
        check s.obj["spec"]["podSelector"]["matchExpressions"][0]["operator"].getStr == "NotIn"
        check s.obj["spec"]["podSelector"]["matchExpressions"][0]["values"][0].getStr == "cinim-job-controller"
      if s.objectName == "controller-no-ingress":
        check s.obj["spec"]["policyTypes"].len == 1 and "Egress" notin $s.obj["spec"]["policyTypes"] and not s.obj["spec"].hasKey("ingress")
  test "the Ingress exists only in the multi mode, lives in the namespace of the shard and points at the core":
    check organizationSteps(cfg(false), "acme", curve, "BT").steps[^1].kind != "Ingress"
    let last = organizationSteps(cfg(true), "acme", curve, "BT").steps[^1]
    check last.kind == "Ingress" and last.namespace == "cinim-001" and last.objectName == "org-acme"
    let i = last.obj
    check i["spec"]["rules"][0]["host"].getStr == "ci.example.com" and i["spec"]["rules"][0]["http"]["paths"][0]["path"].getStr == "/acme"
    check i["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"]["name"].getStr == "cinim-core"
    check i["spec"]["ingressClassName"].getStr == "nginx" and i["metadata"]["annotations"]["a/b"].getStr == "c"
  test "with a base path the Ingress path carries it":
    var c = cfg(true)
    c.basePath = "/ci/"
    check organizationSteps(c, "acme", curve, "BT").steps[^1].obj["spec"]["rules"][0]["http"]["paths"][0]["path"].getStr == "/ci/acme"
  test "without a controller image the controller and what it needs are left out and the reason is given":
    let r = organizationSteps(cfg(image = ""), "acme", curve, "BT")
    for s in r.steps: check s.kind notin ["Deployment", "RoleBinding", "ServiceAccount", "PersistentVolumeClaim"]
    check r.skipped.len == 1 and "CINIM_CONTROLLER_IMAGE" in r.skipped[0]

suite "SHD-007 creating, switching off, deleting":
  test "everything is created in order, the namespace first":
    let f = Fake()
    let r = provision(api(f), cfg(true), "acme", curve, "BT")
    check r.ok and r.steps[0].name == "namespace" and r.steps[^1].name == "ingress"
    check f.calls[0] == "POST /api/v1/namespaces"
    check "POST /apis/apps/v1/namespaces/cinim-001-acme/deployments" in f.calls
    check "POST /apis/networking.k8s.io/v1/namespaces/cinim-001/ingresses" in f.calls
  test "an object that exists is as good as a created one, so a repeat succeeds":
    let f = Fake(exists: @["/api/v1/namespaces", "/apis/apps/v1/namespaces/cinim-001-acme/deployments"])
    let r = provision(api(f), cfg(), "acme", curve, "BT")
    check r.ok and r.steps[0].outcome == oExists
  test "a refusal stops there and names the step and the reason":
    let f = Fake(fail: "/api/v1/namespaces/cinim-001-acme/secrets")
    let r = provision(api(f), cfg(), "acme", curve, "BT")
    check not r.ok and r.failedStep == "controller keys" and r.error == "namespaces is forbidden: nope"
    check "POST /apis/apps/v1/namespaces/cinim-001-acme/deployments" notin f.calls
  test "switching off removes the Ingress and the controller and leaves the namespace":
    let f = Fake()
    let r = disable(api(f), cfg(true), "acme")
    check r.ok
    check f.calls == @["DELETE /apis/networking.k8s.io/v1/namespaces/cinim-001/ingresses/org-acme",
                       "DELETE /apis/apps/v1/namespaces/cinim-001-acme/deployments/cinim-job-controller"]
  test "an object that is already gone does not stop switching off":
    let f = Fake(absent: @["/apis/networking.k8s.io/v1/namespaces/cinim-001/ingresses/org-acme"])
    let r = disable(api(f), cfg(true), "acme")
    check r.ok and r.steps[0].outcome == oAbsent and r.steps.len == 2
  test "deleting for good removes the namespace last":
    let f = Fake()
    let r = purge(api(f), cfg(false), "acme")
    check r.ok and f.calls[^1] == "DELETE /api/v1/namespaces/cinim-001-acme"
  test "a new bootstrap token replaces the old Secret: removed first, then made":
    let f = Fake()
    let r = renewBootstrapSecret(api(f), cfg(), "acme", "NEW")
    check r.ok
    check f.calls == @["DELETE /api/v1/namespaces/cinim-001-acme/secrets/cinim-controller-bootstrap",
                       "POST /api/v1/namespaces/cinim-001-acme/secrets"]
    check f.bodies["/api/v1/namespaces/cinim-001-acme/secrets"]["stringData"]["token"].getStr == "NEW"
  test "the paths of the kinds the core handles":
    check collectionPath("Namespace", "") == "/api/v1/namespaces"
    check objectPath("RoleBinding", "x", "y") == "/apis/rbac.authorization.k8s.io/v1/namespaces/x/rolebindings/y"
    expect ValueError: discard collectionPath("Pod", "x")
