## D-27: what a Pod's state means for its step, and when a lost step is run again (pure, no cluster).
import std/[unittest, json, options, strutils]
import jobcontroller/[podverdict, backend]
import core/retrypolicy

proc pod(phase: string; reason = ""; state: JsonNode = nil): JsonNode =
  result = %*{"status": {"phase": phase}}
  if reason.len > 0: result["status"]["reason"] = %reason
  if state != nil: result["status"]["containerStatuses"] = %*[{"state": state}]

proc terminated(code: int; startedAt = "2026-10-02T10:00:00Z"; message = ""; reason = "Error"): JsonNode =
  %*{"terminated": {"exitCode": code, "startedAt": startedAt, "reason": reason, "message": message}}

suite "Pod -> step verdict":
  test "still running or pending: nothing to report":
    check classifyPod(pod("Running", state = %*{"running": {}})).verdict == vRunning
    check classifyPod(pod("Pending")).verdict == vRunning
  test "a failed or missing API read is never taken for a result":
    check classifyPod(nil).verdict == vRunning
    check classifyPod(%*{"kind": "Status", "code": 500, "reason": "InternalError"}).verdict == vRunning
    check classifyPod(%*{"kind": "Status", "code": 403, "reason": "Forbidden"}).verdict == vRunning
  test "exit 0 is success, a non-zero exit is the step's own failure":
    check classifyPod(pod("Succeeded", state = terminated(0))).verdict == vSucceeded
    let f = classifyPod(pod("Failed", state = terminated(2)))
    check f.verdict == vFailed and f.exitCode == 2
  test "an OOM kill is the step's own failure, not infrastructure (it would just be killed again)":
    check classifyPod(pod("Failed", state = terminated(137, reason = "OOMKilled"))).verdict == vFailed
  test "logs not delivered: the command's own exit code is the result":
    let msg = $(%*{"exit_code": 72, "reason": "logs_undelivered", "command_exit_code": 3})
    let r = classifyPod(pod("Failed", state = terminated(72, message = msg)))
    check r.verdict == vLogsUndelivered and r.exitCode == 3
    check classifyPod(pod("Failed", state = terminated(1, message = msg))).verdict == vLogsUndelivered
  test "logs not delivered and no command exit code anywhere: the fate is unknown, so it is not restarted either":
    check classifyPod(pod("Failed", state = terminated(72))).verdict == vOutcomeUnknown
  test "the Pod vanished (404): it may have run - unless nothing ever showed that its container started":
    let gone = %*{"kind": "Status", "code": 404, "reason": "NotFound"}
    let r = classifyPod(gone)
    check r.verdict == vOutcomeUnknown and r.detail == "pod_missing"
    check classifyPod(gone, seenStarted = true).verdict == vOutcomeUnknown
    check classifyPod(gone, seenStarted = false).verdict == vLostNeverStarted
  test "a Pod being deleted (drain, preemption) after its command started is a loss, not the step's own failure":
    var p = pod("Failed", state = terminated(143))
    p["metadata"] = %*{"deletionTimestamp": "2026-10-02T10:01:00Z"}
    check classifyPod(p).verdict == vOutcomeUnknown and classifyPod(p).detail == "pod_deleted"
    check classifyPod(pod("Failed", state = terminated(143))).verdict == vFailed      # a plain 143 stays the step's own
  test "the shim stopped by a signal from outside is outcome_unknown; its own timeout is the step's failure":
    let term = $(%*{"exit_code": 143, "reason": "terminated", "command_exit_code": 143})
    check classifyPod(pod("Failed", state = terminated(143, message = term))).verdict == vOutcomeUnknown
    let tmo = $(%*{"exit_code": 124, "reason": "timeout", "command_exit_code": 143})
    let r = classifyPod(pod("Failed", state = terminated(124, message = tmo)))
    check r.verdict == vFailed and r.exitCode == 124
  test "containerStarted: running or has run, not waiting":
    check containerStarted(pod("Running", state = %*{"running": {}}))
    check containerStarted(pod("Failed", state = terminated(1)))
    check not containerStarted(pod("Pending", state = %*{"waiting": {"reason": "ContainerCreating"}}))
    check not containerStarted(pod("Pending"))
  test "evicted before the command started is the safe kind of loss":
    check classifyPod(pod("Failed", reason = "Evicted")).verdict == vLostNeverStarted
    check classifyPod(pod("Failed", reason = "NodeAffinity")).verdict == vLostNeverStarted
    check classifyPod(pod("Failed", reason = "UnexpectedAdmissionError")).verdict == vLostNeverStarted
  test "evicted or shut down after the command started may have run":
    check classifyPod(pod("Failed", reason = "Evicted", state = terminated(137))).verdict == vOutcomeUnknown
    check classifyPod(pod("Failed", reason = "NodeShutdown", state = %*{"running": {}})).verdict == vOutcomeUnknown
  test "evicted for the Pod's own ephemeral-storage limit is the step's failure; node pressure is the platform's":
    let own = pod("Failed", reason = "Evicted", state = terminated(137))
    own["status"]["message"] = %"Pod ephemeral local storage usage exceeds the total limit of containers 1Gi. "
    let r = classifyPod(own)
    check r.verdict == vFailed and r.exitCode == 137 and r.detail == "ephemeral_storage_exceeded"
    let node = pod("Failed", reason = "Evicted", state = terminated(137))
    node["status"]["message"] = %"The node was low on resource: ephemeral-storage. Threshold quantity: 19127914436, available: 17489608Ki."
    check classifyPod(node).verdict == vOutcomeUnknown
  test "what Kubernetes says about the end is kept: status.reason and message, or the container's reason, cut to a size":
    let e = pod("Failed", reason = "Evicted", state = terminated(137))
    e["status"]["message"] = %("x".repeat(3000))
    let r = classifyPod(e)
    check r.podReason == "Evicted" and r.podMessage.len == maxMessage
    check classifyPod(pod("Failed", state = terminated(137, reason = "OOMKilled"))).podReason == "OOMKilled"
    check classifyPod(pod("Succeeded", state = terminated(0))).podReason == ""
  test "a terminated container whose startedAt is the zero time never started":
    check classifyPod(pod("Failed", reason = "Evicted", state = terminated(1, startedAt = "0001-01-01T00:00:00Z"))).verdict == vLostNeverStarted
  test "a finished Pod with no container status at all is unknown, so it may have run":
    check classifyPod(pod("Failed")).verdict == vOutcomeUnknown

suite "a Pod the API server refused":
  test "a used-up quota and a request to slow down wait; every other refusal is final":
    check classifyCreateFailure(403, "Forbidden", "pods \"x\" is forbidden: exceeded quota: q, requested: pods=1").kind == ckQuota
    check classifyCreateFailure(429, "TooManyRequests", "slow down").kind == ckQuota
    check classifyCreateFailure(403, "Forbidden", "violates PodSecurity \"restricted:latest\"").kind == ckRejected
    check classifyCreateFailure(403, "Forbidden", "must specify limits.cpu,limits.memory").kind == ckRejected
    check classifyCreateFailure(422, "Invalid", "spec.containers[0].image: Required value").kind == ckRejected
  test "the step whose Pod was refused ends as an infrastructure error at once, with no attempts repeated":
    check decide("pod_rejected", 1, defaultPolicy()) == dFailInfra

suite "when a lost step is run again":
  let p = defaultPolicy()
  test "the step's own result is final - and so is a result whose log was lost":
    check decide("ok", 1, p) == dFinish
    check decide("failed", 1, p) == dFinish
    check decide("logs_undelivered", 1, p) == dFinish
  test "a command that never started is retried up to infra_retries times":
    for a in 1 .. 3: check decide("lost_never_started", a, p) == dRequeue
    check decide("lost_never_started", 4, p) == dFailInfra
  test "a command that started and whose fate is unknown is never restarted, whatever the attempt or the limit":
    for a in 1 .. 5: check decide("outcome_unknown", a, p) == dFailInfra
    var many = p
    many.infraRetries = 20
    check decide("outcome_unknown", 1, many) == dFailInfra
  test "the retry limit is configurable, 0 means never":
    var none = p
    none.infraRetries = 0
    check decide("lost_never_started", 1, none) == dFailInfra
    var five = p
    five.infraRetries = 5
    check decide("lost_never_started", 5, five) == dRequeue
    check decide("lost_never_started", 6, five) == dFailInfra
  test "retries are spaced out and the pause is capped":
    check backoffSeconds(1, p) == 5
    check backoffSeconds(3, p) == 15
    check backoffSeconds(50, p) == 60
  test "every verdict maps to a distinct wire reason the policy understands":
    for v in [vSucceeded, vFailed, vLogsUndelivered, vLostNeverStarted, vOutcomeUnknown]:
      check reasonOf(v).len > 0
    check decide(reasonOf(vSucceeded), 1, p) == dFinish
