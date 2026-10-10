## The conductors of an organisation, from the controller's side (docs/conductors.md section 5, phase 3). The core computes how many there should be and gives
## each its credential (`ConductorPlan` in the answer to a report); the controller makes the Pods `cinim-conductor-1` .. `-N` in the organisation's namespace, finds
## the ones that exist (adoption: it keeps no list of its own), and removes a Pod only after it has ended. It never stops a conductor that runs: the core drains a
## conductor that is idle and above the number wanted (`conductor.drain` on the push channel), the conductor exits with 0, and the Pod is then removed here.
## Pure but for the `Backend`: the Pod and its Secret are plain JSON, the decisions are tested against a fake cluster.
import std/[json, tables, strutils, options, sequtils]
import backend

const
  conductorLabel* = "cinim-conductor"          ## the name label of a conductor Pod; the network policy of the namespace and this controller select it
  podPrefix = "cinim-conductor-"
  retrySeconds = 10.0                          ## a conductor that could not be made is tried again after this long

type
  ConductorSpec* = object
    image*: string
    runsPerConductor*, drainSeconds*: int
    streamAddr*: string                        ## the core's push channel as the Pods of this namespace reach it
    namespace*: string                         ## the organisation's namespace: the identity the conductor proves
    curveSecret*: string                       ## the Secret with the keys of the transport (core.pub, client.pub, client.key) that the core made for the controller

  ActionKind* = enum akCreate, akDelete

  Action* = object
    kind*: ActionKind
    n*: int
    name*: string

func conductorPodName*(n: int): string = podPrefix & $n

func conductorPodNumber*(name: string): Option[int] =
  if not name.startsWith(podPrefix) or name.len == podPrefix.len: return none(int)
  for ch in name[podPrefix.len .. ^1]:
    if ch notin {'0'..'9'}: return none(int)
  let n = parseInt(name[podPrefix.len .. ^1])
  if n >= 1: some(n) else: none(int)

func ended(p: ConductorPod): bool = p.phase in ["Succeeded", "Failed"]

proc planActions*(wanted: int; existing: seq[ConductorPod]; now: float; tried: var Table[int, float]): seq[Action] =
  ## Make the first `wanted`; remove a Pod that has ended (made again on a later round); leave every Pod that runs, whatever its number: the core drains the idle
  ## ones above the number wanted. `tried`: when each number was last made, so that a conductor that cannot be made is not tried every round.
  var byNumber = initTable[int, ConductorPod]()
  for p in existing:
    let n = conductorPodNumber(p.name)
    if n.isSome: byNumber[n.get] = p
  for n in 1 .. wanted:
    if n in byNumber:
      if byNumber[n].ended: result.add Action(kind: akDelete, n: n, name: byNumber[n].name)
    elif now - tried.getOrDefault(n, -retrySeconds * 2) >= retrySeconds:
      tried[n] = now
      result.add Action(kind: akCreate, n: n, name: conductorPodName(n))
  for n, p in byNumber:
    if n > wanted and p.ended: result.add Action(kind: akDelete, n: n, name: p.name)

func conductorLabels(n: int): JsonNode =
  %*{"app.kubernetes.io/name": conductorLabel, "cinim.io/conductor": "cond-" & $n}

func conductorSecretBody*(spec: ConductorSpec; n: int; credential: string): JsonNode =
  %*{"apiVersion": "v1", "kind": "Secret", "metadata": {"name": conductorPodName(n), "labels": conductorLabels(n)}, "type": "Opaque",
     "stringData": {"credential": credential}}

func conductorPodBody*(spec: ConductorSpec; n: int): JsonNode =
  ## The Pod of one conductor: the `restricted` Pod Security class, a read-only file system, no capabilities, no token of the cluster. It has no rights in the cluster and
  ## reaches nothing but the core's push channel (the network policy of the namespace). Its credential comes from its own Secret, never as a value in the specification.
  let memoryMi = 256 + 64 * max(spec.runsPerConductor, 1)      # the supervisor and the run processes (docs/conductors.md section 8: about 700-800 MiB for ten)
  %*{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": conductorPodName(n), "labels": conductorLabels(n)},
     "spec": {
       "restartPolicy": "Never", "automountServiceAccountToken": false,
       "terminationGracePeriodSeconds": spec.drainSeconds + 15,
       "securityContext": {"runAsNonRoot": true, "runAsUser": 65532, "fsGroup": 65532, "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{
         "name": "conductor", "image": spec.image,
         "env": [
           {"name": "CINIM_CORE_STREAM_ADDR", "value": spec.streamAddr},
           {"name": "CINIM_NAMESPACE", "value": spec.namespace},
           {"name": "CINIM_CONDUCTOR_ID", "value": "cond-" & $n},
           {"name": "CINIM_CONDUCTOR_CREDENTIAL", "valueFrom": {"secretKeyRef": {"name": conductorPodName(n), "key": "credential"}}},
           {"name": "CINIM_CERTS", "value": "/etc/cinim"},
           {"name": "CINIM_RUNS_PER_CONDUCTOR", "value": $spec.runsPerConductor},
           {"name": "CINIM_DRAIN_SECONDS", "value": $spec.drainSeconds}],
         "volumeMounts": [{"name": "curve", "mountPath": "/etc/cinim/curve", "readOnly": true}],
         "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}},
         "resources": {"requests": {"cpu": "50m", "memory": "64Mi"}, "limits": {"memory": $memoryMi & "Mi"}}}],
       "volumes": [{"name": "curve", "secret": {"secretName": spec.curveSecret, "defaultMode": 288}}]}}     # 0440

proc reconcile*(be: Backend; spec: ConductorSpec; wanted: int; credentials: seq[(string, string)]; now: float;
                tried: var Table[int, float]): tuple[created, deleted: seq[string]] =
  ## One round: read the conductor Pods of the namespace, make what is missing, remove what has ended. A list that could not be read concludes nothing.
  if be.listConductors == nil or be.createConductor == nil or be.deleteConductor == nil: return
  let listed = be.listConductors()
  if not listed.ok: return
  var creds = initTable[string, string]()
  for (id, c) in credentials: creds[id] = c
  for a in planActions(wanted, listed.pods, now, tried):
    case a.kind
    of akDelete:
      if be.deleteConductor(a.name): result.deleted.add a.name
    of akCreate:
      let id = "cond-" & $a.n
      if id notin creds:
        tried.del a.n                      # the plan has none for it yet: try again as soon as it has
        continue
      let out0 = be.createConductor(a.name, $conductorSecretBody(spec, a.n, creds[id]), $conductorPodBody(spec, a.n))
      if out0.ok: result.created.add a.name
