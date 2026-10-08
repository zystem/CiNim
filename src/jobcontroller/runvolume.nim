## The run volume (STO-001, STO-002, RUN-014): one PersistentVolumeClaim per run that every step Pod of the run mounts, so that the steps of a run
## see one `/cicd/workspace` and one `/cicd/state` (the env file of STO-003). The controller makes the claim before the first Pod of the run and deletes it
## when core says the run's storage may go (STO-006). Everything here is plain data and JSON, so that it is tested without a cluster; k8s.nim sends it.
import std/[json, strutils]

const
  runLabel* = "cicd.io/run"
  workspaceDir* = "workspace"          ## the subdirectory of the volume that is `/cicd/workspace`
  stateDir* = "state"                  ## ... and `/cicd/state`
  defaultSize* = "5Gi"

type
  VolumeSettings* = object
    enabled*: bool                     ## CINIM_RUN_STORAGE=on: steps share a volume; off: every Pod has an emptyDir of its own as before
    size*, storageClass*: string       ## the claim's request and class ("" = the cluster's default class)
    readWriteMany*: bool               ## the class offers ReadWriteMany; otherwise ReadWriteOnce, and the Pods of a run are kept on one node (STO-001)

func volumeSettings*(enabled, size, storageClass, access: string): VolumeSettings =
  ## from the environment (CINIM_RUN_STORAGE, CINIM_RUN_STORAGE_SIZE, CINIM_RUN_STORAGE_CLASS, CINIM_RUN_STORAGE_ACCESS)
  VolumeSettings(enabled: enabled == "on", size: (if size.len > 0: size else: defaultSize), storageClass: storageClass,
                 readWriteMany: access == "ReadWriteMany")

func withEnabled*(v: VolumeSettings; on: bool): VolumeSettings =
  ## the namespace's settings, for one Pod: on when the controller makes run volumes and the request says the step uses it
  result = v
  result.enabled = v.enabled and on

func claimName*(runId: string): string =
  ## the run id is shard-prefixed ("s1_<uuid>"): the underscore is not valid in a Kubernetes name
  "cicd-run-" & runId.replace("_", "-")

func claimBody*(v: VolumeSettings; runId: string): JsonNode =
  result = %*{"apiVersion": "v1", "kind": "PersistentVolumeClaim",
              "metadata": {"name": claimName(runId), "labels": {runLabel: runId, "app.kubernetes.io/part-of": "cinim"}},
              "spec": {"accessModes": [if v.readWriteMany: "ReadWriteMany" else: "ReadWriteOnce"],
                       "resources": {"requests": {"storage": v.size}}}}
  if v.storageClass.len > 0: result["spec"]["storageClassName"] = %v.storageClass

type PodVolume* = object
  ## the parts of a step Pod that the run volume adds
  mounts*, volumes*, initContainers*: seq[JsonNode]
  affinity*: JsonNode                  ## nil when the Pods of the run may run anywhere
  runDir*: string                      ## where the shim keeps the step's own files (CICD_OUTPUT, CICD_MASK)

func podVolume*(v: VolumeSettings; runId, image: string; shimMount, containerCtx, resources: JsonNode): PodVolume =
  ## Without a run volume the step has an emptyDir at `/cicd/workspace`, as before. With it: the claim's `workspace/` at `/cicd/workspace`, its `state/` at
  ## `/cicd/state`, and an emptyDir at `/cicd/run` for the step's own files. The two subdirectories are made by an init container, because the kubelet would make
  ## a missing `subPath` as root and a step that is not root could not write there; the init container runs as the step does (the same security context)
  ## and opens the two for everyone of the run, since the steps of one run are not all the same user (a build Pod is root of its user namespace).
  if not v.enabled:
    return PodVolume(mounts: @[%*{"name": "run", "mountPath": "/cicd/workspace"}],
                     volumes: @[%*{"name": "run", "emptyDir": {}}], runDir: "/cicd/workspace/.run")
  result.mounts = @[%*{"name": "run", "mountPath": "/cicd/run"},
                    %*{"name": "data", "mountPath": "/cicd/workspace", "subPath": workspaceDir},
                    %*{"name": "data", "mountPath": "/cicd/state", "subPath": stateDir}]
  result.volumes = @[%*{"name": "run", "emptyDir": {}},
                     %*{"name": "data", "persistentVolumeClaim": {"claimName": claimName(runId)}}]
  result.initContainers = @[%*{"name": "prepare", "image": image,
    "command": ["/cicd/shim/cicd-shim", "--prepare-volume", "/cicd/volume", workspaceDir, stateDir],
    "volumeMounts": [shimMount, {"name": "data", "mountPath": "/cicd/volume"}],
    "securityContext": containerCtx, "resources": resources}]
  result.runDir = "/cicd/run"
  if not v.readWriteMany:
    # one node for the run: with ReadWriteOnce the volume can be attached to one node. The first Pod of a run matches its own term, which Kubernetes allows.
    result.affinity = %*{"podAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [
      {"labelSelector": {"matchLabels": {runLabel: runId}}, "topologyKey": "kubernetes.io/hostname"}]}}
