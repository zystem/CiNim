## Core shard process (D-23): scheduler (run creation, ControllerAttach, ExecutorChannel), the log
## collector (LogIngest, StepReport, RUN-007/DAT-001) and the REST API (including the log-window read) in one process - spec 7.3's component table puts all of this in one shard
## process; the log-circuit module (loggate.nim polls the VictoriaLogs nodes and vlagent, RUN-015's launch gate)
## runs as another thread, and a watchdog thread enforces liveness_timeout and probes rqlite and the log circuit (D-29).
## One shard, one execution profile, no directory.
import std/[times, os, strutils, posix, atomics, uri]
import common/rqlite
import schema, scheduler, api, logcollector, logcircuit, loggate

let
  rqliteUrl = getEnv("CINIM_RQLITE_URL", "http://127.0.0.1:4001")
  namespace = getEnv("CINIM_NAMESPACE", "cinim")
  certs = getEnv("CINIM_CERTS", getCurrentDir() / "tests" / "certs")
  controllerPort = parseInt(getEnv("CINIM_CONTROLLER_PORT", "19740"))
  executorPort = parseInt(getEnv("CINIM_EXECUTOR_PORT", "19741"))
  apiPort = parseInt(getEnv("CINIM_API_PORT", "18081"))
  stepReportPort = parseInt(getEnv("CINIM_STEPREPORT_PORT", "19742"))
  logIngestPort = parseInt(getEnv("CINIM_LOGINGEST_PORT", "19743"))
  vlagentUrl = getEnv("CINIM_VLAGENT_URL", "http://127.0.0.1:19429/insert/jsonline")
  # one VictoriaLogs node URL, or several separated by commas, in the same order as vlagent's remoteWrite list
  # (vlagent labels its per-destination queues by that position); reads still go to the first node
  victoriaLogsUrls = getEnv("CINIM_VICTORIALOGS_URL", "http://127.0.0.1:19428").split(',')
  victoriaLogsUrl = victoriaLogsUrls[0]
  # RUN-015 launch gate. "off" exists only for test setups that run no log circuit at all (the open question Q-16
  # - an emergency bypass in production - is the owner's call and is not decided here); it is announced loudly.
  launchGateOff = getEnv("CINIM_LAUNCH_GATE", "on") == "off"

type
  Args = tuple[co: Core, port: int]
  StepReportArgs = tuple[rqliteUrl, certs: string, port: int, profileId: string]

proc runControllerAttach(a: Args) {.thread.} = serveControllerAttach(a.co, a.port)
proc runExecutorChannel(a: Args) {.thread.} = serveExecutorChannel(a.co, a.port)
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
proc runLogGate(a: tuple[w: Watch, stop: ptr Atomic[bool]]) {.thread.} = serveLogGate(a.w, a.stop)

proc main() =
  setStdIoUnbuffered()           # a supervisor that kills the process must still find its log complete
  var c = newRq(rqliteUrl)
  migrate(c)
  let profileId = seedDefaultProfile(c, namespace)
  let co = Core(rqliteUrl: rqliteUrl, profileId: profileId, namespace: namespace, certs: certs,
                victoriaLogsUrl: victoriaLogsUrl)
  echo "core: profile=", profileId, " namespace=", namespace

  let agent = parseUri(vlagentUrl)
  let watch = Watch(nodes: victoriaLogsUrls, agentUrl: agent.scheme & "://" & agent.hostname & (if agent.port.len > 0: ":" & agent.port else: ""),
                    cfg: defaultConfig(), disabled: launchGateOff)
  initGate(watch)
  if launchGateOff: echo "core: WARNING - launch gate DISABLED (CINIM_LAUNCH_GATE=off): steps start whatever the log circuit does"
  var gateThread: Thread[tuple[w: Watch, stop: ptr Atomic[bool]]]
  if not launchGateOff:
    createThread(gateThread, runLogGate, (watch, addr stopServers))
  var controllerThread, executorThread: Thread[Args]
  var stepReportThread: Thread[StepReportArgs]
  var logIngestThread: Thread[tuple[co: Collector, certs: string, port: int]]
  createThread(controllerThread, runControllerAttach, (co, controllerPort))
  createThread(executorThread, runExecutorChannel, (co, executorPort))
  createThread(logIngestThread, runLogIngest,
    (Collector(rqliteUrl: rqliteUrl, vlagentUrl: vlagentUrl), certs, logIngestPort))
  createThread(stepReportThread, runStepReport, (rqliteUrl, certs, stepReportPort, profileId))
  var watchdogThread: Thread[tuple[rqliteUrl, profileId: string, startedAt: int64]]
  createThread(watchdogThread, runWatchdog, (rqliteUrl, profileId, getTime().toUnix()))
  echo "core: ControllerAttach on ", controllerPort, ", ExecutorChannel on ", executorPort,
       ", LogIngest on ", logIngestPort, ", StepReport on ", stepReportPort, ", API on ", apiPort
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
  joinThread(controllerThread)
  joinThread(executorThread)
  joinThread(stepReportThread)
  joinThread(logIngestThread)
  joinThread(watchdogThread)
  if not launchGateOff: joinThread(gateThread)

main()
