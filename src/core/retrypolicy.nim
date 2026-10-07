## When a step that did not finish by its own code is run again (D-28, RUN-002). Pure.
## One simple rule, no heuristics: a step is repeated automatically only when it is *known* that its command never started.
##   - the step's own result (ok / failed) is final, never retried here;
##   - logs_undelivered: the command finished and its exit code is known; only the log is incomplete. The result stands
##     (the step is not run again - it could repeat a deploy that already succeeded), the log is marked incomplete;
##   - lost_never_started: the command provably did not run -> safe to run again;
##   - outcome_unknown: the command started and what happened to it is unknown (node lost, Pod vanished, evicted
##     mid-step) -> NOT restarted: the run ends as infrastructure_error with the reason `outcome_unknown` and a person
##     decides (a deploy that is half done must not be started a second time by a machine);
##   - start_timeout: the Pod did not come up within liveness_timeout (core killed it): a configuration or capacity problem
##     that another attempt would meet again, so it is not repeated either;
##   - every retry is bounded by `infra_retries` (default 3), spaced out with a growing pause so a node that keeps losing Pods
##     cannot be hammered (the retry storm Jenkins' Kubernetes plugin is known for).
type
  Decision* = enum
    dFinish             ## the step is done: record its own result
    dRequeue            ## back to the queue as the next attempt
    dFailInfra          ## give up: the run ends with infrastructure_error

  RetryPolicy* = object
    infraRetries*: int      ## default 3
    backoffBase*: int       ## seconds, default 5

const
  maxBackoff = 60

func defaultPolicy*(): RetryPolicy = RetryPolicy(infraRetries: 3, backoffBase: 5)

type
  ProfileSettings* = object
    ## what the UI edits for an execution profile (GET/PUT /api/v1/profile); every field has a default and a valid range
    infraRetries*: int        ## 0..20, default 3: how often a step that provably never started is run again
    logMaxBytes*: int64       ## 0 = unlimited, default 1 GiB: the most log one step may store; the rest is cut with a marker
    logSpoolBytes*: int64     ## 1 MiB..1 GiB, default 10 MiB: the log queue on the Pod's ephemeral storage; full = the build is slowed (backpressure)
    logHoldTimeout*: int      ## 10..86400 s, default 600: how long a finished step waits for its log to be delivered (and for core)
    livenessTimeout*: int     ## 30..3600 s, default 300: a Pod that has not started, or a shim that has not been heard from,
                              ## for this long is killed by core (one timeout for both, D-29)

const
  defaultLogMaxBytes* = 1'i64 shl 30
  defaultLivenessTimeout* = 300
  defaultLogSpoolBytes* = 10'i64 * 1024 * 1024
  defaultLogHoldTimeout* = 600

func defaultSettings*(): ProfileSettings =
  ProfileSettings(infraRetries: 3, logMaxBytes: defaultLogMaxBytes, livenessTimeout: defaultLivenessTimeout,
                  logSpoolBytes: defaultLogSpoolBytes, logHoldTimeout: defaultLogHoldTimeout)

func validate*(s: ProfileSettings): string =
  ## "" if valid, else what is wrong (the API answers 400 with it)
  if s.infraRetries notin 0 .. 20: "infra_retries must be 0..20"
  elif s.logMaxBytes < 0 or (s.logMaxBytes > 0 and s.logMaxBytes < 1024 * 1024): "log_max_bytes must be 0 (unlimited) or at least 1 MiB"
  elif s.logSpoolBytes notin 1'i64 shl 20 .. 1'i64 shl 30: "log_spool_bytes must be 1 MiB..1 GiB"
  elif s.logHoldTimeout notin 10 .. 86400: "log_hold_timeout must be 10..86400 seconds"
  elif s.livenessTimeout notin 30 .. 3600: "liveness_timeout must be 30..3600 seconds"
  else: ""

func decide*(reason: string; attempt: int; p: RetryPolicy): Decision =
  ## `attempt` is the attempt that just ended (1 = the first run).
  case reason
  of "lost_never_started":
    if attempt <= p.infraRetries: dRequeue else: dFailInfra
  of "outcome_unknown", "start_timeout", "pod_rejected":     # pod_rejected: the API server refused the Pod for good, asking again would get the same answer
    dFailInfra
  else:                     # ok, failed, logs_undelivered (the exit code is the result), ...
    dFinish

func backoffSeconds*(attempt: int; p: RetryPolicy): int =
  ## the pause before attempt+1 may start: linear in the attempt that just ended, capped
  min(p.backoffBase * attempt, maxBackoff)
