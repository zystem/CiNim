# Known pitfalls of other CI systems and how this platform handles them

Status against the code: ✅ closed and covered by a test, 🟡 closed partly or only in the design, ❌ not closed.
Retry rule (D-28): a step is repeated automatically only when it is **known** that its command never started.
If the start is visible in the log or another source and the status is unclear, the step is not restarted.

## Loss of the executor and retries

| Pitfall | Seen in | Here |
|---|---|---|
| The Pod is gone (404), the step is "running" for ever | Jenkins Kubernetes plugin, Drone | ✅ a 404 gives a verdict (unit test); end to end |
| A retry of a step that may have partly run (a deploy) | Argo, GitLab `retry`, Jenkins | ✅ a visible start with an unclear status is not restarted, the reason `outcome_unknown` is in the API; end to end |
| A retry storm on a systemic problem | Jenkins | ✅ `infra_retries` (3), the pause grows up to 60 s, only "never started" is repeated |
| A retry after an OOM is pointless | Argo | ✅ OOM is the step's own failure |
| A Pod is deleted (drain, preemption) and exit 143 is taken for a step failure | Argo, Tekton | ✅ `deletionTimestamp` means loss; the shim catches SIGTERM, passes it to the whole tree, finishes the log, reason `terminated` |
| An agent lost its link, the server cancelled the build, late data is rejected, a returned agent is ignored | Jenkins, TeamCity, GitHub Actions | ✅ the shim survives the loss of the core and reconnects (end to end: the core is stopped for the duration of a step, the result and the log arrive after it returns); silence is not loss until `liveness_timeout` (5 min, configurable) has passed, after which the core finishes the step and removes the Pod; late logs of an old attempt are accepted into its own stream |
| A "ghost" build keeps writing into another build | TeamCity | ✅ the stream key and the `job` label contain the attempt number, the status of a stale attempt is ignored |
| Orphaned Pods after a controller restart | Jenkins | ✅ the controller keeps its Pods in sqlite and continues with them after a restart; `ci-*` Pods in the dedicated namespace that it does not know are removed after a grace period; the core sends `CancelStep` for Pods it no longer needs (unit tests on a fake cluster, end to end) |
| A Pod hangs in `Pending` (ErrImagePull, unschedulable) | every Kubernetes system | ✅ `liveness_timeout`: a Pod with no sign of life is removed, reason `start_timeout`, no retry (end to end) |
| A failed step does not fail the pipeline, or a failed build is reported as green | Jenkins (`catchError`, `sh returnStatus`), GitLab `allow_failure` | ✅ a non-zero exit code fails the job and so the run; only `ignore_failure = true` returns the code to the script (unit test `tpipeline`). This was found wrong in the first end-to-end self-build: a failed build step left the run `SUCCEEDED` |
| A reader sees the end of a step before its last log lines (the step "failed", the log is cut) | GitLab, Buildkite | 🟡 the shim ends the step only after the log has been delivered and acknowledged (checked end to end: the events `logs_delivered` and then `done`), but VictoriaLogs makes a record readable 0.4-1.5 s later (measured, five runs); the log API's `complete` says whether the shim's count of lines is stored, so a client asks again until it is |
| Blank lines come back as an error text, or lines come in the wrong order | observed here | ✅ the log window is sorted by line number and a blank line is returned blank (unit test `tlogwindow`); VictoriaLogs stores an empty message as the text `missing _msg field...` |
| A step hangs without output | TeamCity, Jenkins | ✅ `timeout` in Lua, the shim ends the process tree (TERM, then KILL), reason `timeout`, code 124 (end to end). A silent shim is caught by `liveness_timeout` |
| Finished Pods are cleaned before the result is read | Tekton | ✅ a finished Pod is kept after the result is recorded (10 min after success, 6 h after failure) and removed only then |
| The result is taken from the Pod status only | Tekton, Argo | ✅ the shim sends the result and waits for `may_exit`; the Pod status and log are the fallback (end to end) |
| The termination message is limited to 4 KiB | Tekton | ✅ ours is short; the Pod-log events are compact |

## Logs

| Pitfall | Seen in | Here |
|---|---|---|
| Lines are lost when the store fails | Buildkite, GitLab | ✅ a spool on the Pod, acknowledgement after vlagent's 2xx, back-pressure, end to end without losses |
| Duplicates and numbering on a repeated send | GitLab, Buildkite | ✅ `ln`, `acked_seq`, idempotence by `first_ln` |
| Invalid UTF-8 breaks the write | Woodpecker | ✅ invalid bytes become U+FFFD, a long line is cut between characters, a character on a read boundary waits for its second half |
| An endless line without `\n` | many | ✅ split at 32 KiB, a bound on accumulation |
| Secrets in logs | all | ✅ values are masked in the shim before the spool and the core, the build's output does not reach the Pod's log at all; base64 forms (all alignments), URL, JSON; `$CICD_MASK` for values found at run time (docs/secrets-masking.md). ❌ splits across lines and other encodings |
| The spool disk is full or unavailable | observed in testing | ✅ the shim does not fail: blocks are dropped and counted (`dropped` in the state and in the Pod log), the step ends with its own result |
| An undelivered block is lost together with the Pod | Jenkins, GitLab (attach) | ✅ before a running Pod is removed the controller pulls the spool out over exec in chunks with checksums and hands it to the core; the client's exec is costly (~17 s per call) and loses frames on a fast stream, so the shim writes frames with a pause |
| The whole log is in the server's memory | Drone | ✅ the core is a proxy and stores nothing |
| A step's log has no size limit | GitLab (`output_limit`) | ✅ `log_max_bytes` per step (1 GiB by default, configurable), one truncation marker (end to end) |
| A log sidecar is killed too early | Prow | ✅ there is no sidecar: the shim is the parent of the command and holds the Pod until delivery |
| Logs are not delivered: what to do with the step | observed in testing | ✅ the command's result is kept, the step is not repeated, `termination = logs_undelivered`, the log is marked incomplete |

## State of the components

| Pitfall | Seen in | Here |
|---|---|---|
| A node or agent is "online" but does not work | Concourse (stalled workers), Jenkins | ✅ the component registry is wired: heartbeats of the controller, the executor and the shim, probes of rqlite and the gate; `/api/v1/components`, `/metrics` |
| VictoriaLogs/vlagent die unnoticed | — | ✅ `/health` of the nodes and vlagent, the launch gate, hysteresis; a failed write to vlagent closes the gate at once (an in-band signal from the proxy) |
| Silence is taken for failure | TeamCity | ✅ silence marks a component `down` after 30 s (visible in `/metrics`), a step is considered lost only after `liveness_timeout` |

## What remains

- Secrets: a value split by a line break and other encodings (hex, gzip+base64) are not masked; a value that is neither among the step's secrets nor in `$CICD_MASK` cannot be masked.
- Every exec call in the Kubernetes client costs about 17 s: pulling out a large spool takes minutes, so the controller is limited to a total of 120 s. An alternative (an own exec client or a separate adapter process) is needed only if the need is real.
- Adoption of a "revived" step after `liveness_timeout` is not done: the core has already finished it and removed the Pod (by design).
- UI: there are no warnings in the interface because there is no UI yet (stage M4); the profile settings are available through the API.
