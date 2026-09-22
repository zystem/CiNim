## Spike 4 (part 3): the real static shim inside step Pods (RUN-010, STO-003, SEC-011, RUN-014).
## The shim binary is delivered through a ConfigMap (defaultMode 0755) because no image registry is involved here.
import std/[unittest, json, os, base64]
import common/k8sbind
import support/k8shelp

const
  ns = "cinim-m0c"
  img = "busybox:1.36"

proc shimPod(name, cmd: string; pvc = ""): string =
  var vols = %*[{"name": "shim", "configMap": {"name": "cicd-shim", "defaultMode": 493}}]    # 493 = 0755
  var mounts = %*[{"name": "shim", "mountPath": "/cicd/shim", "readOnly": true}]
  if pvc.len > 0:
    vols.add %*{"name": "ws", "persistentVolumeClaim": {"claimName": pvc}}
    mounts.add %*{"name": "ws", "mountPath": "/cicd/workspace"}
  else:
    vols.add %*{"name": "run", "emptyDir": {}}
    mounts.add %*{"name": "run", "mountPath": "/cicd/workspace"}
  let runDir = "/cicd/workspace/.run"
  $(%*{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "labels": {"cicd.io/run": "r1"}}, "spec": {
    "restartPolicy": "Never", "automountServiceAccountToken": false,
    "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": "step", "image": img, "volumeMounts": mounts,
      "command": ["/cicd/shim/cicd-shim", "--run-dir", runDir, "--", "sh", "-c", cmd],
      "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}, "readOnlyRootFilesystem": true},
      "resources": {"requests": {"cpu": "10m", "memory": "8Mi"}, "limits": {"memory": "64Mi"}}}],
    "volumes": vols}})

proc finish(pods: ptr genericClient_t; name: string): tuple[exitCode: int, msg: JsonNode] =
  let p = waitFor(pods, ns, name, phaseIs("Succeeded", "Failed"), 120000)
  let term = p{"status", "containerStatuses"}[0]{"state", "terminated"}
  result.exitCode = term{"exitCode"}.getInt(-1)
  let m = term{"message"}.getStr
  result.msg = if m.len > 0: parseJson(m) else: newJNull()

suite "spike 4c: static shim in step Pods":
  apiClient_setupGlobalEnv()
  let k = connectK8s()
  let pods = gclient(k, "", "v1", "pods")
  discard j(Generic_createResource(gclient(k, "", "v1", "namespaces"),
    $(%*{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}}), nil))

  test "the shim binary fits a ConfigMap and every Pod can start it":
    let bin = readFile("build/cicd-shim")
    echo "  METRIC shim size KiB = ", bin.len div 1024
    check bin.len < 5 * 1024 * 1024                      # RUN-010: at most 5 MiB
    let cm = create(gclient(k, "", "v1", "configmaps"), ns, $(%*{"apiVersion": "v1", "kind": "ConfigMap",
      "metadata": {"name": "cicd-shim"}, "binaryData": {"cicd-shim": encode(bin)}}))
    check cm{"kind"}.getStr == "ConfigMap"

  test "RUN-010 step through the shim: outputs are validated and reported in the termination message":
    check create(pods, ns, shimPod("ci-r1-1-1", "echo VERSION=1.2 >> \"$CICD_OUTPUT\"")){"kind"}.getStr == "Pod"
    let r = finish(pods, "ci-r1-1-1")
    echo "  METRIC termination message: ", r.msg
    check r.exitCode == 0
    check r.msg{"reason"}.getStr == "ok" and r.msg{"outputs"}.getInt == 1

  test "RUN-010 the step's own exit code is the Pod's exit code":
    check create(pods, ns, shimPod("ci-r1-2-1", "exit 3")){"kind"}.getStr == "Pod"
    let r = finish(pods, "ci-r1-2-1")
    check r.exitCode == 3 and r.msg{"reason"}.getStr == "failed"

  test "SEC-011 a deny-listed name ends the step with exit 70 and reason env_rejected":
    check create(pods, ns, shimPod("ci-r1-3-1", "echo LD_PRELOAD=/x.so >> \"$CICD_ENV\"")){"kind"}.getStr == "Pod"
    let r = finish(pods, "ci-r1-3-1")
    check r.exitCode == 70 and r.msg{"reason"}.getStr == "env_rejected"

  test "STO-003 + RUN-014 CICD_ENV written by one Pod is visible to the next Pod of the run (shared volume)":
    let pvcs = gclient(k, "", "v1", "persistentvolumeclaims")
    check create(pvcs, ns, $(%*{"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "run-1"},
      "spec": {"accessModes": ["ReadWriteOnce"], "storageClassName": "directpv-min-io", "resources": {"requests": {"storage": "1Gi"}}}})){"kind"}.getStr == "PersistentVolumeClaim"
    check create(pods, ns, shimPod("ci-r1-4-1", "echo FOO=bar >> \"$CICD_ENV\"", pvc = "run-1")){"kind"}.getStr == "Pod"
    check finish(pods, "ci-r1-4-1").exitCode == 0
    check create(pods, ns, shimPod("ci-r1-5-1", "test \"$FOO\" = bar", pvc = "run-1")){"kind"}.getStr == "Pod"
    let r = finish(pods, "ci-r1-5-1")
    check r.exitCode == 0 and r.msg{"reason"}.getStr == "ok"

  test "cleanup":
    discard Generic_deleteResource(gclient(k, "", "v1", "namespaces"), ns.cstring, nil)
