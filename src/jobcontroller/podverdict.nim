## What a step Pod's state means for the step (D-28, RUN-002). Pure: takes the Pod JSON the Kubernetes API returned.
##
## The line that matters is "did the step's own code decide this?". A non-zero exit, a crash or an OOM kill is the step's
## result and is never retried automatically. Everything the platform or the cluster did to the Pod (eviction, node
## shutdown, the Pod vanishing) is an infrastructure loss, and those split in two (D-28): a Pod we *know* never started
## its command is safe to run again; one whose command started and whose fate is unknown is NOT restarted (a half-done
## deploy must not be started a second time by a machine). No heuristics beyond that: when in doubt, it is the second kind.
## A log that was not delivered is not a loss at all: the command's exit code is known and is the result.
import std/[json, strutils, options]

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

const
  exitLogsUndelivered* = 72
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

proc classifyPod*(pod: JsonNode; logTail = ""; seenStarted = true): PodReading =
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
    of "logs_undelivered":
      return if r.commandExitCode >= 0: PodReading(verdict: vLogsUndelivered, exitCode: r.commandExitCode, detail: "logs_undelivered")
             else: PodReading(verdict: vOutcomeUnknown, exitCode: -1, detail: "logs_undelivered_exit_code_unknown")
    else: return PodReading(verdict: vFailed, exitCode: (if r.commandExitCode > 0: r.commandExitCode else: r.exitCode),
                            detail: "shim_result_" & r.reason)
  let reason = pod{"status", "reason"}.getStr
  # A Pod that is being deleted (node drain, preemption, someone's `kubectl delete`) gets SIGTERM and usually exits 143:
  # that is the cluster's doing, not the step's own result - and the command had started, so it is not restarted.
  let deleted = pod{"metadata", "deletionTimestamp"}
  if deleted != nil and deleted.kind == JString and containerStarted(pod):
    return PodReading(verdict: vOutcomeUnknown, exitCode: -1, detail: "pod_deleted")
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
  if code == exitLogsUndelivered or msgReason == "logs_undelivered":
    # the exit code of the step's own command is the result; without it the fate of the step is unknown
    if cmdExit >= 0: PodReading(verdict: vLogsUndelivered, exitCode: cmdExit, detail: "logs_undelivered")
    else: PodReading(verdict: vOutcomeUnknown, exitCode: -1, detail: "logs_undelivered_exit_code_unknown")
  elif code == 0:
    PodReading(verdict: vSucceeded, exitCode: 0)
  else:
    PodReading(verdict: vFailed, exitCode: code, detail: term{"reason"}.getStr("Error"))      # detail "OOMKilled" when the memory limit did it
