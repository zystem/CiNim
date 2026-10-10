## RUN-009 / docs/conductors.md section 5, phase 3: what the controller of an organisation does about conductors - which Pods to make, which to remove, what a conductor
## Pod is. Against a fake cluster (no Kubernetes).
import std/[unittest, json, tables, strutils, sequtils, options]
import jobcontroller/[backend, conductors]

type Fake = ref object
  pods: Table[string, ConductorPod]
  secrets: Table[string, JsonNode]
  podBodies: Table[string, JsonNode]
  creates, deletes: seq[string]
  listOk: bool
  refuse: bool

proc newFake(): Fake = Fake(listOk: true)

proc backendOf(f: Fake): Backend =
  result.createConductor = proc (name, secretJson, podJson: string): CreateOutcome =
    if f.refuse: return CreateOutcome(kind: ckQuota, reason: "Forbidden", message: "exceeded quota")
    f.creates.add name
    f.secrets[name] = parseJson(secretJson)
    f.podBodies[name] = parseJson(podJson)
    f.pods[name] = ConductorPod(name: name, phase: "Pending", image: parseJson(podJson)["spec"]["containers"][0]["image"].getStr)
    CreateOutcome(kind: ckOk)
  result.listConductors = proc (): tuple[ok: bool, pods: seq[ConductorPod]] =
    result.ok = f.listOk
    for _, p in f.pods: result.pods.add p
  result.deleteConductor = proc (name: string): bool =
    f.deletes.add name
    f.pods.del name
    f.secrets.del name
    true

let spec = ConductorSpec(image: "reg/cinim-conductor:t", runsPerConductor: 10, drainSeconds: 30, streamAddr: "tcp://core.ns.svc:19745",
                         namespace: "cinim-001-acme", curveSecret: "cinim-controller-curve")

proc plan(n: int): seq[(string, string)] =
  for i in 1 .. n: result.add ("cond-" & $i, "cred-" & $i)

suite "RUN-009 the names of conductor Pods":
  test "cinim-conductor-<n> and back":
    check conductorPodName(3) == "cinim-conductor-3"
    check conductorPodNumber("cinim-conductor-3") == some(3)
    check conductorPodNumber("cinim-conductor-0").isNone
    check conductorPodNumber("ci-s1-abc-0-1").isNone
    check conductorPodNumber("cinim-conductor-").isNone

suite "RUN-009 which conductors the controller makes and removes":
  test "the first N are made when none exist":
    var tried: Table[int, float]
    let a = planActions(2, @[], 100.0, tried)
    check a.mapIt((it.kind, it.n)) == @[(akCreate, 1), (akCreate, 2)]
  test "a conductor that exists (adopted after a restart of the controller) is left alone":
    var tried: Table[int, float]
    let ex = @[ConductorPod(name: "cinim-conductor-1", phase: "Running"), ConductorPod(name: "cinim-conductor-2", phase: "Pending")]
    check planActions(2, ex, 100.0, tried).len == 0
  test "a conductor that has ended is removed, and made again on a later round, not in the same one":
    var tried: Table[int, float]
    let ex = @[ConductorPod(name: "cinim-conductor-1", phase: "Succeeded")]
    check planActions(1, ex, 100.0, tried).mapIt((it.kind, it.name)) == @[(akDelete, "cinim-conductor-1")]
    check planActions(1, @[], 101.0, tried).mapIt((it.kind, it.n)) == @[(akCreate, 1)]
  test "a conductor that failed is removed too":
    var tried: Table[int, float]
    check planActions(1, @[ConductorPod(name: "cinim-conductor-1", phase: "Failed")], 100.0, tried).mapIt(it.kind) == @[akDelete]
  test "a running conductor above the number wanted is NOT removed: the core drains it; one that has ended is":
    var tried: Table[int, float]
    let ex = @[ConductorPod(name: "cinim-conductor-1", phase: "Running"), ConductorPod(name: "cinim-conductor-2", phase: "Running"),
               ConductorPod(name: "cinim-conductor-3", phase: "Succeeded")]
    check planActions(1, ex, 100.0, tried).mapIt((it.kind, it.name)) == @[(akDelete, "cinim-conductor-3")]
  test "zero wanted makes nothing and removes nothing that runs":
    var tried: Table[int, float]
    check planActions(0, @[ConductorPod(name: "cinim-conductor-1", phase: "Running")], 100.0, tried).len == 0
  test "a Pod that is not named like a conductor is not touched":
    var tried: Table[int, float]
    check planActions(1, @[ConductorPod(name: "something", phase: "Failed"), ConductorPod(name: "cinim-conductor-1", phase: "Running")], 100.0, tried).len == 0
  test "a conductor that could not be made is tried again only after a pause":
    var tried: Table[int, float]
    check planActions(1, @[], 100.0, tried).len == 1
    check planActions(1, @[], 103.0, tried).len == 0
    check planActions(1, @[], 111.0, tried).len == 1

suite "RUN-009 reconciling against the cluster":
  test "the conductors are made with their credentials, and a second round changes nothing":
    let f = newFake()
    var tried: Table[int, float]
    let r = reconcile(backendOf(f), spec, 2, plan(2), 100.0, tried)
    check r.created == @["cinim-conductor-1", "cinim-conductor-2"]
    check f.secrets["cinim-conductor-1"]["stringData"]["credential"].getStr == "cred-1"
    check f.secrets["cinim-conductor-2"]["stringData"]["credential"].getStr == "cred-2"
    let r2 = reconcile(backendOf(f), spec, 2, plan(2), 200.0, tried)
    check r2.created.len == 0 and r2.deleted.len == 0
  test "a conductor with no credential in the plan is not made":
    let f = newFake()
    var tried: Table[int, float]
    check reconcile(backendOf(f), spec, 2, plan(1), 100.0, tried).created == @["cinim-conductor-1"]
  test "a cluster that cannot be read is concluded nothing from":
    let f = newFake()
    f.listOk = false
    var tried: Table[int, float]
    check reconcile(backendOf(f), spec, 2, plan(2), 100.0, tried).created.len == 0
  test "a refused Pod (a used-up quota) is not tracked as made, and is tried again later":
    let f = newFake()
    f.refuse = true
    var tried: Table[int, float]
    check reconcile(backendOf(f), spec, 1, plan(1), 100.0, tried).created.len == 0
    f.refuse = false
    check reconcile(backendOf(f), spec, 1, plan(1), 120.0, tried).created == @["cinim-conductor-1"]
  test "an ended conductor is removed with its Secret":
    let f = newFake()
    var tried: Table[int, float]
    discard reconcile(backendOf(f), spec, 1, plan(1), 100.0, tried)
    f.pods["cinim-conductor-1"].phase = "Succeeded"
    let r = reconcile(backendOf(f), spec, 1, plan(1), 200.0, tried)
    check r.deleted == @["cinim-conductor-1"] and "cinim-conductor-1" notin f.secrets
  test "a controller that makes no conductors (no backend support) does nothing":
    var tried: Table[int, float]
    check reconcile(Backend(), spec, 2, plan(2), 100.0, tried).created.len == 0

suite "RUN-009 what a conductor Pod is":
  let pod = conductorPodBody(spec, 2)
  let c = pod["spec"]["containers"][0]
  test "named, labelled so that the network policy and the controller find it":
    check pod["metadata"]["name"].getStr == "cinim-conductor-2"
    check pod["metadata"]["labels"]["app.kubernetes.io/name"].getStr == "cinim-conductor"
    check pod["metadata"]["labels"]["cinim.io/conductor"].getStr == "cond-2"
  test "the restricted class: non-root, no privilege escalation, no capabilities, the default seccomp profile, a read-only file system, no service account token":
    check pod["spec"]["securityContext"]["runAsNonRoot"].getBool
    check pod["spec"]["securityContext"]["seccompProfile"]["type"].getStr == "RuntimeDefault"
    check c["securityContext"]["allowPrivilegeEscalation"].getBool == false
    check c["securityContext"]["readOnlyRootFilesystem"].getBool
    check c["securityContext"]["capabilities"]["drop"][0].getStr == "ALL"
    check pod["spec"]["automountServiceAccountToken"].getBool == false
    check pod["spec"]["restartPolicy"].getStr == "Never"
  test "its environment: the core's push channel, the namespace, its id, its credential from its own Secret and never as a value":
    var env = initTable[string, JsonNode]()
    for e in c["env"]: env[e["name"].getStr] = e
    check env["CINIM_CORE_STREAM_ADDR"]["value"].getStr == "tcp://core.ns.svc:19745"
    check env["CINIM_NAMESPACE"]["value"].getStr == "cinim-001-acme"
    check env["CINIM_CONDUCTOR_ID"]["value"].getStr == "cond-2"
    check env["CINIM_RUNS_PER_CONDUCTOR"]["value"].getStr == "10" and env["CINIM_DRAIN_SECONDS"]["value"].getStr == "30"
    check not env["CINIM_CONDUCTOR_CREDENTIAL"].hasKey("value")
    check env["CINIM_CONDUCTOR_CREDENTIAL"]["valueFrom"]["secretKeyRef"]["name"].getStr == "cinim-conductor-2"
    check env["CINIM_CONDUCTOR_CREDENTIAL"]["valueFrom"]["secretKeyRef"]["key"].getStr == "credential"
  test "the keys of the transport are the organisation's, mounted read-only, and nothing else is mounted":
    check pod["spec"]["volumes"].len == 1 and pod["spec"]["volumes"][0]["secret"]["secretName"].getStr == "cinim-controller-curve"
    check c["volumeMounts"].len == 1 and c["volumeMounts"][0]["readOnly"].getBool
  test "memory grows with the runs it leads; the grace period covers the drain":
    check c["resources"]["limits"]["memory"].getStr == "896Mi"
    check pod["spec"]["terminationGracePeriodSeconds"].getInt >= 30 + 5
  test "the Secret carries the credential and the same labels":
    let s = conductorSecretBody(spec, 2, "the-credential")
    check s["metadata"]["name"].getStr == "cinim-conductor-2" and s["stringData"]["credential"].getStr == "the-credential"
