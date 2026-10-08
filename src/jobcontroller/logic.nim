## The job-controller's decisions (D-29), independent of Kubernetes and of the wire protocol: they work through a `Backend`
## (backend.nim) and the sqlite `CtrlState` (ctrlstate.nim), and speak plain Nim types, so the tests drive them with a fake
## cluster. What lives here: creating Pods (state first, then the Pod), the poll round (read each tracked Pod, classify it, read
## the shim's state from its log), cancelling Pods core no longer wants, keeping finished Pods for a while and then removing them,
## and sweeping orphans out of the (dedicated) step namespace.
import std/[json, options, strutils, tables, times, sequtils]
import ../common/[shimstate, spoolwire, envname]
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
    secretHandles*: seq[string]          ## `NAME:version` of the secrets the step asked for (core/stepsecrets.nim)

  Config* = object
    collectorAddr*, stepReportAddr*: string   ## where the shim in the Pod reaches core; both empty = no log streaming
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

func buildRequest*(cfg: Config; r: StartRequest): PodRequest =
  let logging = cfg.collectorAddr.len > 0 and cfg.stepReportAddr.len > 0
  let spool = if r.logSpoolBytes > 0: int(r.logSpoolBytes) else: cfg.logSpoolBytes
  let hold = if r.logHoldTimeout > 0: r.logHoldTimeout else: cfg.logHoldTimeout
  var cmd = @["/cicd/shim/cicd-shim", "--run-dir", "/cicd/workspace/.run"]
  if logging:
    cmd.add @["--collector-addr", cfg.collectorAddr, "--core-addr", cfg.stepReportAddr, "--certs-dir", "/cicd/certs",
              "--run-id", r.runId, "--step-seq", $r.seq, "--step-attempt", $r.attempt,
              "--log-spool-dir", "/cicd/spool", "--log-spool-bytes", $spool,
              "--log-hold-timeout", $hold]
  if r.logMaxBytes > 0: cmd.add @["--log-max-bytes", $r.logMaxBytes]
  if r.optsJson.len > 0: cmd.add @["--opts-json", r.optsJson]          # validated by the Lua sandbox, holds no secret values
  var secrets: seq[tuple[name, objectName: string]]
  for h in r.secretHandles:
    let colon = h.rfind(':')
    if colon <= 0: continue
    let v = try: parseInt(h[colon + 1 .. ^1]) except ValueError: continue
    secrets.add (h[0 ..< colon], stepSecretObjectName(h[0 ..< colon], v))
  # the shim reads the values from its own environment, to mask them in the log; only the names are on the command line
  if secrets.len > 0: cmd.add @["--secret-env", secrets.mapIt(it.name).join(",")]
  cmd.add "--"
  cmd.add (if r.command.len > 0: r.command else: @["sh", "-c", "true"])
  PodRequest(name: podName(r.runId, r.seq, r.attempt), image: r.image, runId: r.runId, cmd: cmd, logging: logging,
             spoolBytes: spool, build: r.profile == "build", secrets: secrets)

proc startPod*(be: Backend; st: CtrlState; cfg: Config; r: StartRequest; now: int64): CreateOutcome =
  ## State first, Pod second: a controller that dies in between leaves a row for a Pod that may not exist (the poll finds
  ## out: 404 = never started), never a Pod without a row (that would be an orphan).
  let req = buildRequest(cfg, r)
  st.track(req.name, r.runId, r.seq, r.attempt, now)
  result = be.createPod(req)
  if result.kind in [ckQuota, ckRejected]:
    st.forget(req.name)         # no Pod exists and none will: the caller tells core what the API server said, and nothing is left to find 404

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
                 elif reading.verdict == vFailed and reading.detail == "ephemeral_storage_exceeded": "ephemeral_storage_exceeded"
                 else: reasonOf(reading.verdict)))

proc afterPoll*(st: CtrlState; transitions: seq[Transition]; now: int64) =
  ## core acknowledged these ends: from now on the Pods are only kept for a while, not watched
  for t in transitions: st.markReported(t.podName, t.kind == tkSucceeded, t.fullyRead, now, t.reason, t.podReason, t.podMessage)

const
  shimExe = "/cicd/shim/cicd-shim"
  spoolDir = "/cicd/spool"

proc drainSpool*(be: Backend; name: string; afterSeq: uint64 = 0; maxCalls = 60; deadlineSeconds = 120.0): seq[Frame] =
  ## Read the undelivered blocks out of a running Pod's spool through exec (the fallback for a shim that cannot reach core).
  ## The C client's exec drops data when a producer streams fast, so the shim paces its output and this asks for small pieces:
  ## each call yields whole, checksummed blocks; a damaged call is repeated with a smaller budget (never an error), and a block
  ## out of order stops the run (the next attempt starts from the last good one). Returns the blocks in sequence order.
  var last = afterSeq                           # the spool does not start at 1: blocks the shim already delivered are gone from it
  var haveAny = false
  var budget = 400_000
  var failures = 0
  let until = epochTime() + deadlineSeconds     # an exec call costs ~17 s of the C client's own overhead: do not stall the controller for ever
  for _ in 0 ..< maxCalls:
    if epochTime() > until: return
    let r = be.execInPod(name, "step", shimExe & " --read-spool " & spoolDir & " --after-seq " & $last & " --max-bytes " & $budget)
    if not r.ok: return
    let p = parseFrames(r.output)
    var took = 0
    for f in p.frames:
      if haveAny and f.seq != last + 1: return    # a gap or a repeat inside what we read: do not guess
      if f.seq <= last: return                    # older than what we asked for: not ours to trust
      result.add f
      last = f.seq
      haveAny = true
      inc took
    if took == 0:
      if not p.damaged: return                    # empty and not damaged: nothing (more) in the spool
      inc failures
      if failures >= 4: return
      budget = max(20_000, budget div 2)          # lost data in the stream: ask for less at a time
    elif not p.damaged and p.consumed + 64 * 1024 < budget:
      return          # the answer stopped well short of the budget: that was all of it (every exec costs ~17 s of the client's own overhead)

proc ackSpool*(be: Backend; name: string; upto: uint64): bool =
  be.execInPod(name, "step", shimExe & " --ack-spool " & spoolDir & " --upto " & $upto).ok

type Deliver* = proc (runId: string; seq, attempt: int; frames: seq[Frame]): uint64
  ## hands blocks to core's LogIngest; returns the highest sequence core acknowledged (0 = none)

proc cancelPod*(be: Backend; st: CtrlState; runId: string; seq, attempt, graceSeconds: int; rescue: Deliver = nil): int =
  ## core does not want this Pod any more (a later attempt exists, the step is finished, or it is an orphan). Before a Pod that
  ## is still running is removed, whatever its shim could not deliver is pulled out of its spool and given to core (log lines
  ## are not lost with a dead shim). Returns how many blocks were rescued.
  let name = podName(runId, seq, attempt)
  if rescue != nil:
    let frames = drainSpool(be, name)
    if frames.len > 0:
      let acked = rescue(runId, seq, attempt, frames)
      if acked > 0:
        result = frames.len
        discard ackSpool(be, name, acked)
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
