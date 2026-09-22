## Helpers over the official Kubernetes C client's generic JSON API (test support).
import std/[json, os, times]
import common/k8sbind

type K8s* = object
  api*: ptr apiClient_t

proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc connectK8s*(): K8s =
  var base: cstring
  var ssl: ptr sslConfig_t
  var keys: ptr list_t
  doAssert load_kube_config(cast[cstringArray](addr base), addr ssl, addr keys, nil) == 0, "cannot load kubeconfig"
  result.api = apiClient_create_with_base_path(base, ssl, keys)
  doAssert result.api != nil

proc gclient*(k: K8s; group, version, plural: string): ptr genericClient_t =
  genericClient_create(k.api, group.cstring, version.cstring, plural.cstring)

proc j*(raw: cstring): JsonNode =
  if raw == nil: return newJNull()
  let text = $raw
  c_free(raw)
  try: result = parseJson(text)
  except JsonParsingError:
    echo "  NOT JSON (", text.len, " bytes): ", text[0 ..< min(200, text.len)]
    raise

proc create*(g: ptr genericClient_t; ns, body: string): JsonNode = j(Generic_createNamespacedResource(g, ns.cstring, body.cstring, nil))
proc read*(g: ptr genericClient_t; ns, name: string): JsonNode = j(Generic_readNamespacedResource(g, ns.cstring, name.cstring))
proc remove*(g: ptr genericClient_t; ns, name: string): JsonNode = j(Generic_deleteNamespacedResource(g, ns.cstring, name.cstring, nil))
proc replace*(g: ptr genericClient_t; ns, name, body: string): JsonNode = j(Generic_replaceNamespacedResource(g, ns.cstring, name.cstring, body.cstring))

proc waitFor*(g: ptr genericClient_t; ns, name: string; pred: proc (o: JsonNode): bool; timeoutMs = 60000): JsonNode =
  ## polls the object until pred(o) holds (or it disappears when pred accepts a NotFound Status)
  var waited = 0
  while waited < timeoutMs:
    result = read(g, ns, name)
    if pred(result): return
    sleep 250
    waited += 250

proc phaseIs*(want: varargs[string]): proc (o: JsonNode): bool =
  let w = @want
  result = proc (o: JsonNode): bool = o{"status", "phase"}.getStr in w

proc stepPod*(name, image: string; cmd: string; pvc = ""; extra: JsonNode = nil; token = false): string =
  ## restricted-profile step Pod; optionally mounts a PVC at /cicd/workspace and a projected token
  var vols = newJArray()
  var mounts = newJArray()
  if pvc.len > 0:
    vols.add %*{"name": "ws", "persistentVolumeClaim": {"claimName": pvc}}
    mounts.add %*{"name": "ws", "mountPath": "/cicd/workspace"}
  if token:
    vols.add %*{"name": "tok", "projected": {"sources": [{"serviceAccountToken": {"audience": "cicd-shard", "expirationSeconds": 600, "path": "token"}}]}}
    mounts.add %*{"name": "tok", "mountPath": "/cicd/run/token", "readOnly": true}
  var spec = %*{
    "restartPolicy": "Never", "automountServiceAccountToken": false,
    "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": "step", "image": image, "command": ["sh", "-c", cmd], "volumeMounts": mounts,
      "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}},
      "resources": {"requests": {"cpu": "10m", "memory": "8Mi"}, "limits": {"memory": "64Mi"}}}],
    "volumes": vols}
  if extra != nil:
    for k, v in extra: spec[k] = v
  $(%*{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "labels": {"cicd.io/run": "r1"}}, "spec": spec})
