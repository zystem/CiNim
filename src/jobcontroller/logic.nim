## The job-controller's decisions (D-29), independent of Kubernetes and of the wire protocol: they work through a `Backend`
## (backend.nim) and the sqlite `CtrlState` (ctrlstate.nim), and speak plain Nim types, so the tests drive them with a fake
## cluster. What lives here: creating Pods (state first, then the Pod), the poll round (read each tracked Pod, classify it, read
## the shim's state from its log), cancelling Pods core no longer wants, keeping finished Pods for a while and then removing them,
## and sweeping orphans out of the (dedicated) step namespace.
import std/[json, options, strutils, tables, times, sequtils]
import ../common/shimstate
import backend, ctrlstate, podverdict

type
  TKind* = enum
    tkSucceeded, tkFailed, tkLost

  Transition* = object
    ## a Pod's story is over; becomes a PodTransition on the wire
    runId*, podName*, reason*, shimJson*, podReason*, podMessage*, podDiag*: string
    seq*, attempt*, exitCode*: int
    kind*: TKind
    fullyRead*: bool             ## the shim's verdict was read and the log reached the log pipeline: the Pod has nothing left to show

  PodSeen* = object
    ## a tracked Pod that is still going; becomes a PodInfo on the wire
    runId*, podName*, phase*, node*, shimJson*, podReason*, podMessage*: string    ## podReason/podMessage: why it has not started
    seq*, attempt*: int
    started*: bool

  StartRequest* = object
    runId*, image*, optsJson*, profile*: string       ## profile: "" = ordinary, "build" = an image build (D-42)
    seq*, attempt*: int
    command*: seq[string]
    logMaxBytes*, logSpoolBytes*: uint64
    logHoldTimeout*: int                 ## per-step values from the profile; 0 = the controller's own defaults
    secretNames*: seq[string]            ## the secrets the step asked for (core/stepsecrets.nim)
    stepToken*: string                   ## the step's credential for fetching them from core
    env*: seq[(string, string)]          ## the run's launch parameters as plain environment variables (VAR-002)
    volume*: string                      ## "" = the run's volume; else the id of the job that has a volume of its own (`workspace = "isolated"`, STO-002)

  Config* = object
    collectorAddr*, stepReportAddr*: string   ## where the shim in the Pod reaches core; both empty = no log streaming
    artifactAddr*: string                     ## the core's ArtifactIngest (DAT-003); empty = the Pod gets no address and a step with artifacts fails
    logSpoolBytes*, logHoldTimeout*: int
    retentionRead*: int                       ## seconds a finished Pod is kept when its result and its log are both read (0: removed at once)
    retentionUnread*: int                     ## seconds it is kept when they are not (log not delivered, end unknown): 14 days
    orphanGrace*: int                         ## a Pod not in our state is an orphan only after this many seconds
    logEvery*: int                            ## seconds between reads of a running Pod's log

func defaultConfig*(): Config =
  Config(logSpoolBytes: 10 * 1024 * 1024, logHoldTimeout: 600, retentionUnread: 14 * 86400, orphanGrace: 120,
         logEvery: 5)

func podName*(runId: string; seq, attempt: int): string =
  ## run_id is shard-prefixed ("s1_<uuid7>") - the underscore is not valid in a Kubernetes RFC 1123 name, so it becomes '-'
  ## (run_id is otherwise lowercase hex/dashes, so this stays injective). Must equal the shim's and core's podName.
  "ci-" & runId.replace("_", "-") & "-" & $seq & "-" & $attempt

func drainDir*(seq, attempt: int): string =
  ## Where a step keeps what a reader Pod may have to fetch after the step's own Pod has ended (docs/artifacts.md): the manifest of its artifacts, and under `spool/` its log
  ## spool. On the run's volume, so it outlives the Pod; the path is the same in the step's Pod and in the reader's.
  "/cicd/state/drain/" & $seq & "-" & $attempt

func buildRequest*(cfg: Config; r: StartRequest): PodRequest =
  let logging = cfg.collectorAddr.len > 0 and cfg.stepReportAddr.len > 0
  let spool = if r.logSpoolBytes > 0: int(r.logSpoolBytes) else: cfg.logSpoolBytes
  let hold = if r.logHoldTimeout > 0: r.logHoldTimeout else: cfg.logHoldTimeout
  var cmd = @["/cicd/shim/cicd-shim"]
  # STO-002: the step's own files (CICD_OUTPUT, CICD_MASK) are in /cicd/run, the run's workspace and the env file of STO-003 on the volume the steps of the run share
  cmd.add @["--run-dir", "/cicd/run", "--workspace", "/cicd/workspace", "--state-dir", "/cicd/state"]
  if logging:
    cmd.add @["--collector-addr", cfg.collectorAddr, "--core-addr", cfg.stepReportAddr, "--certs-dir", "/cicd/certs",
              "--run-id", r.runId, "--step-seq", $r.seq, "--step-attempt", $r.attempt,
              "--log-spool-dir", drainDir(r.seq, r.attempt) & "/spool", "--log-spool-bytes", $spool,
              "--log-hold-timeout", $hold]
  if cfg.artifactAddr.len > 0: cmd.add @["--artifact-addr", cfg.artifactAddr]
  cmd.add @["--manifest-dir", drainDir(r.seq, r.attempt)]       # on the volume: a drain Pod can deliver what the shim could not (D-53)
  if r.logMaxBytes > 0: cmd.add @["--log-max-bytes", $r.logMaxBytes]
  if r.optsJson.len > 0: cmd.add @["--opts-json", r.optsJson]          # validated by the Lua sandbox, holds no secret values
  # the values are fetched by the shim from core with the step's own credential; the Pod's specification holds the names (as placeholders) and the credential
  # the credential is given whenever the step needs one (secrets, artifacts); only secrets are fetched at the start by a flag of their own
  if r.stepToken.len > 0: cmd.add @["--step-token", r.stepToken]
  if r.secretNames.len > 0 and r.stepToken.len > 0: cmd.add "--fetch-secrets"
  cmd.add "--"
  cmd.add (if r.command.len > 0: r.command else: @["sh", "-c", "true"])
  PodRequest(name: podName(r.runId, r.seq, r.attempt), image: r.image, runId: r.runId, volume: r.volume, cmd: cmd, logging: logging,
             spoolBytes: spool, build: r.profile == "build", deploy: r.profile == "deploy", env: r.env, secrets: (if r.stepToken.len > 0: r.secretNames else: @[]))

proc startPod*(be: Backend; st: CtrlState; cfg: Config; r: StartRequest; now: int64): CreateOutcome =
  ## State first, Pod second: a controller that dies in between leaves a row for a Pod that may not exist (the poll finds
  ## out: 404 = never started), never a Pod without a row (that would be an orphan).
  let req = buildRequest(cfg, r)
  if be.ensureRunVolume != nil:
    # the claim of the run is made before its first Pod (and found again by every later one); a refusal (the namespace's quota of claims or of storage is used
    # up, or a claim the class cannot give) is told the way a refused Pod is, and nothing is tracked for a Pod that will not exist
    let vol = be.ensureRunVolume(r.runId, r.volume)
    if vol.kind != ckOk: return vol
  st.track(req.name, r.runId, r.seq, r.attempt, now)
  result = be.createPod(req)
  if result.kind in [ckQuota, ckRejected]:
    st.forget(req.name)         # no Pod exists and none will: the caller tells core what the API server said, and nothing is left to find 404

proc releaseRunVolumes*(be: Backend; runIds: seq[string]): seq[string] =
  ## STO-006: core says these runs' storage may go; the ones whose claim is gone afterwards are returned, and core is told in the next poll
  if be.releaseRunVolume == nil: return
  for id in runIds:
    if be.releaseRunVolume(id): result.add id

proc shimStateOf*(tail: string): string =
  ## the newest shim state in a Pod-log tail, as the JSON core's recordShimState expects ("" = none found)
  let s = lastState(tail)
  if s.isSome: $toJson(s.get, 0) else: ""

proc pollRound*(be: Backend; st: CtrlState; cfg: Config; now: float): tuple[transitions: seq[Transition], inventory: seq[PodSeen]] =
  ## Read every Pod whose end core has not been told. A Pod still going is listed in the inventory (core uses the list to find
  ## Pods it no longer wants); one whose story is over becomes a Transition.
  for p in st.active():
    let pod = be.readPod(p.name)
    var started = p.started
    if pod != nil and pod.kind == JObject and pod{"kind"}.getStr != "Status" and containerStarted(pod) and not started:
      started = true
      st.markStarted(p.name)
    let reading = classifyPod(pod, seenStarted = started)
    # the Pod's log is the second route by which core learns what the shim is doing (the first is ZeroMQ): read every few
    # seconds while the step runs, and once more when the Pod's story is over; core reconciles both by event number
    var shimJson = ""
    if started and (reading.verdict != vRunning or now - p.lastLog >= cfg.logEvery.float):
      st.setLastLog(p.name, now)
      shimJson = shimStateOf(be.readLogTail(p.name))
    if reading.verdict == vRunning:
      result.inventory.add PodSeen(runId: p.runId, seq: p.seq, attempt: p.attempt, podName: p.name, started: started,
        phase: (if pod != nil: pod{"status", "phase"}.getStr("Unknown") else: "Unknown"),
        node: (if pod != nil: pod{"spec", "nodeName"}.getStr else: ""), shimJson: shimJson,
        podReason: pendingWhy(pod).reason, podMessage: pendingWhy(pod).message)
    else:
      result.transitions.add Transition(runId: p.runId, seq: p.seq, attempt: p.attempt, podName: p.name, shimJson: shimJson,
        kind: (case reading.verdict
               of vSucceeded: tkSucceeded
               of vFailed, vLogsUndelivered: (if reading.exitCode == 0: tkSucceeded else: tkFailed)
               else: tkLost),
        exitCode: reading.exitCode,
        fullyRead: reading.verdict in [vSucceeded, vFailed],
        # the kernel killed the container for exceeding its memory limit (the whole cgroup goes, shim included, so no shim verdict
        # exists): still the step's own failure, and the reason says so
        podReason: reading.podReason, podMessage: reading.podMessage,
        # everything the cluster says about the Pod while it still says it: the events are gone in about an hour
        podDiag: podDiag(pod, (if be.readEvents != nil: be.readEvents(p.name) else: @[])),
        reason: (if reading.verdict == vFailed and reading.detail == "OOMKilled": "oom_killed"
                 elif reading.verdict == vLogsUndelivered and reading.detail == "artifacts_undelivered": "artifacts_undelivered"
                 elif reading.verdict == vFailed and reading.detail == "ephemeral_storage_exceeded": "ephemeral_storage_exceeded"
                 else: reasonOf(reading.verdict)))

proc afterPoll*(st: CtrlState; transitions: seq[Transition]; now: int64) =
  ## core acknowledged these ends: from now on the Pods are only kept for a while, not watched
  for t in transitions: st.markReported(t.podName, t.kind == tkSucceeded, t.fullyRead, now, t.reason, t.podReason, t.podMessage)

proc cancelPod*(be: Backend; st: CtrlState; runId: string; seq, attempt, graceSeconds: int) =
  ## core does not want this Pod any more (a cancelled step, a later attempt exists, the step is finished, or it is an orphan). The Pod is deleted with a grace period, and in
  ## it the shim stops the build (SIGTERM to its process group, SIGKILL after 20 s), delivers the log and leaves; the spool of the log is on the run's volume, so what it could not
  ## deliver is not lost with the Pod (D-53, D-55). Nothing is pulled out of the Pod from outside.
  let name = podName(runId, seq, attempt)
  if be.deletePod(name, graceSeconds): st.forget(name)

type SweepResult* = object
  expired*, orphans*: seq[string]

proc sweep*(be: Backend; st: CtrlState; cfg: Config; now: int64): SweepResult =
  ## Finished Pods are removed once their retention has passed; Pods in the step namespace that this controller has no record
  ## of (a namespace dedicated to it is a requirement, see docs/settings.md) are orphans and are removed after a grace period.
  for p in st.reported():
    # a Pod whose result core has and whose log was delivered has nothing left to show (the log is in the log store): it goes at once. One that core
    # could not read (the log was not delivered, the end is unknown) is kept long, success or not, to be looked at, and core shows an alert for it
    let keep = if p.fullyRead: cfg.retentionRead else: cfg.retentionUnread
    if now - p.reportedAt >= keep.int64 and be.deletePod(p.name, 0):
      st.forget(p.name)
      result.expired.add p.name
  let listed = be.listPods()
  if not listed.ok: return
  var present = initTable[string, bool]()
  for pod in listed.pods:
    present[pod.name] = true
    if pod.name.startsWith("ci-") and not st.has(pod.name) and now - pod.createdAt >= cfg.orphanGrace.int64:
      if be.deletePod(pod.name, 0): result.orphans.add pod.name
  for p in st.reported():                       # a finished Pod that is already gone: nothing left to keep
    if p.name notin present: st.forget(p.name)
