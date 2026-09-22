## Spike 4 (part 2): storage, cleanup ownership, lease fencing and the job token contract (STO-001, RUN-014, RUN-002, SEC-010).
import std/[unittest, json, os, osproc, strutils, base64, sequtils]
import common/k8sbind
import support/k8shelp

const
  ns = "cinim-m0b"
  img = "busybox:1.36"
  sc = "directpv-min-io"

let kubectl = "kubectl --context admin@home -n " & ns

proc kget(args: string): string = execProcess(kubectl & " " & args).strip

suite "spike 4b: storage, ownership, lease and job token":
  apiClient_setupGlobalEnv()
  let k = connectK8s()
  let pods = gclient(k, "", "v1", "pods")
  let pvcs = gclient(k, "", "v1", "persistentvolumeclaims")
  let secrets = gclient(k, "", "v1", "secrets")
  let leases = gclient(k, "coordination.k8s.io", "v1", "leases")
  discard j(Generic_createResource(gclient(k, "", "v1", "namespaces"),
    $(%*{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}}), nil))

  test "STO-001 a run PVC is created once and shared by step Pods on one node (RWO, node-local StorageClass)":
    let pvc = create(pvcs, ns, $(%*{"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "run-1"},
      "spec": {"accessModes": ["ReadWriteOnce"], "storageClassName": sc, "resources": {"requests": {"storage": "1Gi"}}}}))
    check pvc{"kind"}.getStr == "PersistentVolumeClaim"
    # step 1 writes, step 2 (a NEW Pod, RUN-014) reads what step 1 left on the volume
    check create(pods, ns, stepPod("ci-r1-1-1", img, "echo hello > /cicd/workspace/a.txt", pvc = "run-1")){"kind"}.getStr == "Pod"
    check waitFor(pods, ns, "ci-r1-1-1", phaseIs("Succeeded", "Failed"), 90000){"status", "phase"}.getStr == "Succeeded"
    let node1 = read(pods, ns, "ci-r1-1-1"){"spec", "nodeName"}.getStr
    check create(pods, ns, stepPod("ci-r1-2-1", img, "test \"$(cat /cicd/workspace/a.txt)\" = hello", pvc = "run-1")){"kind"}.getStr == "Pod"
    let p2 = waitFor(pods, ns, "ci-r1-2-1", phaseIs("Succeeded", "Failed"), 90000)
    check p2{"status", "phase"}.getStr == "Succeeded"
    echo "  METRIC step1 node=", node1, " step2 node=", p2{"spec", "nodeName"}.getStr
    check p2{"spec", "nodeName"}.getStr == node1      # the scheduler follows the volume

  test "STO-001 two Pods of the same run run concurrently on the volume node":
    for n in ["ci-r1-3-1", "ci-r1-4-1"]:
      check create(pods, ns, stepPod(n, img, "sleep 20", pvc = "run-1")){"kind"}.getStr == "Pod"
    for n in ["ci-r1-3-1", "ci-r1-4-1"]:
      check waitFor(pods, ns, n, phaseIs("Running"), 60000){"status", "phase"}.getStr == "Running"

  test "STO-001 a Pod forced onto another node cannot use a node-local RWO volume (stays Pending)":
    let volNode = read(pods, ns, "ci-r1-1-1"){"spec", "nodeName"}.getStr
    var other = ""
    for n in ["talos-worker-1", "talos-worker-2", "talos-worker-3"]:
      if n != volNode: other = n; break
    check create(pods, ns, stepPod("ci-r1-5-1", img, "true", pvc = "run-1", extra = %*{"nodeName": other})){"kind"}.getStr == "Pod"
    sleep 15000
    let p = read(pods, ns, "ci-r1-5-1")
    echo "  METRIC forced node=", other, " phase=", p{"status", "phase"}.getStr, " reason=", p{"status", "containerStatuses"}.pretty.len
    check p{"status", "phase"}.getStr in ["Pending"]

  test "RUN-005 a Secret owned by the Pod is garbage-collected with it":
    check create(pods, ns, stepPod("ci-r1-6-1", img, "sleep 60")){"kind"}.getStr == "Pod"
    let uid = waitFor(pods, ns, "ci-r1-6-1", phaseIs("Running"), 60000){"metadata", "uid"}.getStr
    check uid.len > 0
    check create(secrets, ns, $(%*{"apiVersion": "v1", "kind": "Secret",
      "metadata": {"name": "ci-r1-6-1-env", "ownerReferences": [{"apiVersion": "v1", "kind": "Pod", "name": "ci-r1-6-1", "uid": uid}]},
      "stringData": {"TOKEN": "s3cr3t"}})){"kind"}.getStr == "Secret"
    discard remove(pods, ns, "ci-r1-6-1")
    var gone = false
    for _ in 0 ..< 60:
      if read(secrets, ns, "ci-r1-6-1-env"){"reason"}.getStr == "NotFound": gone = true; break
      sleep 1000
    check gone

  test "RUN-002 Lease: renewal with the current resourceVersion succeeds, a stale one is rejected (409)":
    let body = proc (holder, rv, renew: string): string =
      # an update that changes nothing is a no-op and keeps the resourceVersion, so every renewal carries a new renewTime
      var o = %*{"apiVersion": "coordination.k8s.io/v1", "kind": "Lease", "metadata": {"name": "shard-scheduler"},
        "spec": {"holderIdentity": holder, "leaseDurationSeconds": 15, "renewTime": renew}}
      if rv.len > 0: o["metadata"]["resourceVersion"] = %rv
      $o
    let l1 = create(leases, ns, body("sched-a", "", "2026-09-21T10:00:00.000000Z"))
    check l1{"kind"}.getStr == "Lease"
    let rv1 = l1{"metadata", "resourceVersion"}.getStr
    let l2 = replace(leases, ns, "shard-scheduler", body("sched-a", rv1, "2026-09-21T10:00:05.000000Z"))
    check l2{"kind"}.getStr == "Lease"
    check l2{"metadata", "resourceVersion"}.getStr != rv1
    let stale = replace(leases, ns, "shard-scheduler", body("sched-b", rv1, "2026-09-21T10:00:06.000000Z"))   # a second scheduler with an old view
    check stale{"code"}.getInt == 409
    check stale{"reason"}.getStr == "Conflict"

  test "SEC-010 projected job token: audience, 10 min TTL, bound to the Pod":
    check create(pods, ns, stepPod("ci-r1-7-1", img, "cat /cicd/run/token/token", token = true)){"kind"}.getStr == "Pod"
    let p = waitFor(pods, ns, "ci-r1-7-1", phaseIs("Succeeded", "Failed"), 90000)
    check p{"status", "phase"}.getStr == "Succeeded"
    let tok = kget("logs ci-r1-7-1").strip
    let parts = tok.split('.')
    check parts.len == 3
    let payload = parseJson(decode(parts[1].replace('-', '+').replace('_', '/') & "=".repeat((4 - parts[1].len mod 4) mod 4)))
    echo "  METRIC token claims: aud=", payload["aud"], " ttl_s=", payload["exp"].getInt - payload["iat"].getInt,
      " sub=", payload["sub"].getStr, " pod=", payload{"kubernetes.io", "pod", "name"}.getStr
    check payload["aud"].getElems.mapIt(it.getStr) == @["cicd-shard"]
    check payload["exp"].getInt - payload["iat"].getInt <= 600
    check payload{"kubernetes.io", "pod", "name"}.getStr == "ci-r1-7-1"
    check payload{"kubernetes.io", "pod", "uid"}.getStr == p{"metadata", "uid"}.getStr
    writeFile("/tmp/cinim-job-token.jwt", tok)

  test "cleanup":
    discard Generic_deleteResource(gclient(k, "", "v1", "namespaces"), ns.cstring, nil)
