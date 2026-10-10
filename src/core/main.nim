## Core shard process (D-23): scheduler (run creation, the push channel of the controllers and conductors), the log
## collector (LogIngest, StepReport, RUN-007/DAT-001) and the REST API (including the log-window read) in one process - spec 7.3's component table puts all of this in one shard
## process; the log-circuit module (loggate.nim polls the VictoriaLogs nodes and vlagent, RUN-015's launch gate)
## runs as another thread, and a watchdog thread enforces liveness_timeout and probes rqlite and the log circuit (D-29).
## One shard, one execution profile, no directory.
import std/[times, os, strutils, posix, atomics, uri]
import common/[rqlite, ctrlauth]
import apiauth, schema, scheduler, triggers, artifactingest, api, logcollector, logcircuit, loggate, routerclient, orgrules, streamhub

if paramCount() >= 1 and paramStr(1) == "admin-token-reset":
  # `kubectl -n <ns> exec deploy/cinim-core -- /core admin-token-reset`: a lost administrator token is made again (IAM-003, core/apiauth.nim); the new
  # one has to be changed at first use, the other tokens stay
  var rc = newRq(getEnv("CINIM_RQLITE_URL", "http://127.0.0.1:4001"))
  echo bootstrapAdminToken(rc, getTime().toUnix(), force = true)
  quit 0

if paramCount() >= 3 and paramStr(1) == "conductor-credential":
  # `/core conductor-credential <namespace> <conductor id>`: what a conductor of that organisation proves itself with (IAM-003). The controller will
  # hand it to the conductors it makes (docs/conductors.md phase 3); a conductor started by hand is given it this way.
  echo conductorCredential(coreSecretKey(getEnv("CINIM_CERTS", getCurrentDir() / "tests" / "certs")), paramStr(2), paramStr(3))
  quit 0

let
  rqliteUrl = getEnv("CINIM_RQLITE_URL", "http://127.0.0.1:4001")
  namespace = getEnv("CINIM_NAMESPACE", "cinim")
  certs = getEnv("CINIM_CERTS", getCurrentDir() / "tests" / "certs")
  apiPort = parseInt(getEnv("CINIM_API_PORT", "18081"))
  stepReportPort = parseInt(getEnv("CINIM_STEPREPORT_PORT", "19742"))
  logIngestPort = parseInt(getEnv("CINIM_LOGINGEST_PORT", "19743"))
  artifactPort = parseInt(getEnv("CINIM_ARTIFACTINGEST_PORT", "19744"))
  streamPort = parseInt(getEnv("CINIM_STREAM_PORT", "19745"))   ## the push channel of the controllers (docs/conductors.md section 12)
  vlagentUrl = getEnv("CINIM_VLAGENT_URL", "http://127.0.0.1:19429/insert/jsonline")
  # one VictoriaLogs node URL, or several separated by commas, in the same order as vlagent's remoteWrite list
  # (vlagent labels its per-destination queues by that position); reads still go to the first node
  victoriaLogsUrls = getEnv("CINIM_VICTORIALOGS_URL", "http://127.0.0.1:19428").split(',')
  victoriaLogsUrl = victoriaLogsUrls[0]
  # RUN-015 launch gate. "off" exists only for test setups that run no log circuit at all (the open question Q-16
  # - an emergency bypass in production - is the owner's call and is not decided here); it is announced loudly.
  launchGateOff = getEnv("CINIM_LAUNCH_GATE", "on") == "off"
  # SHD-006: the router of the `multi` mode. Without CINIM_ROUTER_URL there is no router (the `single` mode).
  shardName = getEnv("CINIM_SHARD", "001")
  routerUrl = getEnv("CINIM_ROUTER_URL").strip(chars = {'/', ' '})
  routerKey = getEnv("CINIM_ROUTER_KEY")
  publicUrl = getEnv("CINIM_PUBLIC_URL").strip(chars = {'/', ' '})   ## https://<domain><basePath>: the URL of an organisation is <publicUrl>/<slug>/
  routerInterval = parseInt(getEnv("CINIM_ROUTER_INTERVAL", "60"))

type
  Args = tuple[co: Core, port: int]
  StepReportArgs = tuple[rqliteUrl, certs: string, port: int, profileId: string]

proc runStream(a: Args) {.thread.} = serveStream(a.co, a.port)
proc runLogIngest(a: tuple[co: Collector, certs: string, port: int]) {.thread.} =
  serveLogIngest(a.co, a.certs, a.port)
proc runStepReport(a: StepReportArgs) {.thread.} = serveStepReport(a.rqliteUrl, a.certs, a.port, a.profileId)
proc runWatchdog(a: tuple[rqliteUrl, profileId: string, startedAt: int64]) {.thread.} =
  ## every few seconds: steps whose Pod never came up or whose shim went quiet (liveness_timeout, D-29)
  {.cast(gcsafe).}:
    var c = newRq(a.rqliteUrl)
    while not stopServers.load:
      try:
        probeAndAge(c, a.startedAt)
        watchdogPass(c, a.profileId, a.startedAt)
      except CatchableError as e: stderr.writeLine "core: watchdog: " & e.msg
      for _ in 0 ..< 50:
        if stopServers.load: break
        sleep 100
proc runArtifactIngest(a: tuple[rqliteUrl, certs: string, port: int]) {.thread.} = serveArtifactIngest(a.rqliteUrl, a.certs, a.port)
proc runLogGate(a: tuple[w: Watch, stop: ptr Atomic[bool]]) {.thread.} = serveLogGate(a.w, a.stop)

proc runRouterClient(a: tuple[rqliteUrl: string]) {.thread.} =
  {.cast(gcsafe).}:
    let url = a.rqliteUrl
    proc readOrgs(): seq[OwnOrg] {.gcsafe.} =
      {.cast(gcsafe).}:
        var c = newRq(url)
        for o in c.listOrganizationRows():
          if o.state == "active": result.add OwnOrg(slug: o.slug, name: o.name)
    serveRouterClient(readOrgs, addr stopServers)

proc main() =
  setStdIoUnbuffered()           # a supervisor that kills the process must still find its log complete
  var c = newRq(rqliteUrl)
  var profileId: string
  try:
    migrate(c)
    profileId = seedDefaultProfile(c, namespace)
  except CatchableError as e:
    # in a cluster this happens while rqlite is still starting: say what failed, exit, and let Kubernetes start the core again
    stderr.writeLine "core: cannot use the database at " & rqliteUrl & " (CINIM_RQLITE_URL): " & e.msg
    quit 1
  for f in ["core.pub", "core.key"]:
    if not fileExists(certs / "curve" / f):
      stderr.writeLine "core: the transport key " & (certs / "curve" / f) & " is missing (CINIM_CERTS; in a cluster the Secret named by curve.secretName)"
      quit 2
  let co = Core(rqliteUrl: rqliteUrl, profileId: profileId, namespace: namespace, certs: certs,
                orgPrefix: getEnv("CINIM_NAMESPACE_PREFIX", "cinim"), orgShard: shardName, buildOn: getEnv("CINIM_BUILD", "off") == "on", deployOn: getEnv("CINIM_DEPLOY", "off") == "on",
                victoriaLogsUrl: victoriaLogsUrl)
  echo "core: profile=", profileId, " namespace=", namespace

  let agent = parseUri(vlagentUrl)
  let watch = Watch(nodes: victoriaLogsUrls, agentUrl: agent.scheme & "://" & agent.hostname & (if agent.port.len > 0: ":" & agent.port else: ""),
                    cfg: defaultConfig(), disabled: launchGateOff)
  initGate(watch)
  if not validShardName(shardName):
    stderr.writeLine "core: CINIM_SHARD must be made of digits only (SHD-001), got '" & shardName & "'"
    quit 2
  configure(RouterConfig(url: routerUrl, key: routerKey, coreId: getEnv("CINIM_CORE_ID", shardName), publicBase: publicUrl,
                         intervalSec: routerInterval))
  var routerThread: Thread[tuple[rqliteUrl: string]]
  if routerUrl.len > 0:
    let unsupported = urlSupported(routerUrl)
    if unsupported.len > 0 or routerKey.len == 0:
      stderr.writeLine "core: router: " & (if unsupported.len > 0: unsupported else: "CINIM_ROUTER_KEY is required")
      quit 2
    if publicUrl.len == 0: echo "core: WARNING - CINIM_PUBLIC_URL is not set: organisations are registered without a URL"
    createThread(routerThread, runRouterClient, (rqliteUrl,))
    echo "core: registering with the router ", routerUrl, " as ", getEnv("CINIM_CORE_ID", shardName), " every ", routerInterval, " s"
  if launchGateOff: echo "core: WARNING - launch gate DISABLED (CINIM_LAUNCH_GATE=off): steps start whatever the log circuit does"
  var gateThread: Thread[tuple[w: Watch, stop: ptr Atomic[bool]]]
  if not launchGateOff:
    createThread(gateThread, runLogGate, (watch, addr stopServers))
  startReconciler(co)      # SHD-008: the organisations against their objects, and the retention of a switched-off one
  var stepReportThread: Thread[StepReportArgs]
  var logIngestThread: Thread[tuple[co: Collector, certs: string, port: int]]
  var streamThread: Thread[Args]
  createThread(streamThread, runStream, (co, streamPort))
  createThread(logIngestThread, runLogIngest,
    (Collector(rqliteUrl: rqliteUrl, vlagentUrl: vlagentUrl), certs, logIngestPort))
  createThread(stepReportThread, runStepReport, (rqliteUrl, certs, stepReportPort, profileId))
  var artifactThread: Thread[tuple[rqliteUrl, certs: string, port: int]]
  createThread(artifactThread, runArtifactIngest, (rqliteUrl, certs, artifactPort))
  var triggerThread: Thread[tuple[co: Core, stop: ptr Atomic[bool]]]
  createThread(triggerThread, runTriggerLoop, (co, addr stopServers))
  var watchdogThread: Thread[tuple[rqliteUrl, profileId: string, startedAt: int64]]
  createThread(watchdogThread, runWatchdog, (rqliteUrl, profileId, getTime().toUnix()))
  echo "core: LogIngest on ", logIngestPort, ", ArtifactIngest on ", artifactPort, ", the push channel on ", streamPort, ", StepReport on ", stepReportPort, ", API on ", apiPort
  serveApi(co, apiPort)   # returns immediately: GuildenStern runs its own thread pool (D-25)
  # GuildenStern installs its own SIGTERM/SIGINT handler that only stops *its* threads, and the loop that
  # used to sit here (`while true: sleep`) never noticed - so the process ignored SIGTERM and a supervisor
  # (systemd, kubectl delete) had to wait out its kill timeout. Take the signals over once the server is up:
  # set the flag every REP-server thread already polls (they wake at least every 200 ms) and leave.
  proc onSignal(sig: cint) {.noconv.} = stopServers.store(true)
  signal(SIGTERM, onSignal)
  signal(SIGINT, onSignal)
  while not stopServers.load: sleep(100)
  echo "core: stopping"
  joinThread(stepReportThread)
  joinThread(logIngestThread)
  joinThread(watchdogThread)
  joinThread(triggerThread)
  joinThread(artifactThread)
  joinVault()
  if not launchGateOff: joinThread(gateThread)
  if routerUrl.len > 0: joinThread(routerThread)
  joinReconciler()

main()
