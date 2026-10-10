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
    check env["CINIM_CORE_STREAM_ADDR"] == "tcp://cinim-core.cinim-001.svc:19745"      # the push channel is the controller's way to the core
    check "CINIM_CORE_ADDR" notin env
    # what the controller needs to find the core and prove itself; the addresses for the shim and the policy come over the push channel (D-49)
    for name in ["CINIM_COLLECTOR_ADDR", "CINIM_STEPREPORT_ADDR", "CINIM_ARTIFACTINGEST_ADDR", "CINIM_LOGINGEST_ADDR", "CINIM_LOG_SPOOL_BYTES", "CINIM_LOG_HOLD_TIMEOUT",
                 "CINIM_POD_RETENTION_READ", "CINIM_POD_RETENTION_UNREAD"]:
      check name notin env
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

proc buildCfg(egress: JsonNode = nil): ProvisionConfig =
  result = cfg(true)
  result.build = true
  result.buildEgress = egress

suite "build profile (D-42): build Pods in the namespace of the organisation":
  let registry = %*[{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "registry"}}}],
                     "ports": [{"protocol": "TCP", "port": 5000}]}]
  proc namespaceOf(cfg: ProvisionConfig): JsonNode =
    for st in organizationSteps(cfg, "acme", curve, "BT").steps:
      if st.kind == "Namespace": return st.obj
  test "without a build profile there is one namespace, restricted, and no build setting anywhere":
    let steps = organizationSteps(cfg(true), "acme", curve, "BT").steps
    for st in steps:
      check "-build" notin st.objectName and "-build" notin st.namespace and st.objectName notin ["allow-build-internet", "allow-build-egress"]
      if st.kind == "Deployment":
        for e in st.obj["spec"]["template"]["spec"]["containers"][0]["env"]: check not e["name"].getStr.startsWith("CINIM_BUILD")
    check not namespaceOf(cfg(true))["metadata"]["labels"].hasKey("cinim.io/build-pod-policy")
  test "with one the namespace is baseline by label and carries the label of the admission policy, audit and warn stay restricted":
    let l = namespaceOf(buildCfg())["metadata"]["labels"]
    check l["pod-security.kubernetes.io/enforce"].getStr == "baseline"
    for m in ["audit", "warn"]: check l["pod-security.kubernetes.io/" & m].getStr == "restricted"
    check l["cinim.io/build-pod-policy"].getStr == "on"
  test "there is no second namespace and no second controller, and no object of the organisation is labelled as a build Pod":
    let steps = organizationSteps(buildCfg(registry), "acme", curve, "BT").steps
    var namespaces, deployments = 0
    for st in steps:
      if st.kind == "Namespace": inc namespaces
      if st.kind == "Deployment": inc deployments
      check st.obj["metadata"]["labels"]{"cinim.io/profile"} == nil     # that label marks a build Pod, which only the controller makes
      if st.kind == "Deployment": check st.obj["spec"]["template"]["metadata"]["labels"]{"cinim.io/profile"} == nil
    check namespaces == 1 and deployments == 1
  test "the settings of the shard do not reach the controller as environment (they come in the answers to its poll): its Deployment is the same whatever they are":
    var c = buildCfg()
    var env = initTable[string, string]()
    for st in organizationSteps(c, "acme", curve, "BT").steps:
      if st.kind == "Deployment":
        for e in st.obj["spec"]["template"]["spec"]["containers"][0]["env"]: env[e["name"].getStr] = e["value"].getStr
    check env["CINIM_NAMESPACE"] == "cinim-001-acme" and "CINIM_STEP_SECURITY" notin env
    for name in env.keys: check not name.startsWith("CINIM_BUILD") and not name.startsWith("CINIM_RUN_STORAGE")
    proc deployment(c: ProvisionConfig): string =
      for st in organizationSteps(c, "acme", curve, "BT").steps:
        if st.kind == "Deployment": return $st.obj
    check deployment(buildCfg()) == deployment(cfg())              # a build profile or not
  test "DAT-003 a step Pod reaches the core's artifact port and not the object store":
    var ports: seq[int]
    var toStore = false
    for st in organizationSteps(buildCfg(), "acme", curve, "BT").steps:
      if st.kind == "NetworkPolicy" and st.objectName == "allow-dns-and-collector":
        for r in st.obj["spec"]["egress"]:
          if r["to"][0]{"podSelector"}{"matchLabels"}{"app"}.getStr == "garage": toStore = true
          if r["to"][0]{"podSelector"}{"matchLabels"}{"app.kubernetes.io/name"}.getStr == "cinim-core":
            for p in r["ports"]: ports.add p["port"].getInt
    check 19744 in ports and 19742 in ports and 19743 in ports
    check not toStore
  test "without an internet setting a build Pod may reach DNS, the collector and what the operator opened, nothing else":
    var closed, opened: seq[string]
    for st in organizationSteps(buildCfg(), "acme", curve, "BT").steps:
      if st.kind == "NetworkPolicy": closed.add st.objectName
    check "default-deny" in closed and "allow-dns-and-collector" in closed and "allow-build-egress" notin closed
    var egress: JsonNode
    for st in organizationSteps(buildCfg(registry), "acme", curve, "BT").steps:
      if st.kind == "NetworkPolicy": opened.add st.objectName
      if st.objectName == "allow-build-egress": egress = st.obj
    check "allow-build-egress" in opened
    check egress["spec"]["egress"][0]["ports"][0]["port"].getInt == 5000
    check egress["spec"]["podSelector"]["matchLabels"]["cinim.io/profile"].getStr == "build"      # build Pods only, not the other steps
  test "a step may publish to several sinks at once (a registry and a Nexus): every rule of build.egress is in the one policy":
    let sinks = %*[{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "registry"}}}], "ports": [{"protocol": "TCP", "port": 5000}]},
                   {"to": [{"ipBlock": {"cidr": "192.168.10.20/32"}}], "ports": [{"protocol": "TCP", "port": 8081}, {"protocol": "TCP", "port": 8443}]}]
    var egress: JsonNode
    for st in organizationSteps(buildCfg(sinks), "acme", curve, "BT").steps:
      if st.objectName == "allow-build-egress": egress = st.obj
    check egress["spec"]["egress"].len == 2
    check egress["spec"]["egress"][1]["to"][0]["ipBlock"]["cidr"].getStr == "192.168.10.20/32" and egress["spec"]["egress"][1]["ports"].len == 2
    check egress["spec"]["podSelector"]["matchLabels"]["cinim.io/profile"].getStr == "build"
  test "build.egress `all`: build Pods may reach any address, private ones too, and the other steps stay closed":
    var c = buildCfg(%"all")
    c.buildInternet = %*{"ports": [80, 443], "except": ["10.0.0.0/8"]}
    var egress: JsonNode
    var names: seq[string]
    for st in organizationSteps(c, "acme", curve, "BT").steps:
      if st.kind == "NetworkPolicy": names.add st.objectName
      if st.objectName == "allow-build-egress": egress = st.obj
    check egress["spec"]["egress"] == %*[{}]
    check egress["spec"]["podSelector"]["matchLabels"]["cinim.io/profile"].getStr == "build"
    check "allow-build-internet" notin names and "allow-all-egress" notin names and "default-deny" in names
  test "build.ingress `all`: only build Pods may be reached from any address; nothing with ingress open for all steps":
    var c = buildCfg()
    c.buildIngress = %"all"
    var p: JsonNode
    for st in organizationSteps(c, "acme", curve, "BT").steps:
      if st.objectName == "allow-build-ingress": p = st.obj
    check p["spec"]["ingress"] == %*[{}] and p["spec"]["podSelector"]["matchLabels"]["cinim.io/profile"].getStr == "build"
    for st in organizationSteps(buildCfg(), "acme", curve, "BT").steps: check st.objectName != "allow-build-ingress"
    c.ingressOpen = true
    for st in organizationSteps(c, "acme", curve, "BT").steps: check st.objectName != "allow-build-ingress"      # the all-steps policy says it
  test "build.ingress as a list: several peers and ports in one policy":
    var c = buildCfg()
    c.buildIngress = %*[{"from": [{"ipBlock": {"cidr": "192.168.10.0/24"}}], "ports": [{"protocol": "TCP", "port": 8080}]},
                        {"from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "registry"}}}]}]
    var p: JsonNode
    for st in organizationSteps(c, "acme", curve, "BT").steps:
      if st.objectName == "allow-build-ingress": p = st.obj
    check p["spec"]["ingress"].len == 2 and p["spec"]["podSelector"]["matchLabels"]["cinim.io/profile"].getStr == "build"
    c.buildIngress = %*[]
    for st in organizationSteps(c, "acme", curve, "BT").steps: check st.objectName != "allow-build-ingress"      # an empty list is closed
  test "the simple mode: egress open and ingress open are one policy each for every step Pod, the controller stays closed":
    var c = cfg(true)
    c.egressOpen = true
    c.ingressOpen = true
    var all: seq[JsonNode]
    var names: seq[string]
    for st in organizationSteps(c, "acme", curve, "BT").steps:
      if st.kind == "NetworkPolicy": names.add st.objectName
      if st.objectName in ["allow-all-egress", "allow-all-ingress"]: all.add st.obj
    check all.len == 2 and "default-deny" in names and "controller-no-ingress" in names
    check all[0]["spec"]["egress"] == %*[{}] and all[0]["spec"]["policyTypes"] == %*["Egress"]
    check all[1]["spec"]["ingress"] == %*[{}] and all[1]["spec"]["policyTypes"] == %*["Ingress"]
    for p in all: check p["spec"]["podSelector"]["matchExpressions"][0]["operator"].getStr == "NotIn"      # not the controller
    # asked for separately; a closed organisation has neither
    for st in organizationSteps(cfg(true), "acme", curve, "BT").steps: check st.objectName notin ["allow-all-egress", "allow-all-ingress"]
  test "with egress open the rules of the build profile are left out, as they would say nothing more":
    var c = buildCfg(%*[{"to": [{"ipBlock": {"cidr": "192.168.10.20/32"}}]}])
    c.buildInternet = %*{"ports": [80], "except": []}
    c.egressOpen = true
    for st in organizationSteps(c, "acme", curve, "BT").steps: check st.objectName notin ["allow-build-egress", "allow-build-internet"]
  test "a build Pod may download packages from the public internet and reach no private range (npm, deb, maven, git)":
    var cfgI = buildCfg(registry)
    cfgI.buildInternet = %*{"ports": [80, 443, 22], "except": ["10.0.0.0/8", "192.168.0.0/16", "169.254.0.0/16"]}
    var policy: JsonNode
    for st in organizationSteps(cfgI, "acme", curve, "BT").steps:
      if st.objectName == "allow-build-internet": policy = st.obj
    check policy != nil
    let rule = policy["spec"]["egress"][0]
    check rule["to"][0]["ipBlock"]["cidr"].getStr == "0.0.0.0/0"
    check "169.254.0.0/16" in $rule["to"][0]["ipBlock"]["except"] and "10.0.0.0/8" in $rule["to"][0]["ipBlock"]["except"]
    var ports: seq[int]
    for p in rule["ports"]: ports.add p["port"].getInt
    check ports == @[80, 443, 22]
    check policy["spec"]["podSelector"]["matchLabels"]["cinim.io/profile"].getStr == "build"
    for st in organizationSteps(buildCfg(registry), "acme", curve, "BT").steps: check st.objectName != "allow-build-internet"
  test "the limit range gives a step Pod an ephemeral-storage request of 64Mi and a limit of 1Gi, or the operator's":
    for cfgLimit in ["", "3Gi"]:
      var c = buildCfg()
      c.stepEphemeralLimit = cfgLimit
      for st in organizationSteps(c, "acme", curve, "BT").steps:
        if st.kind == "LimitRange":
          let l = st.obj["spec"]["limits"][0]
          check l["defaultRequest"]["ephemeral-storage"].getStr == "64Mi"
          check l["default"]["ephemeral-storage"].getStr == (if cfgLimit.len > 0: cfgLimit else: "1Gi")
  test "the limit range stays that of an ordinary step: a build Pod sets its own memory":
    for st in organizationSteps(buildCfg(), "acme", curve, "BT").steps:
      if st.kind == "LimitRange": check st.obj["spec"]["limits"][0]["default"]["memory"].getStr == "1Gi"
  test "everything is created once, and a repeat is harmless":
    let f = Fake()
    let r = provision(api(f), buildCfg(registry), "acme", curve, "BT")
    check r.ok
    check f.calls.count("POST /api/v1/namespaces") == 1
    let again = Fake(exists: @["/api/v1/namespaces", "/apis/apps/v1/namespaces/cinim-001-acme/deployments"])
    check provision(api(again), buildCfg(registry), "acme", curve, "BT").ok
  test "switching off and deleting for good touch the one namespace":
    let f = Fake()
    check disable(api(f), buildCfg(), "acme").ok
    check f.calls.filterIt("DELETE" in it and "-build" in it).len == 0
    let g = Fake()
    check purge(api(g), buildCfg(), "acme").ok
    check "DELETE /api/v1/namespaces/cinim-001-acme" in g.calls and g.calls.filterIt("-build" in it).len == 0

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

suite "RUN-009 the namespace of an organisation with conductors (docs/conductors.md section 7)":
  test "without conductors nothing changes: no policy for them":
    var names: seq[string]
    for st in organizationSteps(cfg(), "acme", curve, "BT").steps: names.add st.objectName
    check "allow-conductor" notin names
  test "a conductor Pod is denied everything but DNS and the core's push channel, and a step's policies do not select it":
    var c = cfg()
    c.conductors = true
    var conductorPolicy: JsonNode
    var deny: JsonNode
    for st in organizationSteps(c, "acme", curve, "BT").steps:
      if st.objectName == "allow-conductor": conductorPolicy = st.obj
      if st.objectName == "default-deny": deny = st.obj
      if st.objectName == "allow-dns-and-collector":
        # the step Pods' opening of the collector, the step report and the artifacts is not the conductor's
        check "cinim-conductor" in $st.obj["spec"]["podSelector"]
        check "NotIn" in $st.obj["spec"]["podSelector"]
    check conductorPolicy != nil
    check conductorPolicy["spec"]["podSelector"]["matchLabels"]["app.kubernetes.io/name"].getStr == "cinim-conductor"
    check conductorPolicy["spec"]["policyTypes"].len == 1 and conductorPolicy["spec"]["policyTypes"][0].getStr == "Egress"
    var ports: seq[int]
    for r in conductorPolicy["spec"]["egress"]:
      if r["to"][0]{"podSelector"}{"matchLabels"}{"app.kubernetes.io/name"}.getStr == "cinim-core":
        for p in r["ports"]: ports.add p["port"].getInt
    check ports == @[19745]
    # the default deny keeps covering the conductor (it excludes the controller only): its ingress is closed and its egress is what the policy above opens
    check deny["spec"]["policyTypes"].len == 2
    check "cinim-conductor" notin $deny["spec"]["podSelector"]
