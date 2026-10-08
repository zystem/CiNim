## STO-001, STO-002, STO-006, RUN-014: the volume the steps of a run share, as the controller makes it and mounts it.
import std/[unittest, json, strutils, sequtils]
import jobcontroller/runvolume

let shimMount = %*{"name": "shim", "mountPath": "/cicd/shim", "readOnly": true}
let ctx = %*{"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}
let res = %*{"requests": {"cpu": "10m"}}
let rwo = volumeSettings("on", "", "", "")

suite "STO-001 the claim of a run":
  test "the name is a valid Kubernetes name made of the run id, the claim carries the run's label":
    check claimName("s1_0198-aa") == "cicd-run-s1-0198-aa"
    check claimBody(rwo, "s1_r")["metadata"]["labels"]["cicd.io/run"].getStr == "s1_r"
  test "the size defaults to 5Gi, the access mode to ReadWriteOnce and the class to the cluster's default":
    let c = claimBody(rwo, "s1_r")
    check c["spec"]["resources"]["requests"]["storage"].getStr == "5Gi"
    check c["spec"]["accessModes"][0].getStr == "ReadWriteOnce" and not c["spec"].hasKey("storageClassName")
  test "what the operator set is used":
    let c = claimBody(volumeSettings("on", "20Gi", "fast", "ReadWriteMany"), "s1_r")
    check c["spec"]["resources"]["requests"]["storage"].getStr == "20Gi" and c["spec"]["storageClassName"].getStr == "fast"
    check c["spec"]["accessModes"][0].getStr == "ReadWriteMany"
  test "the volumes are off unless the controller is told to make them, and a request can switch them off for a Pod":
    check not volumeSettings("off", "", "", "").enabled and not volumeSettings("", "", "", "").enabled
    check not rwo.withEnabled(false).enabled and rwo.withEnabled(true).enabled
    check not volumeSettings("off", "", "", "").withEnabled(true).enabled

suite "STO-002 what a step Pod gets of it":
  test "without a run volume the step has an emptyDir at the workspace and keeps its files in it, as before":
    let v = podVolume(volumeSettings("off", "", "", ""), "s1_r", "img", shimMount, ctx, res)
    check v.runDir == "/cicd/workspace/.run" and v.initContainers.len == 0 and v.affinity.isNil
    check v.mounts[0]["mountPath"].getStr == "/cicd/workspace" and v.volumes[0].hasKey("emptyDir")
  test "with it the claim's workspace/ and state/ are mounted, the step's own files are in an emptyDir at /cicd/run":
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
    check term["labelSelector"]["matchLabels"]["cicd.io/run"].getStr == "s1_r" and term["topologyKey"].getStr == "kubernetes.io/hostname"
    check podVolume(volumeSettings("on", "", "", "ReadWriteMany"), "s1_r", "img", shimMount, ctx, res).affinity.isNil
