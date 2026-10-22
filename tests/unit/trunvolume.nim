## STO-001, STO-002, STO-006, RUN-014: the volume the steps of a run share, as the controller makes it and mounts it.
import std/[unittest, json, strutils, sequtils]
import jobcontroller/runvolume

let shimMount = %*{"name": "shim", "mountPath": "/cicd/shim", "readOnly": true}
let ctx = %*{"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}
let res = %*{"requests": {"cpu": "10m"}}
let rwo = volumeSettings("", "", "")

suite "STO-001 the claim of a run":
  test "the name is a valid Kubernetes name made of the run id, the claim carries the run's label":
    check claimName("s1_0198-aa") == "cicd-run-s1-0198-aa"
    check claimBody(rwo, "s1_r")["metadata"]["labels"]["cicd.io/run"].getStr == "s1_r"
  test "the size defaults to 5Gi, the access mode to ReadWriteOnce and the class to the cluster's default":
    let c = claimBody(rwo, "s1_r")
    check c["spec"]["resources"]["requests"]["storage"].getStr == "5Gi"
    check c["spec"]["accessModes"][0].getStr == "ReadWriteOnce" and not c["spec"].hasKey("storageClassName")
  test "what the operator set is used":
    let c = claimBody(volumeSettings("20Gi", "fast", "ReadWriteMany"), "s1_r")
    check c["spec"]["resources"]["requests"]["storage"].getStr == "20Gi" and c["spec"]["storageClassName"].getStr == "fast"
    check c["spec"]["accessModes"][0].getStr == "ReadWriteMany"

suite "D-63 the /dev/shm of a job":
  test "a Pod has the default shm unless the job asked: then a volume in memory of that size is mounted at /dev/shm":
    let plain = podVolume(rwo, "s1_r", "img", shimMount, ctx, res)
    check plain.volumes.allIt(it["name"].getStr != "shm") and plain.mounts.allIt(it["mountPath"].getStr != "/dev/shm")
    let v = podVolume(rwo, "s1_r", "img", shimMount, ctx, res, "", "2Gi")
    let shm = v.volumes.filterIt(it["name"].getStr == "shm")[0]
    check shm["emptyDir"]["medium"].getStr == "Memory" and shm["emptyDir"]["sizeLimit"].getStr == "2Gi"
    check v.mounts.anyIt(it["name"].getStr == "shm" and it["mountPath"].getStr == "/dev/shm")

suite "STO-002 what a step Pod gets of it":
  test "D-55 the claim's workspace/ and state/ are mounted, the step's own files are in an emptyDir at /cicd/run":
    let v = podVolume(rwo, "s1_r", "img", shimMount, ctx, res)
    check v.runDir == "/cicd/run"
    var paths: seq[string]
    for m in v.mounts: paths.add m["mountPath"].getStr & "=" & m{"subPath"}.getStr
    check paths == @["/cicd/run=", "/cicd/workspace=workspace", "/cicd/state=state"]
    check v.volumes[1]["persistentVolumeClaim"]["claimName"].getStr == "cicd-run-s1-r"
  test "an init container makes the two directories before the step, with the step's own security context, from the step's image":
    let v = podVolume(rwo, "s1_r", "img", shimMount, ctx, res)
    check v.initContainers.len == 1
    let i = v.initContainers[0]
    check i["image"].getStr == "img" and i["securityContext"] == ctx
    check i["command"].elems.mapIt(it.getStr) == @["/cicd/shim/cicd-shim", "--prepare-volume", "/cicd/volume", "workspace", "state"]
    check i["volumeMounts"][1]["mountPath"].getStr == "/cicd/volume" and not i["volumeMounts"][1].hasKey("subPath")
  test "RUN-014 with ReadWriteOnce the Pods of a run are kept on one node; with ReadWriteMany they are not":
    let a = podVolume(rwo, "s1_r", "img", shimMount, ctx, res).affinity
    let term = a["podAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"][0]
    check term["labelSelector"]["matchLabels"]["cicd.io/volume"].getStr == "s1_r" and term["topologyKey"].getStr == "kubernetes.io/hostname"
    check podVolume(volumeSettings("", "", "ReadWriteMany"), "s1_r", "img", shimMount, ctx, res).affinity.isNil

suite "STO-002 (D-74) the volumes of the runs are spread over the nodes":
  test "a Pod asks to be spread over the nodes among the step Pods of the namespace (every run, every volume), softly: a full or absent node does not leave it waiting":
    for vol in ["", "s1_job"]:
      let c = podVolume(rwo, "s1_r", "img", shimMount, ctx, res, vol).spread[0]
      check c["topologyKey"].getStr == "kubernetes.io/hostname" and c["maxSkew"].getInt == 1 and c["whenUnsatisfiable"].getStr == "ScheduleAnyway"
      check c["labelSelector"]["matchExpressions"][0]["key"].getStr == "cicd.io/run" and c["labelSelector"]["matchExpressions"][0]["operator"].getStr == "Exists"
  test "with ReadWriteMany too (the Pods are free to be anywhere, and are then spread as well)":
    check podVolume(volumeSettings("", "", "ReadWriteMany"), "s1_r", "img", shimMount, ctx, res).spread.len == 1

suite "STO-002 the volume of a job with workspace = isolated":
  test "its claim is named for the job, carries the run's label (the run's storage goes with the run) and the job's as the volume":
    check claimName("s1_r", "s1_0198-job") == "cicd-job-s1-0198-job"
    let l = claimBody(rwo, "s1_r", "s1_job")["metadata"]["labels"]
    check l["cicd.io/run"].getStr == "s1_r" and l["cicd.io/volume"].getStr == "s1_job"
    check claimBody(rwo, "s1_r")["metadata"]["labels"]["cicd.io/volume"].getStr == "s1_r"      # the run's own volume is named by the run
  test "a Pod of the job mounts it, and nothing of the run's volume":
    let v = podVolume(rwo, "s1_r", "img", shimMount, ctx, res, "s1_job")
    check v.volumes[1]["persistentVolumeClaim"]["claimName"].getStr == "cicd-job-s1-job"
    check v.volumes.allIt(it{"persistentVolumeClaim", "claimName"}.getStr != "cicd-run-s1-r")
    var paths: seq[string]
    for m in v.mounts: paths.add m["mountPath"].getStr & "=" & m{"subPath"}.getStr
    check paths == @["/cicd/run=", "/cicd/workspace=workspace", "/cicd/state=state"]
  test "the Pods of one job are kept on one node (ReadWriteOnce), by the job's label, so that the job does not pull the run's other Pods to its node":
    let term = podVolume(rwo, "s1_r", "img", shimMount, ctx, res, "s1_job").affinity["podAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"][0]
    check term["labelSelector"]["matchLabels"]["cicd.io/volume"].getStr == "s1_job"
    check podVolume(volumeSettings("", "", "ReadWriteMany"), "s1_r", "img", shimMount, ctx, res, "s1_job").affinity.isNil
