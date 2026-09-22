## Spike 4: Kubernetes access from Nim through the official C client (generic JSON API) against a real cluster.
## Build: nim c -r -d:k8sPrefix=<prefix> tests/integration/tk8s.nim   (uses the current kubeconfig context, namespace cinim-m0)
import std/[unittest, json, os, strutils, times, algorithm, tables, locks, sequtils]
import common/k8sbind

const ns = "cinim-m0"

# ---------- thin JSON helpers over the generic client ----------
type K8s = object
  api: ptr apiClient_t

proc connect(): K8s =
  var base: cstring
  var ssl: ptr sslConfig_t
  var keys: ptr list_t
  doAssert load_kube_config(cast[cstringArray](addr base), addr ssl, addr keys, nil) == 0, "cannot load kubeconfig"
  result.api = apiClient_create_with_base_path(base, ssl, keys)
  doAssert result.api != nil

proc gclient(k: K8s; group, version, plural: string): ptr genericClient_t =
  genericClient_create(k.api, group.cstring, version.cstring, plural.cstring)

proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc j(raw: cstring): JsonNode =
  if raw == nil: return newJNull()
  let text = $raw
  c_free(raw)
  try: result = parseJson(text)
  except JsonParsingError:
    echo "  NOT JSON (", text.len, " bytes): ", text[0 ..< min(200, text.len)]
    raise

proc podBody(name: string; run = "r1"; cmd = "exit 0"; init = false; extra: JsonNode = nil): string =
  var spec = %*{
    "restartPolicy": "Never", "automountServiceAccountToken": false,
    "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": "step", "image": "busybox:1.36", "command": ["sh", "-c", cmd],
      "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}},
      "resources": {"requests": {"cpu": "10m", "memory": "8Mi"}, "limits": {"memory": "64Mi"}}}]}
  if init:
    spec["initContainers"] = %*[{"name": "shim", "image": "busybox:1.36", "command": ["sh", "-c", "true"],
      "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}}]
  if extra != nil:
    for k, v in extra: spec[k] = v
  $(%*{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "labels": {"cicd.io/run": run}}, "spec": spec})

# ---------- watch stream (own client, own thread) ----------
# Only plain data crosses the thread boundary: ORC heaps are per thread and reference counts are not atomic.
type
  Ev = object
    name, node: array[64, char]
    stage: int          # 0: spec.nodeName set, 1: a container running or terminated, 2: phase Running/Succeeded/Failed
    t: float
  Timeline = object
    scheduled, started, phase: float
    node: string

var
  evLock: Lock
  evs: array[8192, Ev]
  evCount: int
  evRead: int
  seen: Table[string, Timeline]       # main thread only
initLock(evLock)

proc put(dst: var array[64, char]; src: string) =
  for i in 0 ..< min(63, src.len): dst[i] = src[i]

proc push(name, node: string; stage: int; t: float) =
  {.cast(gcsafe).}:
    withLock evLock:
      if evCount < evs.len:
        evs[evCount].name.put name
        evs[evCount].node.put node
        evs[evCount].stage = stage
        evs[evCount].t = t
        inc evCount

proc onEvent(ev: cstring) {.cdecl.} =
  let t = epochTime()
  try:
    let e = parseJson($ev)
    if not e.hasKey("object"): return
    let o = e["object"]
    let name = o{"metadata", "name"}.getStr
    let node = o{"spec", "nodeName"}.getStr
    var started = false
    let css = o{"status", "containerStatuses"}      # nil until the kubelet reports
    if css != nil and css.kind == JArray:
      for cs in css:
        let st = cs{"state"}
        if st != nil and (st.hasKey("running") or st.hasKey("terminated")): started = true
    if node.len > 0: push(name, node, 0, t)
    if started: push(name, node, 1, t)
    if o{"status", "phase"}.getStr in ["Running", "Succeeded", "Failed"]: push(name, node, 2, t)
  except CatchableError: discard

proc pollEvents() =
  ## main thread: fold new watch events into `seen` (first observation of each stage wins)
  {.cast(gcsafe).}:
    withLock evLock:
      while evRead < evCount:
        let e = evs[evRead]
        inc evRead
        let name = $cast[cstring](unsafeAddr e.name[0])
        var tl = seen.getOrDefault(name)
        case e.stage
        of 0: (if tl.scheduled == 0: tl.scheduled = e.t; tl.node = $cast[cstring](unsafeAddr e.node[0]))
        of 1: (if tl.started == 0: tl.started = e.t)
        else: (if tl.phase == 0: tl.phase = e.t)
        seen[name] = tl

proc onData(pData: ptr pointer; pLen: ptr clong) {.cdecl.} =
  kubernets_watch_handler(pData, pLen, onEvent)

proc watchThread(unused: int) {.thread.} =
  {.cast(gcsafe).}:
    let k = connect()
    k.api.data_callback_func = onData
    let g = gclient(k, "", "v1", "pods")
    let q = list_createList()
    list_addElement(q, keyValuePair_create("watch", cast[pointer]("true".cstring)))
    list_addElement(q, keyValuePair_create("timeoutSeconds", cast[pointer]("1500".cstring)))
    discard Generic_listNamespaced(g, ns.cstring, q)

proc pct(xs: seq[float]; p: float): float =
  let s = xs.sorted
  s[min(s.high, int(float(s.len) * p))]

type Series = object
  total, sched, kubelet, phaseLag, toStart: seq[float]   # ms
  nodes: seq[string]

proc runPods(k: K8s; g: ptr genericClient_t; prefix: string; n: int; parallel: bool; init: bool;
             nodes: seq[string] = @[]): Series =
  ## creates n pods, returns per-stage latencies in ms (create -> scheduled -> container started -> phase seen)
  var t0: Table[string, float]
  proc finished(name: string): bool =
    pollEvents()
    result = name in seen and seen[name].phase > 0
  for i in 0 ..< n:
    let name = prefix & $i
    var extra: JsonNode = nil
    if nodes.len > 0: extra = %*{"nodeName": nodes[i mod nodes.len]}
    t0[name] = epochTime()
    let r = j(Generic_createNamespacedResource(g, ns.cstring, podBody(name, init = init, extra = extra).cstring, nil))
    doAssert r{"kind"}.getStr == "Pod", $r
    if not parallel:
      var waited = 0
      while not finished(name):
        sleep 5
        waited += 5
        if waited >= 60000:
          echo "  STUCK ", name, ": ", pretty(j(Generic_readNamespacedResource(g, ns.cstring, name.cstring)){"status"})
          doAssert false, "pod " & name & " never started"
  for name, start in t0:
    var waited = 0
    while not finished(name):
      sleep 5
      waited += 5
      doAssert waited < 120000, "pod " & name & " never started"
    let tl = seen[name]
    let sched = if tl.scheduled > 0: tl.scheduled else: start
    result.total.add (tl.phase - start) * 1000
    result.toStart.add ((if tl.started > 0: tl.started else: tl.phase) - start) * 1000
    result.sched.add (sched - start) * 1000
    result.kubelet.add (tl.started - sched) * 1000
    result.phaseLag.add (tl.phase - tl.started) * 1000
    result.nodes.add tl.node

proc report(label: string; s: Series) =
  proc f(xs: seq[float]): string = "p50=" & $int(pct(xs, 0.5)) & " p95=" & $int(pct(xs, 0.95)) & " max=" & $int(xs.max)
  echo "  METRIC ", label
  echo "    create->started    : ", f(s.toStart), "   <- RUN-013 (API-observed container start)"
  echo "    create->phase seen : ", f(s.total)
  echo "    create->scheduled  : ", f(s.sched)
  echo "    scheduled->started : ", f(s.kubelet)
  echo "    started->phase seen: ", f(s.phaseLag)

suite "spike 4: Kubernetes from Nim via the official C client":
  var k: K8s
  var pods: ptr genericClient_t
  var wt: Thread[int]
  apiClient_setupGlobalEnv()
  k = connect()
  pods = gclient(k, "", "v1", "pods")

  test "kubeconfig loads and the API answers":
    let nsList = j(Generic_list(gclient(k, "", "v1", "namespaces"), nil))
    check nsList["items"].len > 0
    check nsList["items"].mapIt(it["metadata"]["name"].getStr).anyIt(it == "kube-system")

  test "test namespace exists":
    let g = gclient(k, "", "v1", "namespaces")
    let r = j(Generic_createResource(g, $(%*{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}}), nil))
    check r{"kind"}.getStr == "Namespace" or r{"reason"}.getStr == "AlreadyExists"

  test "RUN-002 creating the same deterministic Pod name twice returns AlreadyExists (409)":
    let name = "ci-run1-1-1"
    let first = j(Generic_createNamespacedResource(pods, ns.cstring, podBody(name).cstring, nil))
    checkpoint first{"message"}.getStr
    check first{"kind"}.getStr == "Pod"
    let second = j(Generic_createNamespacedResource(pods, ns.cstring, podBody(name).cstring, nil))
    check second{"reason"}.getStr == "AlreadyExists"
    check second{"code"}.getInt == 409
    discard Generic_deleteNamespacedResource(pods, ns.cstring, name.cstring, nil)

  test "RUN-013 Pod start latency by stage: sequential, burst, init container, pre-bound node":
    createThread(wt, watchThread, 0)
    sleep 1500                                   # let the watch connect
    let warm = runPods(k, pods, "warm", 12, true, true)   # pull the image on every node
    var nodes: seq[string]
    for n in warm.nodes:
      if n.len > 0 and n notin nodes: nodes.add n
    echo "  worker nodes seen: ", nodes
    for (label, prefix, n, par, init, pinned) in [("sequential", "seq", 30, false, false, false), ("burst50", "brst", 50, true, false, false),
        ("sequential + init container (shim delivery)", "sqi", 30, false, true, false),
        ("sequential, nodeName pre-set (no scheduler)", "pin", 30, false, false, true)]:
      let s = runPods(k, pods, prefix, n, par, init, (if pinned: nodes else: @[]))
      report(label, s)
      check s.total.len == n

  test "cleanup":
    discard Generic_deleteResource(gclient(k, "", "v1", "namespaces"), ns.cstring, nil)
