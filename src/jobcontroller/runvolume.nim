## The run volume (STO-001, STO-002, RUN-014): one PersistentVolumeClaim per run that every step Pod of the run mounts, so that the steps of a run
## see one `/cicd/workspace` and one `/cicd/state` (the env file of STO-003). The controller makes the claim before the first Pod of the run and deletes it
## when core says the run's storage may go (STO-006). Everything here is plain data and JSON, so that it is tested without a cluster; k8s.nim sends it.
import std/[json, strutils]

const
  runLabel* = "cicd.io/run"
  volumeLabel* = "cicd.io/volume"      ## on the claim and on every Pod that mounts it: the run's id for the run's volume, the job's for a job's own (STO-002). The affinity of the Pods that share a volume names it
  workspaceDir* = "workspace"          ## the subdirectory of the volume that is `/cicd/workspace`
  stateDir* = "state"                  ## ... and `/cicd/state`
  defaultSize* = "5Gi"

type
  VolumeSettings* = object
    size*, storageClass*: string       ## the claim's request and class ("" = the cluster's default class)
    readWriteMany*: bool               ## the class offers ReadWriteMany; otherwise ReadWriteOnce, and the Pods of a run are kept on one node (STO-001)

func volumeSettings*(size, storageClass, access: string): VolumeSettings =
  ## from the environment (CINIM_RUN_STORAGE_SIZE, CINIM_RUN_STORAGE_CLASS, CINIM_RUN_STORAGE_ACCESS). The run volume is not optional (D-55): the steps of a run share it, and
  ## the spool of the log and the manifest of the artifacts are on it.
  VolumeSettings(size: (if size.len > 0: size else: defaultSize), storageClass: storageClass, readWriteMany: access == "ReadWriteMany")

func claimName*(runId: string; volume = ""): string =
  ## the run id is shard-prefixed ("s1_<11 characters of base32>"): the underscore is not valid in a Kubernetes name. `volume` is the id of a job that has a volume of its own (`workspace = "isolated"`),
  ## "" for the volume of the run
  if volume.len > 0: "cicd-job-" & volume.replace("_", "-") else: "cicd-run-" & runId.replace("_", "-")

func volumeId*(runId: string; volume = ""): string = (if volume.len > 0: volume else: runId)

func claimBody*(v: VolumeSettings; runId: string; volume = ""): JsonNode =
  ## a job's volume carries the run's label as well, so that the run's storage goes with the run (STO-006)
  result = %*{"apiVersion": "v1", "kind": "PersistentVolumeClaim",
              "metadata": {"name": claimName(runId, volume), "labels": {runLabel: runId, volumeLabel: volumeId(runId, volume), "app.kubernetes.io/part-of": "cinim"}},
              "spec": {"accessModes": [if v.readWriteMany: "ReadWriteMany" else: "ReadWriteOnce"],
                       "resources": {"requests": {"storage": v.size}}}}
  if v.storageClass.len > 0: result["spec"]["storageClassName"] = %v.storageClass

type PodVolume* = object
  ## the parts of a step Pod that the run volume adds
  mounts*, volumes*, initContainers*: seq[JsonNode]
  affinity*: JsonNode                  ## nil when the Pods of the run may run anywhere
  runDir*: string                      ## where the shim keeps the step's own files (CICD_OUTPUT, CICD_MASK)

func podVolume*(v: VolumeSettings; runId, image: string; shimMount, containerCtx, resources: JsonNode; volume = ""; shm = ""): PodVolume =
  ## The claim's `workspace/` at `/cicd/workspace`, its `state/` at `/cicd/state`, and an emptyDir at `/cicd/run` for the step's own files. The two subdirectories are made by an init container, because the kubelet would make
  ## a missing `subPath` as root and a step that is not root could not write there; the init container runs as the step does (the same security context)
  ## and opens the two for everyone of the run, since the steps of one run are not all the same user (a build Pod is root of its user namespace).
  result.mounts = @[%*{"name": "run", "mountPath": "/cicd/run"},
                    %*{"name": "data", "mountPath": "/cicd/workspace", "subPath": workspaceDir},
                    %*{"name": "data", "mountPath": "/cicd/state", "subPath": stateDir}]
  result.volumes = @[%*{"name": "run", "emptyDir": {}},
                     %*{"name": "data", "persistentVolumeClaim": {"claimName": claimName(runId, volume)}}]
  result.initContainers = @[%*{"name": "prepare", "image": image,
    "command": ["/cicd/shim/cicd-shim", "--prepare-volume", "/cicd/volume", workspaceDir, stateDir],
    "volumeMounts": [shimMount, {"name": "data", "mountPath": "/cicd/volume"}],
    "securityContext": containerCtx, "resources": resources}]
  result.runDir = "/cicd/run"
  if shm.len > 0:
    # `shm = "2Gi"` of the job: /dev/shm backed by memory instead of the 64Mi a Pod has
    result.mounts.add %*{"name": "shm", "mountPath": "/dev/shm"}
    result.volumes.add %*{"name": "shm", "emptyDir": {"medium": "Memory", "sizeLimit": shm}}
  if not v.readWriteMany:
    # one node for the Pods that share the volume: with ReadWriteOnce it can be attached to one node. The first Pod matches its own term, which Kubernetes allows. The term names the
    # volume, not the run: a job with a volume of its own does not tie the run's other Pods to its node, and they do not tie it to theirs (STO-002)
    result.affinity = %*{"podAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [
      {"labelSelector": {"matchLabels": {volumeLabel: volumeId(runId, volume)}}, "topologyKey": "kubernetes.io/hostname"}]}}
