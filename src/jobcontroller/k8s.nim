## The real Backend: the official Kubernetes C client (A.6, D-26). The only module of the controller that knows
## Kubernetes; it turns the platform's PodRequest into a Pod spec and answers the questions logic.nim asks of the cluster.
## SEC-010 per-job projected tokens are deferred: the shim gets the shared CURVE "client" identity through a Secret.
import std/[os, json, strutils, times, base64, atomics, sequtils, options]
import ../common/[k8sbind, envname, quantity]
import backend, podsec, runvolume, shardsettings

type K8s* = object
  api: ptr apiClient_t
  pods, configmaps, secrets, claims, quotas: ptr genericClient_t
  tailQuery: ptr list_t       ## ?tailLines=40, built once and reused: the client does not consume it
  ns: string

const
  shimConfigMap = "cicd-shim"
  curveSecret = "cicd-curve-certs"

proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc jstr(raw: cstring): JsonNode =
  if raw == nil: return newJNull()
  let text = $raw
  cFree(raw)
  try: parseJson(text)
  except JsonParsingError: newJNull()

proc connectK8s*(ns, kubeconfig: string): K8s =
  ## load_kube_config() always dials whatever "current-context" says in the file, with no per-call override - it silently
  ## follows the shared ~/.kube/config if kubeconfig is empty, which drifts under unrelated work. CINIM_KUBECONFIG pins a file;
  ## inside a cluster with no file given, the ServiceAccount of the Pod is used.
  var base: cstring
  var ssl: ptr sslConfig_t
  var keys: ptr list_t
  let cfgPath = if kubeconfig.len > 0: kubeconfig.cstring else: nil.cstring
  if kubeconfig.len == 0 and getEnv("KUBERNETES_SERVICE_HOST").len > 0:
    # in a cluster (the controller of an organisation, SHD-007): the Pod's own ServiceAccount, no kubeconfig
    doAssert load_incluster_config(cast[cstringArray](addr base), addr ssl, addr keys) == 0
  else:
    doAssert load_kube_config(cast[cstringArray](addr base), addr ssl, addr keys, cfgPath) == 0
  result.ns = ns
  result.api = apiClient_create_with_base_path(base, ssl, keys)
  doAssert result.api != nil
  enableConnectionCache(result.api)
  result.pods = genericClient_create(result.api, "".cstring, "v1".cstring, "pods".cstring)
  result.configmaps = genericClient_create(result.api, "".cstring, "v1".cstring, "configmaps".cstring)
  result.secrets = genericClient_create(result.api, "".cstring, "v1".cstring, "secrets".cstring)
  result.claims = genericClient_create(result.api, "".cstring, "v1".cstring, "persistentvolumeclaims".cstring)
  result.quotas = genericClient_create(result.api, "".cstring, "v1".cstring, "resourcequotas".cstring)
  result.tailQuery = list_createList()
  list_addElement(result.tailQuery, keyValuePair_create("tailLines".cstring, cast[pointer]("40".cstring)))

proc createOrIgnore(k: K8s; client: ptr genericClient_t; kind, name, body: string) =
  let raw = Generic_createNamespacedResource(client, k.ns.cstring, body.cstring, nil)
  if raw == nil:
    stderr.writeLine "jobcontroller: create " & kind & " " & name & ": no response from the Kubernetes API client"
    return
  let r = jstr(raw)
  if r.kind == JObject and r{"status"}.getStr == "Failure" and r{"reason"}.getStr != "AlreadyExists":
    stderr.writeLine "jobcontroller: create " & kind & " " & name & " failed: " & $r
  else:
    echo "jobcontroller: ensured ", kind, " ", name

proc createOrReplace(k: K8s; client: ptr genericClient_t; kind, name, body: string) =
  ## The shim travels in a ConfigMap that the controller makes at every start. Leaving an existing one as it is (createOrIgnore) meant that a new
  ## controller image, and the shim in it, never reached a step Pod: it kept running the shim of the first controller of the namespace.
  let raw = Generic_createNamespacedResource(client, k.ns.cstring, body.cstring, nil)
  if raw == nil:
    stderr.writeLine "jobcontroller: create " & kind & " " & name & ": no response from the Kubernetes API client"
    return
  let r = jstr(raw)
  if r.kind == JObject and r{"status"}.getStr == "Failure":
    if r{"reason"}.getStr != "AlreadyExists":
      stderr.writeLine "jobcontroller: create " & kind & " " & name & " failed: " & $r
      return
    let rep = jstr(Generic_replaceNamespacedResource(client, k.ns.cstring, name.cstring, body.cstring))
    if rep.kind == JObject and rep{"status"}.getStr == "Failure":
      stderr.writeLine "jobcontroller: replace " & kind & " " & name & " failed: " & $rep
    else:
      echo "jobcontroller: replaced ", kind, " ", name, " (it was there; the content of this controller's image is what runs)"
  else:
    echo "jobcontroller: ensured ", kind, " ", name

proc ensureShimAssets*(k: K8s; shimBinPath, certs: string; withCerts: bool) =
  ## Safe at every startup. The ConfigMap is unconditional: every step Pod runs through the shim, and it is replaced when it exists, so that
  ## the shim is that of the controller's own image. The Secret (the shim's CURVE identity) only when logs are streamed; an existing one is left.
  createOrReplace(k, k.configmaps, "configmap", shimConfigMap, $(%*{
    "apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": shimConfigMap},
    "binaryData": {"cicd-shim": encode(readFile(shimBinPath))}}))
  if withCerts:
    createOrIgnore(k, k.secrets, "secret", curveSecret, $(%*{
      "apiVersion": "v1", "kind": "Secret", "metadata": {"name": curveSecret},
      "stringData": {"client.pub": readFile(certs / "curve" / "client.pub"),
                     "client.key": readFile(certs / "curve" / "client.key"),
                     "core.pub": readFile(certs / "curve" / "core.pub")}}))

var shard {.threadvar.}: ShardSettings
  ## the settings of the shard (the build profile of D-42, what a build Pod is is in podsec.nim; the volume of a run, runvolume.nim): given by the core in every answer to a
  ## poll (applyShardSettings), used by the Pod and the claim that the next step gets. The Pods are made by the thread that polls, which is the thread that applies them.

proc applyShardSettings*(s: ShardSettings) = shard = s

proc podBody(r: PodRequest): JsonNode =
  let sec = podsec.podSecurity(shard.build, r.build, r.deploy)
  let shimMount = %*{"name": "shim", "mountPath": "/cicd/shim", "readOnly": true}
  let vol = runvolume.podVolume(shard.volume, r.runId, r.image, shimMount, sec.containerCtx, sec.resources, r.volume, r.shm)
  result = %*{
    "apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": r.name, "labels": {runvolume.runLabel: r.runId, runvolume.volumeLabel: runvolume.volumeId(r.runId, r.volume)}},
    "spec": {
      "restartPolicy": "Never", "automountServiceAccountToken": false,
      # the kubelet's SIGTERM -> SIGKILL window must cover the shim's own: build grace (20 s) + a short log flush
      "terminationGracePeriodSeconds": 60,
      "securityContext": sec.podCtx,
      "containers": [{"name": "step", "image": r.image, "command": r.cmd,
        "volumeMounts": (@[shimMount] & vol.mounts &
          (if r.logging: @[%*{"name": "certs", "mountPath": "/cicd/certs", "readOnly": true}] else: @[])),
        "securityContext": sec.containerCtx,
        "resources": sec.resources}],
      "volumes": (@[%*{"name": "shim", "configMap": {"name": shimConfigMap, "defaultMode": 493}}] & vol.volumes &   # the run's volume (the spool of the log and the manifest of the artifacts are on it), and an emptyDir for the shim's own files
        (if r.logging: @[%*{"name": "certs", "secret": {"secretName": curveSecret, "items": [   # shim reads <certs-dir>/curve/<name>.{pub,key}
          {"key": "client.pub", "path": "curve/client.pub"}, {"key": "client.key", "path": "curve/client.key"},
          {"key": "core.pub", "path": "curve/core.pub"}]}}] else: @[]))}}
  if vol.initContainers.len > 0: result["spec"]["initContainers"] = %vol.initContainers
  if vol.affinity != nil: result["spec"]["affinity"] = vol.affinity
  let podEnv = r.podEnv
  if podEnv.len > 0:
    var env = newJArray()
    for (n, v) in podEnv: env.add %*{"name": n, "value": v}
    result["spec"]["containers"][0]["env"] = env
  for k, v in sec.labels: result["metadata"]["labels"][k] = v
  if not sec.hostUsers: result["spec"]["hostUsers"] = %false

proc drainBody(name, runId, volume, image: string; cmd: seq[string]): JsonNode =
  ## The Pod of a drain (docs/artifacts.md): the run's volume as a step Pod sees it (`/cicd/workspace`, `/cicd/state`), the shim, and the keys of the shim to reach the core, running
  ## `cicd-shim --drain`. Same security class as an ordinary step, so that it reads what a step of that user wrote. On the node of the run's other Pods when there are any (a
  ## ReadWriteOnce volume is attached to one node), anywhere else when there are none. It is a Pod of the steps' policy: DNS and the core's ports, nothing else.
  let sec = podsec.podSecurity(shard.build, false, false)
  let shimMount = %*{"name": "shim", "mountPath": "/cicd/shim", "readOnly": true}
  result = %*{
    "apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": name, "labels": {runvolume.runLabel: runId, runvolume.volumeLabel: runvolume.volumeId(runId, volume), "cicd.io/drain": "true"}},
    "spec": {
      "restartPolicy": "Never", "automountServiceAccountToken": false, "terminationGracePeriodSeconds": 30,
      "securityContext": sec.podCtx,
      "containers": [{"name": "drain", "image": image, "command": cmd,
        "volumeMounts": [shimMount,
          {"name": "certs", "mountPath": "/cicd/certs", "readOnly": true},
          {"name": "data", "mountPath": "/cicd/workspace", "subPath": runvolume.workspaceDir},
          {"name": "data", "mountPath": "/cicd/state", "subPath": runvolume.stateDir}],
        "securityContext": sec.containerCtx, "resources": sec.resources}],
      "volumes": [%*{"name": "shim", "configMap": {"name": shimConfigMap, "defaultMode": 493}},
                  %*{"name": "certs", "secret": {"secretName": curveSecret, "items": [
                    {"key": "client.pub", "path": "curve/client.pub"}, {"key": "client.key", "path": "curve/client.key"}, {"key": "core.pub", "path": "curve/core.pub"}]}},
                  %*{"name": "data", "persistentVolumeClaim": {"claimName": runvolume.claimName(runId, volume)}}],
      "affinity": {"podAffinity": {"preferredDuringSchedulingIgnoredDuringExecution": [
        {"weight": 100, "podAffinityTerm": {"labelSelector": {"matchLabels": {runvolume.volumeLabel: runvolume.volumeId(runId, volume)}}, "topologyKey": "kubernetes.io/hostname"}}]}}}}
  for k, v in sec.labels: result["metadata"]["labels"][k] = v
  if not sec.hostUsers: result["spec"]["hostUsers"] = %false

proc parseTime(s: string): int64 =
  try: parse(s, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()).toTime.toUnix
  except CatchableError: 0

proc backendOf*(k: K8s): Backend =
  let kk = k            # the closures capture a copy of the (pointer-holding) handle
  Backend(
    createPod: proc (r: PodRequest): CreateOutcome =
      let raw = Generic_createNamespacedResource(kk.pods, kk.ns.cstring, ($podBody(r)).cstring, nil)
      if raw == nil:
        # NULL = a transport-level failure (no HTTP response parsed at all), not a Status JSON; otherwise silent
        stderr.writeLine "jobcontroller: create pod " & r.name & ": no response from the Kubernetes API client " &
          "(connection/DNS/TLS failure - check the client's target cluster, e.g. kubeconfig current-context)"
        return CreateOutcome(kind: ckTransport, reason: "NoResponse", message: "no response from the Kubernetes API client")
      let j = jstr(raw)
      # 409 AlreadyExists on a poll-response retry is fine and expected (RUN-002 idempotent create)
      if j.kind == JObject and j{"status"}.getStr == "Failure" and j{"reason"}.getStr != "AlreadyExists":
        stderr.writeLine "jobcontroller: create pod " & r.name & " failed: " & $j
        return classifyCreateFailure(j{"code"}.getInt, j{"reason"}.getStr, j{"message"}.getStr)
      echo "jobcontroller: created pod ", r.name
      CreateOutcome(kind: ckOk),
    createDrainPod: proc (name, runId, volume, image: string; cmd: seq[string]): CreateOutcome =
      let raw = Generic_createNamespacedResource(kk.pods, kk.ns.cstring, ($drainBody(name, runId, volume, image, cmd)).cstring, nil)
      if raw == nil:
        return CreateOutcome(kind: ckTransport, reason: "NoResponse", message: "no response from the Kubernetes API client")
      let j = jstr(raw)
      if j.kind == JObject and j{"status"}.getStr == "Failure" and j{"reason"}.getStr != "AlreadyExists":
        stderr.writeLine "jobcontroller: create drain pod " & name & " failed: " & $j
        return classifyCreateFailure(j{"code"}.getInt, j{"reason"}.getStr, j{"message"}.getStr)
      echo "jobcontroller: created drain pod ", name
      CreateOutcome(kind: ckOk),
    readEvents: proc (name: string): seq[JsonNode] =
      ## the events whose subject is this Pod: the cluster forgets them after about an hour, so they are read when the Pod's story is over
      let g = genericClient_create(kk.api, "".cstring, "v1".cstring, "events".cstring)
      if g == nil: return
      let q = list_createList()
      let selector = "involvedObject.name=" & name       # the client keeps the pointer: it must outlive the call
      list_addElement(q, keyValuePair_create("fieldSelector".cstring, cast[pointer](selector.cstring)))
      let raw = Generic_listNamespaced(g, kk.ns.cstring, q)
      list_freeList(q)
      genericClient_free(g)
      let j = jstr(raw)
      if j.kind == JObject and j{"items"} != nil and j["items"].kind == JArray: result = j["items"].elems,
    readPod: proc (name: string): JsonNode =
      let j = jstr(Generic_readNamespacedResource(kk.pods, kk.ns.cstring, name.cstring))
      if j.kind == JNull: nil else: j,
    readLogTail: proc (name: string): string =
      ## pods/<name>/log?tailLines=40: the shim's own CICD-SHIM lines are all that is in it. Any failure is "" (concludes nothing)
      let g = genericClient_create(kk.api, "".cstring, "v1".cstring, ("pods/" & name & "/log").cstring)
      if g == nil: return
      let raw = Generic_listNamespaced(g, kk.ns.cstring, kk.tailQuery)
      genericClient_free(g)
      if raw == nil: return
      result = $raw
      cFree(raw)
      if result.startsWith("{\"kind\":\"Status\""): result = "",
    deletePod: proc (name: string; graceSeconds: int): bool =
      let raw = Generic_deleteNamespacedResource(kk.pods, kk.ns.cstring, name.cstring,
        ("{\"gracePeriodSeconds\":" & $graceSeconds & "}").cstring)
      let j = jstr(raw)
      if j.kind == JObject and j{"status"}.getStr == "Failure" and j{"reason"}.getStr != "NotFound":
        stderr.writeLine "jobcontroller: delete pod " & name & " failed: " & $j
        return false
      echo "jobcontroller: deleted pod ", name
      true,
    ensureRunVolume: proc (runId, volume: string): CreateOutcome =
      let name = claimName(runId, volume)
      let raw = Generic_createNamespacedResource(kk.claims, kk.ns.cstring, ($claimBody(shard.volume, runId, volume)).cstring, nil)
      if raw == nil:
        stderr.writeLine "jobcontroller: create claim " & name & ": no response from the Kubernetes API client"
        return CreateOutcome(kind: ckTransport, reason: "NoResponse", message: "no response from the Kubernetes API client")
      let j = jstr(raw)
      if j.kind == JObject and j{"status"}.getStr == "Failure" and j{"reason"}.getStr != "AlreadyExists":
        stderr.writeLine "jobcontroller: create claim " & name & " failed: " & $j
        return classifyCreateFailure(j{"code"}.getInt, j{"reason"}.getStr, j{"message"}.getStr)
      if j.kind == JObject and j{"status"}.getStr != "Failure": echo "jobcontroller: created claim ", name
      CreateOutcome(kind: ckOk),
    releaseRunVolume: proc (runId: string): bool =
      ## the run's claim and those of its jobs (STO-002): every claim that carries the run's label, and the run's own by name in case the list could not be read
      var names = @[claimName(runId)]
      let q = list_createList()
      let selector = runLabel & "=" & runId       # the client keeps the pointer: it must outlive the call
      list_addElement(q, keyValuePair_create("labelSelector".cstring, cast[pointer](selector.cstring)))
      let listed = jstr(Generic_listNamespaced(kk.claims, kk.ns.cstring, q))
      list_freeList(q)
      if listed.kind != JObject or listed{"items"} == nil or listed["items"].kind != JArray: return false       # not read: conclude nothing, ask again
      for it in listed["items"]:
        let n = it{"metadata", "name"}.getStr
        if n.len > 0 and n notin names: names.add n
      var allGone = true
      for n in names:
        let j = jstr(Generic_deleteNamespacedResource(kk.claims, kk.ns.cstring, n.cstring, "{}".cstring))
        if j.kind == JObject and j{"status"}.getStr == "Failure" and j{"reason"}.getStr != "NotFound":
          stderr.writeLine "jobcontroller: delete claim " & n & " failed: " & $j
          allGone = false
      if allGone: echo "jobcontroller: released the volumes of run ", runId, " (", names.len, ")"
      allGone,
    createConductor: proc (name, secretJson, podJson: string): CreateOutcome =
      ## the conductor's Secret first (its credential; one that is there already is the same), then its Pod
      let rs = jstr(Generic_createNamespacedResource(kk.secrets, kk.ns.cstring, secretJson.cstring, nil))
      if rs.kind == JObject and rs{"status"}.getStr == "Failure" and rs{"reason"}.getStr != "AlreadyExists":
        stderr.writeLine "jobcontroller: create secret " & name & " failed: " & $rs
        return classifyCreateFailure(rs{"code"}.getInt, rs{"reason"}.getStr, rs{"message"}.getStr)
      let raw = Generic_createNamespacedResource(kk.pods, kk.ns.cstring, podJson.cstring, nil)
      if raw == nil:
        stderr.writeLine "jobcontroller: create pod " & name & ": no response from the Kubernetes API client"
        return CreateOutcome(kind: ckTransport, reason: "NoResponse", message: "no response from the Kubernetes API client")
      let j = jstr(raw)
      if j.kind == JObject and j{"status"}.getStr == "Failure" and j{"reason"}.getStr != "AlreadyExists":
        stderr.writeLine "jobcontroller: create pod " & name & " failed: " & $j
        return classifyCreateFailure(j{"code"}.getInt, j{"reason"}.getStr, j{"message"}.getStr)
      echo "jobcontroller: created conductor ", name
      CreateOutcome(kind: ckOk),
    readStorageQuota: proc (): tuple[used, hard: uint64] =
      ## the namespace's ResourceQuota `cinim-default` (core/orgprovision.nim): requests.storage, used and hard
      let j = jstr(Generic_readNamespacedResource(kk.quotas, kk.ns.cstring, "cinim-default".cstring))
      if j.kind != JObject or j{"status"}.isNil: return
      let hard = parseQuantity(j{"status", "hard", "requests.storage"}.getStr)
      let used = parseQuantity(j{"status", "used", "requests.storage"}.getStr)
      if hard.isSome and used.isSome:
        result = (used.get, hard.get),
    listConductors: proc (): tuple[ok: bool, pods: seq[ConductorPod]] =
      let q = list_createList()
      let selector = "app.kubernetes.io/name=cinim-conductor"       # the client keeps the pointer: it must outlive the call
      list_addElement(q, keyValuePair_create("labelSelector".cstring, cast[pointer](selector.cstring)))
      let j = jstr(Generic_listNamespaced(kk.pods, kk.ns.cstring, q))
      list_freeList(q)
      if j.kind != JObject or j{"items"} == nil or j["items"].kind != JArray: return
      result.ok = true
      for it in j["items"]:
        result.pods.add(ConductorPod(name: it{"metadata", "name"}.getStr, phase: it{"status", "phase"}.getStr,
                                     image: it{"spec", "containers"}[0]{"image"}.getStr)),
    deleteConductor: proc (name: string): bool =
      let jp = jstr(Generic_deleteNamespacedResource(kk.pods, kk.ns.cstring, name.cstring, "{\"gracePeriodSeconds\":0}".cstring))
      if jp.kind == JObject and jp{"status"}.getStr == "Failure" and jp{"reason"}.getStr != "NotFound":
        stderr.writeLine "jobcontroller: delete conductor " & name & " failed: " & $jp
        return false
      let js = jstr(Generic_deleteNamespacedResource(kk.secrets, kk.ns.cstring, name.cstring, "{}".cstring))
      if js.kind == JObject and js{"status"}.getStr == "Failure" and js{"reason"}.getStr != "NotFound":
        stderr.writeLine "jobcontroller: delete secret " & name & " failed: " & $js
      echo "jobcontroller: removed conductor ", name
      true,
    listPods: proc (): tuple[ok: bool, pods: seq[PodSummary]] =
      let j = jstr(Generic_listNamespaced(kk.pods, kk.ns.cstring, nil))
      if j.kind != JObject or j{"items"} == nil or j["items"].kind != JArray: return
      result.ok = true
      for it in j["items"]:
        result.pods.add PodSummary(name: it{"metadata", "name"}.getStr, phase: it{"status", "phase"}.getStr,
                                   createdAt: parseTime(it{"metadata", "creationTimestamp"}.getStr)))
