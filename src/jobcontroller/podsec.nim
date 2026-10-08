## The security class of a step Pod (D-42). An ordinary step runs as it did before: non-root, nothing added, `restricted`. A step of the
## build profile (`profile = "build"`, A.13) becomes a build Pod: label `cinim.io/profile=build`, a user namespace of its own
## (`hostUsers: false`, so root in the container is not root on the node), and one of two classes, set by the operator for the shard:
##   RuntimeDefault  Kaniko: root in the container, the default seccomp profile, every capability dropped but a few (measured in A.13)
##   Localhost       rootless BuildKit and Buildah: user 1000, the Localhost profile profiles/cinim-userns.json (deploy/seccomp) that is
##                   installed on the nodes, the capabilities of the image (newuidmap is setuid)
## The admission policy of the chart (deploy/examples/build-pods/policy.yaml) holds both to the same limits: only this controller may make
## a build Pod, it must have `hostUsers: false`, one of the two seccomp profiles and no more than the six capabilities of `buildCaps`.
import std/[json, strutils, sequtils]

const
  buildLabel* = "cinim.io/profile"
  buildProfile* = "build"
  deployProfile* = "deploy"
  userNsProfile* = "profiles/cinim-userns.json"       ## relative to the kubelet's seccomp directory, as `localhostProfile` wants it
  defaultBuildEphemeral* = "10Gi"
  defaultBuildCaps* = "CHOWN,DAC_OVERRIDE,FOWNER,SETUID,SETGID,SETFCAP"

type
  BuildSettings* = object
    enabled*: bool                 ## the shard has a build profile (CINIM_BUILD): without it a step of the profile is an ordinary Pod
    caps*: seq[string]
    memoryLimit*: string
    ephemeralLimit*: string        ## the ephemeral-storage limit of a build Pod (images are built in it): 10Gi; an ordinary step gets the LimitRange's
    localhost*: bool               ## the Localhost seccomp class (rootless builders); false: RuntimeDefault (Kaniko)

  PodSecurity* = object
    podCtx*, containerCtx*, resources*: JsonNode
    hostUsers*: bool
    labels*: JsonNode              ## added to the Pod's labels

func buildSettings*(enabled: string; caps, memoryLimit, seccomp: string; ephemeralLimit = ""): BuildSettings =
  ## from the environment (CINIM_BUILD, CINIM_BUILD_CAPS, CINIM_BUILD_MEMORY_LIMIT, CINIM_BUILD_SECCOMP); "" is the default of each
  BuildSettings(enabled: enabled == "on",
                caps: (if caps.len > 0: caps else: defaultBuildCaps).split(',').filterIt(it.len > 0),
                memoryLimit: (if memoryLimit.len > 0: memoryLimit else: "4Gi"),
                ephemeralLimit: (if ephemeralLimit.len > 0: ephemeralLimit else: defaultBuildEphemeral),
                localhost: seccomp == "Localhost")

func podSecurity*(b: BuildSettings; build: bool; deploy = false): PodSecurity =
  ## a step that asks for the build profile on a shard without one is an ordinary Pod (the core refuses it earlier). A step of the deploy profile
  ## (D-48) is an ordinary Pod in every respect of security, and differs by one label, which the network policies of its namespace select:
  ## only a deploy Pod may reach the targets of a deployment.
  if not (build and b.enabled):
    return PodSecurity(
      podCtx: %*{"runAsNonRoot": true, "runAsUser": 1000, "fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
      containerCtx: %*{"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}},
      resources: %*{"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"memory": "128Mi"}},
      hostUsers: true, labels: (if deploy and not build: %*{buildLabel: deployProfile} else: newJObject()))
  let resources = %*{"requests": {"cpu": "250m", "memory": "512Mi", "ephemeral-storage": "1Gi"},
                     "limits": {"memory": b.memoryLimit, "ephemeral-storage": b.ephemeralLimit}}
  let labels = %*{buildLabel: buildProfile}
  if b.localhost:
    PodSecurity(
      podCtx: %*{"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000, "seccompProfile": {"type": "Localhost", "localhostProfile": userNsProfile}},
      containerCtx: newJObject(), resources: resources, hostUsers: false, labels: labels)
  else:
    PodSecurity(
      podCtx: %*{"runAsUser": 0, "fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
      containerCtx: %*{"capabilities": {"drop": ["ALL"], "add": b.caps}}, resources: resources, hostUsers: false, labels: labels)
