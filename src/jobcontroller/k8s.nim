## The real Backend: the official Kubernetes C client (A.6, D-26). The only module of the controller that knows
## Kubernetes; it turns the platform's PodRequest into a Pod spec and answers the questions logic.nim asks of the cluster.
## SEC-010 per-job projected tokens are deferred: the shim gets the shared CURVE "client" identity through a Secret.
import std/[os, json, strutils, times, base64, atomics, sequtils]
import ../common/[k8sbind, envname]
import backend, podsec

type K8s* = object
  api: ptr apiClient_t
  pods, configmaps, secrets: ptr genericClient_t
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

let buildSettings = podsec.buildSettings(getEnv("CINIM_BUILD", "off"), getEnv("CINIM_BUILD_CAPS"), getEnv("CINIM_BUILD_MEMORY_LIMIT"),
                                         getEnv("CINIM_BUILD_SECCOMP"), getEnv("CINIM_BUILD_EPHEMERAL_LIMIT"))
  ## the build profile of the namespace (D-42); what a build Pod is is in podsec.nim

proc podBody(r: PodRequest): JsonNode =
  let sec = podsec.podSecurity(buildSettings, r.build)
  result = %*{
    "apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": r.name, "labels": {"cicd.io/run": r.runId}},
    "spec": {
      "restartPolicy": "Never", "automountServiceAccountToken": false,
      # the kubelet's SIGTERM -> SIGKILL window must cover the shim's own: build grace (20 s) + a short log flush
      "terminationGracePeriodSeconds": 60,
      "securityContext": sec.podCtx,
      "containers": [{"name": "step", "image": r.image, "command": r.cmd,
        "volumeMounts": (@[%*{"name": "shim", "mountPath": "/cicd/shim", "readOnly": true},
                          %*{"name": "run", "mountPath": "/cicd/workspace"}] &
          (if r.logging: @[%*{"name": "certs", "mountPath": "/cicd/certs", "readOnly": true},
                           %*{"name": "spool", "mountPath": "/cicd/spool"}] else: @[])),
        "securityContext": sec.containerCtx,
        "resources": sec.resources}],
      "volumes": (@[%*{"name": "shim", "configMap": {"name": shimConfigMap, "defaultMode": 493}},
                    %*{"name": "run", "emptyDir": {}}] &   # the shim's --run-dir (CICD_ENV/CICD_OUTPUT) lives here
        (if r.logging: @[%*{"name": "spool", "emptyDir": {"sizeLimit": $(r.spoolBytes + 1024 * 1024)}},   # kubelet evicts above this; the shim stops itself at spoolBytes
                         %*{"name": "certs", "secret": {"secretName": curveSecret, "items": [   # shim reads <certs-dir>/curve/<name>.{pub,key}
          {"key": "client.pub", "path": "curve/client.pub"}, {"key": "client.key", "path": "curve/client.key"},
          {"key": "core.pub", "path": "curve/core.pub"}]}}] else: @[]))}}
  if r.secrets.len > 0:
    # the step's secrets: a placeholder per name, which the shim replaces with the value it fetches from core; the Pod's specification holds no value
    var env = newJArray()
    for n in r.secrets: env.add %*{"name": n, "value": stepSecretPlaceholder(n)}
    result["spec"]["containers"][0]["env"] = env
  for k, v in sec.labels: result["metadata"]["labels"][k] = v
  if not sec.hostUsers: result["spec"]["hostUsers"] = %false

var execCaptured {.threadvar.}: string

proc onExecData(data: ptr pointer; len: ptr clong) {.cdecl.} =
  if data != nil and data[] != nil and len != nil and len[] > 0:
    let n = int(len[])
    let old = execCaptured.len
    execCaptured.setLen(old + n)
    copyMem(addr execCaptured[old], data[], n)

type
  ExecJob = ref object
    api: ptr apiClient_t
    ns, name, container, command: string
    done: Atomic[bool]
    ok: bool
    output: string

proc execThread(job: ExecJob) {.thread.} =
  ## the C client's WebSocket exec (kube_exec): one connection, blocks until the command's stream closes - and, if the API
  ## refuses or the Pod is not up, may keep retrying for a long time. Hence a thread of its own, which the caller can give up on.
  {.cast(gcsafe).}:
    let wsc = wsclient_create(job.api.basePath, job.api.sslConfig, job.api.apiKeys_BearerToken, 0)
    if wsc != nil:
      setCallback(wsc, onExecData)
      execCaptured = ""
      if kube_exec(wsc, job.ns.cstring, job.name.cstring, job.container.cstring, 0, 1, 0, job.command.cstring) == 0:
        discard wsclient_run(wsc, 0)
        job.ok = true
        job.output = execCaptured
      wsclient_free(wsc)
    job.done.store(true)

proc execInPod(k: K8s; name, container, command: string; timeoutSeconds = 25): tuple[ok: bool, output: string] =
  ## Gives up after `timeoutSeconds`: the thread is left behind (it ends when the Pod is removed and its stream closes) and the
  ## caller carries on - a stuck exec must never stop the controller from deleting a Pod.
  let started = epochTime()
  var job = ExecJob(api: k.api, ns: k.ns, name: name, container: container, command: command)
  GC_ref(job)
  var th: Thread[ExecJob]
  createThread(th, execThread, job)
  let until = epochTime() + timeoutSeconds.float
  while not job.done.load and epochTime() < until: sleep 50
  if job.done.load:
    joinThread(th)
    result = (job.ok, job.output)
    GC_unref(job)
    if epochTime() - started > 3.0:
      stderr.writeLine "jobcontroller: exec in " & name & " took " & formatFloat(epochTime() - started, ffDecimal, 1) & " s (" &
        $job.output.len & " bytes): " & command[0 ..< min(command.len, 60)]
  else:
    stderr.writeLine "jobcontroller: exec in " & name & " did not finish within " & $timeoutSeconds & " s, giving up on it"
    # the thread is detached on purpose (job stays referenced for as long as it runs)

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
    execInPod: proc (name, container, command: string): tuple[ok: bool, output: string] =
      execInPod(kk, name, container, command),
    listPods: proc (): tuple[ok: bool, pods: seq[PodSummary]] =
      let j = jstr(Generic_listNamespaced(kk.pods, kk.ns.cstring, nil))
      if j.kind != JObject or j{"items"} == nil or j["items"].kind != JArray: return
      result.ok = true
      for it in j["items"]:
        result.pods.add PodSummary(name: it{"metadata", "name"}.getStr, phase: it{"status", "phase"}.getStr,
                                   createdAt: parseTime(it{"metadata", "creationTimestamp"}.getStr)))
