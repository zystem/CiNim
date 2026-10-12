## The drain of a step's leavings (DAT-003, D-27, D-53, docs/artifacts.md): the shim could not hand its artifacts or its log to the core (the core was not there), so they are on
## the run's volume - the manifest of the artifacts and the log spool, in `drainDir` - and the Pod of the step has ended. When the core orders it, the controller makes a Pod on
## that volume that runs `cicd-shim --drain`: the shim reads the manifest and the spool and sends them to the core with the step's credential, as the shim of the step would have,
## and takes off what the core has. The controller only makes the Pod and reads how it ended; it carries no data and uses no `exec` (the C client's exec returns nothing in
## the TESTING cluster, and costs ~17 s a call where it works). Plain data and a `Backend`, so it is tested without a cluster.
import std/[json, strutils]
import backend, logic, podverdict

const
  drainPrefix* = "cdrain-"
  drainContainer* = "drain"
  exitRetry* = 77            ## the shim's `--drain`: the core or the store did not answer in time
  exitFailed* = 78           ## ... it cannot be done

type
  DrainOrder* = object
    runId*: string
    seq*, attempt*: int
    image*, token*: string
    artifacts*, logs*: bool

  DrainState* = enum
    dsDone      ## everything asked is delivered; the Pod is removed
    dsMore      ## the Pod is being made, or is working: look again
    dsRetry     ## something that may pass (the core or the store does not answer): ask again later
    dsFailed    ## it cannot be done (the volume is gone, a file does not match its SHA-256, the store refuses for good): `detail` says which

  DrainOutcome* = object
    state*: DrainState
    detail*: string

  DrainAddrs* = object
    collectorAddr*, artifactAddr*: string      ## the core's LogIngest and ArtifactIngest as a Pod reaches them

func drainPodName*(runId: string; seq, attempt: int): string =
  drainPrefix & runId.replace("_", "-") & "-" & $seq & "-" & $attempt

func drainCommand*(o: DrainOrder; a: DrainAddrs; waitSeconds = 120): seq[string] =
  ## the shim's flags for this order: the paths are those of the step's own Pod (the volume is mounted the same way)
  let dir = drainDir(o.seq, o.attempt)
  result = @["/cicd/shim/cicd-shim", "--drain", "--run-id", o.runId, "--step-seq", $o.seq, "--step-attempt", $o.attempt,
            "--workspace", "/cicd/workspace", "--manifest-dir", dir, "--log-spool-dir", dir & "/spool", "--certs-dir", "/cicd/certs",
            "--step-token", o.token, "--wait", $waitSeconds]
  if a.collectorAddr.len > 0: result.add @["--collector-addr", a.collectorAddr]
  if a.artifactAddr.len > 0: result.add @["--artifact-addr", a.artifactAddr]
  if o.artifacts: result.add "--artifacts"
  if o.logs: result.add "--logs"

proc terminationOf(pod: JsonNode): tuple[code: int, reason, detail: string] =
  ## how the drain container ended, from its termination message (the shim writes it) or, failing that, its exit code
  result.code = -1
  let css = pod{"status", "containerStatuses"}
  if css == nil or css.kind != JArray or css.len == 0: return
  let t = css[0]{"state", "terminated"}
  if t == nil or t.kind != JObject: return
  result.code = t{"exitCode"}.getInt(-1)
  try:
    let m = parseJson(t{"message"}.getStr("{}"))
    result.reason = m{"reason"}.getStr
    result.detail = m{"detail"}.getStr
  except CatchableError: discard

proc drainStep*(be: Backend; o: DrainOrder; a: DrainAddrs): DrainOutcome =
  ## One look at the drain of this step: make its Pod when there is none, and, when the Pod has ended, say how it went and remove it.
  let pod = drainPodName(o.runId, o.seq, o.attempt)
  let seen = be.readPod(pod)
  if seen == nil or seen.kind != JObject: return DrainOutcome(state: dsRetry, detail: "the Pod could not be read")
  if seen{"kind"}.getStr == "Status":
    if seen{"code"}.getInt != 404 and seen{"reason"}.getStr != "NotFound": return DrainOutcome(state: dsRetry, detail: "the Pod could not be read")
    let made = be.createDrainPod(pod, o.runId, o.image, drainCommand(o, a))
    case made.kind
    of ckOk, ckTransport: return DrainOutcome(state: dsMore, detail: "the drain Pod is being made")
    of ckQuota: return DrainOutcome(state: dsRetry, detail: "no drain Pod for now: " & made.message)
    of ckRejected: return DrainOutcome(state: dsFailed, detail: "the drain Pod was refused: " & made.message)
  let phase = seen{"status", "phase"}.getStr
  case phase
  of "Succeeded":
    discard be.deletePod(pod, 0)
    return DrainOutcome(state: dsDone)
  of "Failed":
    let t = terminationOf(seen)
    discard be.deletePod(pod, 0)
    if t.code == exitFailed or t.reason == "failed":
      return DrainOutcome(state: dsFailed, detail: if t.detail.len > 0: t.detail else: "the drain failed")
    return DrainOutcome(state: dsRetry, detail: if t.detail.len > 0: t.detail else: "the drain Pod ended (exit code " & $t.code & ")")
  of "Running":
    return DrainOutcome(state: dsMore, detail: "the drain is under way")
  else:
    let why = pendingWhy(seen)
    # a run whose volume has been deleted: the Pod waits for a claim that is not there, for ever
    if "persistentvolumeclaim" in why.message.toLowerAscii and "not found" in why.message.toLowerAscii:
      discard be.deletePod(pod, 0)
      return DrainOutcome(state: dsFailed, detail: "the run's volume is gone")
    return DrainOutcome(state: dsMore, detail: "the drain Pod is not running yet" & (if why.reason.len > 0: " (" & why.reason & ")" else: ""))

proc sweepDrainPods*(be: Backend; now: int64; maxAgeSeconds = 2 * 3600): seq[string] =
  ## drain Pods that have outlived any drain (a controller that was stopped in the middle, an order that core no longer makes)
  let listed = be.listPods()
  if not listed.ok: return
  for p in listed.pods:
    if p.name.startsWith(drainPrefix) and now - p.createdAt >= maxAgeSeconds and be.deletePod(p.name, 0): result.add p.name
