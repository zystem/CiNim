## What a step Pod's state means for the step (D-28, RUN-002). Pure: takes the Pod JSON the Kubernetes API returned.
##
## The line that matters is "did the step's own code decide this?". A non-zero exit, a crash or an OOM kill is the step's
## result and is never retried automatically. Everything the platform or the cluster did to the Pod (eviction, node
## shutdown, the Pod vanishing) is an infrastructure loss, and those split in two (D-28): a Pod we *know* never started
## its command is safe to run again; one whose command started and whose fate is unknown is NOT restarted (a half-done
## deploy must not be started a second time by a machine). No heuristics beyond that: when in doubt, it is the second kind.
## A log that was not delivered is not a loss at all: the command's exit code is known and is the result.
import std/[json, strutils, options, sequtils]

type
  Verdict* = enum
    vRunning            ## nothing final to report (also: an API hiccup - never conclude anything from a failed read)
    vSucceeded
    vFailed             ## the command ran and decided: non-zero exit, crash, OOM kill
    vLogsUndelivered    ## the command finished (exitCode = its result), its log did not reach vlagent within log_hold_timeout
    vLostNeverStarted   ## infrastructure ended the Pod before the command started
    vOutcomeUnknown     ## infrastructure ended the Pod (or it vanished) and the command may have run

  PodReading* = object
    verdict*: Verdict
    exitCode*: int
    detail*: string
    podReason*, podMessage*: string   ## what Kubernetes says about the end (kept in the database for investigations), cut to `maxMessage`

const
  exitLogsUndelivered* = 72
  exitArtifactsUndelivered* = 76   ## the command succeeded; its artifacts are still on the Pod (the core could not take them): the Pod is kept, as for a log that was not delivered
  maxMessage* = 1000
  ownLimitMarks* = ["exceeds the total limit of containers", "exceeded its local ephemeral storage limit", "exceeds the limit of"]
    ## the kubelet's words for a Pod evicted because it used more ephemeral storage than its own limit; node pressure
    ## reads "The node was low on resource: ephemeral-storage" and is not the step's doing
  infraReasons* = ["Evicted", "NodeShutdown", "Shutdown", "Terminated", "NodeAffinity", "UnexpectedAdmissionError", "Preempting"]

func reasonOf*(v: Verdict): string =
  ## the wire value of PodTransition.termination_reason
  case v
  of vRunning: ""
  of vSucceeded: "ok"
  of vFailed: "failed"
  of vLogsUndelivered: "logs_undelivered"
  of vLostNeverStarted: "lost_never_started"
  of vOutcomeUnknown: "outcome_unknown"

const shimResultMarker* = "CICD-SHIM-RESULT "
const shimStartMarker* = "CICD-SHIM-START "

type ShimResult* = object
  ## What the shim itself printed as the very last line of the Pod's log (D-29): its own conclusion, in a second
  ## place besides the termination message and the Pod's status - a log tail is cheap to read and survives cases where
  ## the container status is missing or incomplete.
  reason*: string          ## ok | failed | env_rejected | secret_in_output | logs_undelivered | shim_error
  exitCode*: int           ## the shim's own exit code
  commandExitCode*: int    ## the step command's exit code
  attempt*: int

proc parseShimResult*(logTail: string): Option[ShimResult] =
  ## The last RESULT line in the tail wins (a step's own output can mimic the marker, but only the shim writes it last).
  var found = false
  var line = ""
  for l in logTail.splitLines:
    if l.startsWith(shimResultMarker):
      line = l
      found = true
  if not found: return none(ShimResult)
  try:
    let j = parseJson(line[shimResultMarker.len .. ^1])
    if j.kind != JObject or not j.hasKey("reason"): return none(ShimResult)
    some ShimResult(reason: j["reason"].getStr, exitCode: j{"exit_code"}.getInt(-1),
                    commandExitCode: j{"command_exit_code"}.getInt(-1), attempt: j{"attempt"}.getInt(0))
  except JsonParsingError:
    none(ShimResult)

proc containerStarted*(pod: JsonNode): bool =
  ## the container is running or has run (the shim, and with it the command, is started within milliseconds of that)
  let css = pod{"status", "containerStatuses"}
  if css == nil or css.kind != JArray or css.len == 0: return false
  let st = css[0]{"state"}
  if st == nil: return false
  if st{"running"} != nil: return true
  let started = st{"terminated", "startedAt"}
  started != nil and started.kind == JString and started.getStr.len > 0 and not started.getStr.startsWith("0001-")

func ownLimitEviction*(reason, message: string): bool =
  ## An eviction the step brought on itself (it went over a limit of its own Pod) is the step's failure, like an OOM kill; one the node
  ## brought on (pressure on the node, a drain) is the platform's, and the step may have been innocent.
  reason == "Evicted" and ownLimitMarks.anyIt(it in message)

func podStatusOf*(pod: JsonNode): tuple[reason, message: string] =
  ## the Pod's status.reason and message; with no reason on the Pod, the reason of the container's end ("OOMKilled")
  if pod == nil or pod.kind != JObject: return
  result.reason = pod{"status", "reason"}.getStr
  result.message = pod{"status", "message"}.getStr
  if result.reason.len == 0:
    let css = pod{"status", "containerStatuses"}
    if css != nil and css.kind == JArray and css.len > 0:
      let t = css[0]{"state", "terminated"}
      if t != nil and t.kind == JObject and t{"exitCode"}.getInt(0) != 0: result.reason = t{"reason"}.getStr
  if result.message.len > maxMessage: result.message = result.message[0 ..< maxMessage]

proc classifyPodVerdict(pod: JsonNode; logTail = ""; seenStarted = true): PodReading =
  ## `seenStarted`: see classifyPod
  ## `seenStarted`: the caller's own evidence that the container got as far as running (it observed it running, or heard
  ## from the shim). It only matters when the Pod has vanished (404): with no sign of a start the loss is the safe kind.
  if pod == nil or pod.kind != JObject: return PodReading(verdict: vRunning)
  if pod{"kind"}.getStr == "Status":
    # a real "no such Pod" is the only thing a failed read may be taken for; timeouts and 5xx are not
    if pod{"code"}.getInt == 404 or pod{"reason"}.getStr == "NotFound":
      return PodReading(verdict: (if seenStarted: vOutcomeUnknown else: vLostNeverStarted), exitCode: -1,
                        detail: "pod_missing")
    return PodReading(verdict: vRunning)
  let phase = pod{"status", "phase"}.getStr
  if phase notin ["Succeeded", "Failed"]: return PodReading(verdict: vRunning)
  # The shim's own last line says what it concluded - the most precise account there is, so it decides when present.
  # (Its absence proves nothing: the container may have been killed before it could write it.)
  let shim = parseShimResult(logTail)
  if shim.isSome:
    let r = shim.get
    case r.reason
    of "ok": return PodReading(verdict: vSucceeded, exitCode: r.commandExitCode, detail: "shim_result_ok")
    of "logs_undelivered", "artifacts_undelivered":
      return if r.commandExitCode >= 0: PodReading(verdict: vLogsUndelivered, exitCode: r.commandExitCode, detail: r.reason)
             else: PodReading(verdict: vOutcomeUnknown, exitCode: -1, detail: r.reason & "_exit_code_unknown")
    else: return PodReading(verdict: vFailed, exitCode: (if r.commandExitCode > 0: r.commandExitCode else: r.exitCode),
                            detail: "shim_result_" & r.reason)
  let reason = pod{"status", "reason"}.getStr
  # A Pod that is being deleted (node drain, preemption, someone's `kubectl delete`) gets SIGTERM and usually exits 143:
  # that is the cluster's doing, not the step's own result - and the command had started, so it is not restarted.
  let deleted = pod{"metadata", "deletionTimestamp"}
  if deleted != nil and deleted.kind == JString and containerStarted(pod):
    return PodReading(verdict: vOutcomeUnknown, exitCode: -1, detail: "pod_deleted")
  if phase == "Failed" and ownLimitEviction(reason, pod{"status", "message"}.getStr):
    # evicted for using more ephemeral storage than its own limit: the step's failure (no retry), not the cluster's
    var code = 137
    let css0 = pod{"status", "containerStatuses"}
    if css0 != nil and css0.kind == JArray and css0.len > 0:
      let c = css0[0]{"state", "terminated", "exitCode"}.getInt(0)
      if c > 0: code = c
    return PodReading(verdict: vFailed, exitCode: code, detail: "ephemeral_storage_exceeded")
  if phase == "Failed" and reason in infraReasons:
    return PodReading(verdict: (if containerStarted(pod): vOutcomeUnknown else: vLostNeverStarted), exitCode: -1,
                      detail: "pod_" & reason)
  let css = pod{"status", "containerStatuses"}
  var term: JsonNode = nil
  if css != nil and css.kind == JArray and css.len > 0: term = css[0]{"state", "terminated"}
  if term == nil:
    return PodReading(verdict: vOutcomeUnknown, exitCode: -1, detail: "no_container_status")
  let code = term{"exitCode"}.getInt(-1)
  var msgReason = ""
  var cmdExit = -1
  try:
    let m = parseJson(term{"message"}.getStr("{}"))
    msgReason = m{"reason"}.getStr
    cmdExit = m{"command_exit_code"}.getInt(-1)
  except JsonParsingError: discard
  if msgReason == "terminated":
    # the shim was asked to stop from outside (SIGTERM: drain, preemption, deletion): the command was cut off part-way
    return PodReading(verdict: vOutcomeUnknown, exitCode: -1, detail: "terminated_by_signal")
  if code == exitLogsUndelivered or code == exitArtifactsUndelivered or msgReason in ["logs_undelivered", "artifacts_undelivered"]:
    # the exit code of the step's own command is the result; without it the fate of the step is unknown
    let what = if code == exitArtifactsUndelivered or msgReason == "artifacts_undelivered": "artifacts_undelivered" else: "logs_undelivered"
    if cmdExit >= 0: PodReading(verdict: vLogsUndelivered, exitCode: cmdExit, detail: what)
    else: PodReading(verdict: vOutcomeUnknown, exitCode: -1, detail: what & "_exit_code_unknown")
  elif code == 0:
    PodReading(verdict: vSucceeded, exitCode: 0)
  else:
    PodReading(verdict: vFailed, exitCode: code, detail: term{"reason"}.getStr("Error"))      # detail "OOMKilled" when the memory limit did it

proc classifyPod*(pod: JsonNode; logTail = ""; seenStarted = true): PodReading =
  ## `seenStarted`: the caller's own evidence that the container got as far as running (it only matters when the Pod has vanished).
  ## the verdict, with what Kubernetes said about the end added to it
  result = classifyPodVerdict(pod, logTail, seenStarted)
  if result.verdict != vRunning:
    let s = podStatusOf(pod)
    result.podReason = s.reason
    result.podMessage = s.message

proc clip(s: string; n: int): string = (if s.len > n: s[0 ..< n] else: s)

func pendingWhy*(pod: JsonNode): tuple[reason, message: string] =
  ## Why a Pod that has not started waits: the container's waiting reason (ImagePullBackOff, ErrImagePull, CreateContainerConfigError, ...), or,
  ## when no container exists yet, the PodScheduled=False condition (Unschedulable and the scheduler's words). "" when it runs or nothing is said.
  if pod == nil or pod.kind != JObject: return
  for key in ["initContainerStatuses", "containerStatuses"]:
    let css = pod{"status", key}
    if css == nil or css.kind != JArray: continue
    for cs in css:
      let w = cs{"state", "waiting"}
      if w != nil and w.kind == JObject and w{"reason"}.getStr notin ["", "ContainerCreating", "PodInitializing"]:
        return (w{"reason"}.getStr, clip(w{"message"}.getStr, maxMessage))
  let conds = pod{"status", "conditions"}
  if conds != nil and conds.kind == JArray:
    for c in conds:
      if c{"type"}.getStr == "PodScheduled" and c{"status"}.getStr == "False":
        return (c{"reason"}.getStr, clip(c{"message"}.getStr, maxMessage))

const maxDiag* = 6000

func podDiag*(pod: JsonNode; events: seq[JsonNode]): string =
  ## What an investigation of an incident wants and the cluster forgets: the state of every container (reason, exit code, signal, start and end,
  ## restarts, the image digest that was really pulled), the Pod's conditions (DisruptionTarget says that the cluster ended it, and why),
  ## the node, the QoS class, the resources as they were admitted (after the LimitRange) and the events about the Pod. JSON, at most `maxDiag` bytes;
  ## the events are cut first.
  if pod == nil or pod.kind != JObject: return ""
  var containers = newJArray()
  for key in ["initContainerStatuses", "containerStatuses"]:
    let css = pod{"status", key}
    if css == nil or css.kind != JArray: continue
    for cs in css:
      var c = %*{"name": cs{"name"}.getStr, "init": key == "initContainerStatuses", "restarts": cs{"restartCount"}.getInt,
                 "image_id": cs{"imageID"}.getStr}
      for (field, node) in [("state", cs{"state"}), ("last_state", cs{"lastState"})]:
        if node == nil or node.kind != JObject: continue
        let t = node{"terminated"}
        let w = node{"waiting"}
        if t != nil and t.kind == JObject:
          c[field] = %*{"terminated": {"reason": t{"reason"}.getStr, "exit_code": t{"exitCode"}.getInt(-1), "signal": t{"signal"}.getInt(0),
                                       "started_at": t{"startedAt"}.getStr, "finished_at": t{"finishedAt"}.getStr}}
        elif w != nil and w.kind == JObject:
          c[field] = %*{"waiting": {"reason": w{"reason"}.getStr, "message": clip(w{"message"}.getStr, 300)}}
        elif node{"running"} != nil:
          c[field] = %*{"running": {"started_at": node{"running", "startedAt"}.getStr}}
      containers.add c
  var conditions = newJArray()
  let conds = pod{"status", "conditions"}
  if conds != nil and conds.kind == JArray:
    for c in conds:
      # the ones that say something: a condition that is false, and the disruption target (true) with its reason
      if c{"status"}.getStr == "False" or c{"type"}.getStr == "DisruptionTarget":
        conditions.add %*{"type": c{"type"}.getStr, "status": c{"status"}.getStr, "reason": c{"reason"}.getStr,
                          "message": clip(c{"message"}.getStr, 300)}
  var resources = newJArray()
  let specC = pod{"spec", "containers"}
  if specC != nil and specC.kind == JArray:
    for c in specC: resources.add %*{"name": c{"name"}.getStr, "resources": (if c{"resources"} != nil: c{"resources"} else: newJObject())}
  var d = %*{"node": pod{"spec", "nodeName"}.getStr, "qos": pod{"status", "qosClass"}.getStr, "phase": pod{"status", "phase"}.getStr,
             "start_time": pod{"status", "startTime"}.getStr, "containers": containers, "conditions": conditions, "resources": resources}
  var evs = newJArray()
  for e in events:
    if evs.len >= 20: break
    evs.add %*{"type": e{"type"}.getStr, "reason": e{"reason"}.getStr, "message": clip(e{"message"}.getStr, 300), "count": e{"count"}.getInt(1),
               "last": e{"lastTimestamp"}.getStr}
  d["events"] = evs
  result = $d
  while result.len > maxDiag and evs.len > 0:        # events are the first thing to give up, then the resources
    evs.elems.setLen(evs.len div 2)
    result = $d
  if result.len > maxDiag:
    d.delete("resources")
    result = $d
