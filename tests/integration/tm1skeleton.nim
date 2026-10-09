## End to end on a real cluster: submit runs through the REST API and watch core, job-controller, executor-service and the shim
## in real step Pods do their work - through the real ZeroMQ+CURVE channels (D-24), the real rqlite shard, the real Lua
## sandbox, real VictoriaLogs and vlagent. Nothing is mocked. The pieces have their own tests (tests/unit: the Lua API, the journal,
## the shim, the controller logic on a fake cluster; tests/integration/tk8s*.nim, trqlite.nim: the Kubernetes and rqlite
## primitives); this is the suite that proves them wired together. What it covers:
##   - walking skeleton: a run with one ci.job + Job:sh step becomes a Pod and reaches SUCCEEDED; the Pod's log holds only the shim's
##     events, the build's output comes back through the platform's own log API, and rqlite agrees with the Pod log (D-29);
##   - D-27: the log pipeline, a closed gate when the log circuit is down (RUN-015), the shim holding a finished step until
##     the log is delivered, logs_undelivered, backpressure from a full spool;
##   - D-29: a Pod lost after / before its command started, core stopped while a step runs, a Pod that never comes up, a shim cut
##     off from core (its spool is pulled out through exec before the Pod is removed), timeout from Lua, masking through
##     $CICD_MASK, log_max_bytes, application and JVM metrics, an OOM kill.
##
## Core may run on another host that the step Pods can reach (CINIM_CORE_HOST; deploy/host has the systemd units); then the
## suite also drives it over ssh (stop/start) and gives the Pods its LogIngest/StepReport addresses. Without it, core runs as a
## local process and the Pod-side scenarios are skipped.
##
## Needs: CINIM_RQLITE_URL (a shard's rqlite), a reachable Kubernetes context, K8S_PREFIX to build the job-controller (the only
## binary that links the Kubernetes client), CINIM_VLAGENT_URL / CINIM_VICTORIALOGS_URL for the log scenarios, a libzmq.so with
## CURVE (libsodium) on the loader path at run time (the setup step generates the keys and fails loudly without CURVE), and
## CINIM_STATIC_SHIM (tools/shim/build_static.sh's output) so the shim runs in any step image. CINIM_KUBECONFIG pins the
## Kubernetes context: the official C client always follows the ambient kubeconfig's current-context, which can drift. Otherwise
## the suite is skipped, like trqlite.nim.
import std/[unittest, os, osproc, json, strutils, httpclient, strtabs, sequtils, times, uri]
import common/rqlite

let
  rqliteUrl = getEnv("CINIM_RQLITE_URL")
  k8sPrefix = getEnv("K8S_PREFIX")
  kubeconfig = getEnv("CINIM_KUBECONFIG")     # optional, see the module comment above
  kubectlBase = getEnv("CINIM_KUBECTL", "kubectl")
  ns = "cinim-test"
  certs = getCurrentDir() / "tests" / "certs"
  buildDir = getCurrentDir() / "build" / "tests" / "m1skeleton"
  # distinct from the ports a developer's own manual core/job-controller/executor-service (default 19740/
  # 19741/18081) might already be running on, and from the "cinim" namespace they might be using.
  # CINIM_CORE_HOST=<ip>: core already runs there (default ports, see src/core/main.nim) instead of being
  # spawned here. That is what lets the *step Pod's* shim reach the collector - Pods in the test cluster
  # may have no route to the developer machine but do have one to the TESTING host - so the log check
  # below runs on the real Pod's logs instead of a locally run shim.
  coreHost = getEnv("CINIM_CORE_HOST")
  remoteCore = coreHost.len > 0
  host = if remoteCore: coreHost else: "127.0.0.1"
  controllerPort = if remoteCore: 19740 else: 19760
  executorPort = if remoteCore: 19741 else: 19761
  stepReportPort = if remoteCore: 19742 else: 19762
  logIngestPort = if remoteCore: 19743 else: 19763
  apiPort = if remoteCore: 18081 else: 18091
  # optional: tools/dev/pf-vlagent.sh / pf-victorialogs.sh port-forwards
  vlagentUrl = getEnv("CINIM_VLAGENT_URL")
  victoriaLogsUrl = getEnv("CINIM_VICTORIALOGS_URL")
  staticShim = getEnv("CINIM_STATIC_SHIM")

let ready = rqliteUrl.len > 0 and k8sPrefix.len > 0
let logsReady = vlagentUrl.len > 0 and victoriaLogsUrl.len > 0

# ---------------------------------------------------------------- process management

proc svcEnv(extra: openArray[(string, string)]): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): result[k] = v     # inherit PATH, HOME, etc.
  for (k, v) in extra: result[k] = v

proc spawn(exe, log: string; env: StringTableRef): Process =
  ## redirected to a log file (not piped) so a long-lived service's stdout never blocks on a full pipe.
  ## "exec" matters: without it, dash forks a child to run the redirected command and this proc's
  ## Process tracks the dash wrapper's pid, not the service's - terminate()/kill() then hit a shell that
  ## has already exited (or ignores the signal) while the actual service survives, orphaned under init.
  startProcess("/bin/sh", args = @["-c", "exec " & quoteShell(exe) & " > " & quoteShell(log) & " 2>&1"], env = env)

var core, jobctl, execsvc: Process

proc stopAll() =
  for p in [core, jobctl, execsvc]:
    if p != nil:
      try:
        p.terminate()
        discard p.waitForExit(2000)
      except CatchableError: discard
      try:
        p.kill()                # unconditional belt-and-suspenders: SIGTERM is not always honoured
        discard p.waitForExit(2000)   # promptly (or at all - these are long-lived service loops), and
      except CatchableError: discard  # running() has been unreliable here; never leave a process behind
      p.close()

# ---------------------------------------------------------------- REST client helpers

proc waitApiUp(port: int; timeoutMs = 20000) =
  var waited = 0
  while waited < timeoutMs:
    let c = newHttpClient(timeout = 500)
    try:
      discard c.request("http://" & host & ":" & $port & "/api/v1/runs/warmup", HttpGet)
      c.close()
      return
    except CatchableError:
      c.close()
    sleep 200
    waited += 200
  doAssert false, "core's API on " & $port & " never came up"

proc postRun(port: int; projectId, script: string): JsonNode =
  let c = newHttpClient()
  defer: c.close()
  let body = $(%*{"project_id": projectId, "script": script})
  let resp = c.request("http://" & host & ":" & $port & "/api/v1/runs", HttpPost, body,
    headers = newHttpHeaders({"Content-Type": "application/json"}))
  doAssert resp.code == Http201, "POST /api/v1/runs: " & $resp.code & " " & resp.body
  parseJson(resp.body)

proc getRun(port: int; id: string): JsonNode =
  let c = newHttpClient()
  defer: c.close()
  let resp = c.request("http://" & host & ":" & $port & "/api/v1/runs/" & id, HttpGet)
  doAssert resp.code == Http200, "GET /api/v1/runs/" & id & ": " & $resp.code & " " & resp.body
  parseJson(resp.body)

proc waitTerminal(port: int; id: string; timeoutMs = 45000): JsonNode =
  var waited = 0
  while waited < timeoutMs:
    result = getRun(port, id)
    if result["state"].getStr in ["SUCCEEDED", "FAILED", "INFRASTRUCTURE_ERROR"]: return
    sleep 500
    waited += 500
  doAssert false, "run " & id & " never reached a terminal state, last seen: " & $result

proc launchGate(port: int): JsonNode =
  let c = newHttpClient(timeout = 3000)
  defer: c.close()
  try: parseJson(c.request("http://" & host & ":" & $port & "/api/v1/launch-gate", HttpGet).body)
  except CatchableError: %*{"open": false, "reason": "unreachable"}

proc waitGate(port: int; open: bool; timeoutMs: int): int =
  ## milliseconds until the gate reaches `open`, or -1
  var waited = 0
  while waited < timeoutMs:
    if launchGate(port){"open"}.getBool == open: return waited
    sleep 500
    waited += 500
  -1

proc makeStepRows(runId: string) =
  ## a run/job/step row so core can resolve the step of a log stream (what the executor would have created)
  var c = newRq(rqliteUrl)
  discard c.execute(%*[
    ["INSERT INTO runs (id, tenant_id, project_id, state, version, created_at, updated_at) " &
     "VALUES (?, 't1', 'p1', 'RUNNING', 1, '0', '0')", runId],
    ["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, 'k1', 'RUNNING', 'p1')", "job-" & runId, runId],
    ["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, queued_at) " &
     "VALUES (?, ?, ?, 0, 'sh', 'RUNNING', 'p1', 'x', 'x', '0')", "step-" & runId, runId, "job-" & runId]],
    transaction = true)

proc startShim(runId, spoolDir, termLog, command: string; spoolBytes, holdSeconds: int): Process =
  ## the real shim as a local subprocess, talking to the (remote) core exactly like a Pod's shim would
  removeFile(termLog)                       # leftovers of an earlier run must not pass for this run's result
  removeDir(spoolDir)
  startProcess(buildDir / "cicd-shim-logging", args = @["--run-dir", buildDir / ("run-" & runId), "--termination-log", termLog,
    "--collector-addr", "tcp://" & host & ":" & $logIngestPort, "--core-addr", "tcp://" & host & ":" & $stepReportPort,
    "--certs-dir", certs, "--run-id", runId, "--step-seq", "0", "--step-attempt", "1", "--log-spool-dir", spoolDir,
    "--log-spool-bytes", $spoolBytes, "--log-hold-timeout", $holdSeconds, "--", "sh", "-c", command],
    options = {poParentStreams})

proc storedLines(runId: string; filter = ""): int =
  ## how many lines of the run VictoriaLogs holds, asked directly (not through the platform). Goes through the API
  ## server's service proxy: a `kubectl port-forward` to the VictoriaLogs pod dies whenever that pod restarts, which
  ## is exactly what the failure scenarios below make it do.
  let url = "/api/v1/namespaces/victorialogs/services/victorialogs:http/proxy/select/logsql/query?query=" &
    encodeUrl("run:" & runId & (if filter.len > 0: " " & filter else: "") & " | stats count() c", usePlus = false)
  let (output, rc) = execCmdEx(kubectlBase & " get --raw " & quoteShell(url))
  if rc != 0: return 0
  for l in output.splitLines:
    if l.len > 0:
      try: return parseInt(parseJson(l){"c"}.getStr("0"))
      except CatchableError: discard
  0

proc dirBytes(dir: string): int =
  for f in walkFiles(dir / "*"): result += int(getFileSize(f))

proc scaleAgent(n: int) =
  discard execCmd(kubectlBase & " -n victorialogs scale statefulset vlagent --replicas=" & $n)

proc stepAttempt(runId: string): int =
  var c = newRq(rqliteUrl)
  let r = c.query(%*[["SELECT attempt FROM steps WHERE run_id = ? AND ordinal = 0", runId]])
  let v = r["results"][0]{"values"}
  if v != nil and v.len > 0: v[0][0].getInt else: 0

proc waitAttempt(runId: string; want, timeoutMs: int): bool =
  var waited = 0
  while waited < timeoutMs:
    if stepAttempt(runId) >= want: return true
    sleep 1000
    waited += 1000
  false

proc waitShimEvent(runId: string; n: int; timeoutMs: int): bool =
  ## the shim has told core (ZeroMQ) or the Pod log has (job-controller) that it got as far as event n
  var c = newRq(rqliteUrl)
  var waited = 0
  while waited < timeoutMs:
    let r = c.query(%*[["SELECT shim_n FROM steps WHERE run_id = ? AND ordinal = 0", runId]])
    let v = r["results"][0]{"values"}
    if v != nil and v.len > 0 and v[0][0].getInt >= n: return true
    sleep 500
    waited += 500
  false

proc waitPodPhase(name, phase: string; timeoutMs: int): bool =
  var waited = 0
  while waited < timeoutMs:
    let o = execProcess(kubectlBase & " -n " & ns & " get pod " & name & " -o jsonpath={.status.phase} 2>/dev/null").strip
    if o == phase: return true
    sleep 1000
    waited += 1000
  false

proc killPod(name: string) =
  ## the Pod disappears without a word - what a lost node or a manual delete looks like to the platform
  discard execCmd(kubectlBase & " -n " & ns & " delete pod " & name & " --grace-period=0 --force --wait=false >/dev/null 2>&1")

proc setProfile(infraRetries: int): JsonNode =
  let c = newHttpClient(timeout = 5000)
  defer: c.close()
  parseJson(c.request("http://" & host & ":" & $apiPort & "/api/v1/profile", HttpPut,
    $(%*{"infra_retries": infraRetries}),
    headers = newHttpHeaders({"Content-Type": "application/json"})).body)

proc putProfile(fields: JsonNode): JsonNode =
  let c = newHttpClient(timeout = 5000)
  defer: c.close()
  parseJson(c.request("http://" & host & ":" & $apiPort & "/api/v1/profile", HttpPut, $fields,
    headers = newHttpHeaders({"Content-Type": "application/json"})).body)

proc coreService(action: string) =
  ## the remote core is a systemd unit on the test host (deploy/host)
  discard execCmd("ssh -o ConnectTimeout=10 root@" & host & " systemctl " & action & " cinim-core")

proc stepLogLines(runId: string): seq[string] =
  let c2 = newHttpClient(timeout = 3000)
  defer: c2.close()
  try:
    let resp = c2.request("http://" & host & ":" & $apiPort & "/api/v1/runs/" & runId & "/steps/0/log", HttpGet)
    if resp.code == Http200: result = parseJson(resp.body)["lines"].mapIt(it.getStr)
  except CatchableError: discard

const sleepScript = """
  return ci.pipeline({name = "lost", main = function(run)
    local r
    ci.job({image = "busybox:1.36"}, function(j) r = j:sh("sleep 30; echo survived-the-loss") end)
    return "code=" .. tostring(r.code)
  end})"""

proc podName(runId: string; seq, attempt: int): string =
  ## must match src/jobcontroller/main.nim's podName(): "_" is not valid in a Kubernetes RFC 1123 name.
  "ci-" & runId.replace("_", "-") & "-" & $seq & "-" & $attempt

suite "walking skeleton end to end":
  if not ready:
    test "skipped: CINIM_RQLITE_URL/K8S_PREFIX not set":
      skip()
  else:
    test "setup: generate CURVE keypairs, flatten proto imports, build core/job-controller/executor-service/shim":
      check execCmd("tools/zmq/gen_curve_keys.sh") == 0
      check execCmd("tools/proto/nim_flatten.sh build/nimproto") == 0
      createDir(buildDir)
      check execCmd("nim c --hints:off --warnings:off -o:" & quoteShell(buildDir / "core") &
        " src/core/main.nim") == 0
      check execCmd("nim c --hints:off --warnings:off -d:k8sPrefix=" & quoteShell(k8sPrefix) &
        " -o:" & quoteShell(buildDir / "jobcontroller") & " src/jobcontroller/main.nim") == 0
      check execCmd("nim c --hints:off --warnings:off" &
        " -o:" & quoteShell(buildDir / "executorsvc") & " src/executorsvc/main.nim") == 0
      # two shims: the plain one (no ZeroMQ - what job-controller mounts into the step Pod, whose image
      # has no libzmq) and the -d:shimLogging one the local log-pipeline test below runs directly
      check execCmd("nim c --hints:off --warnings:off" &
        " -o:" & quoteShell(buildDir / "cicd-shim") & " src/shim/shim.nim") == 0
      # CINIM_STATIC_SHIM=<path to tools/shim/build_static.sh's output> swaps in the fully static musl shim
      # (libzmq+libsodium linked in, UPX-packed - runs in any step image, needs docker to build) for both
      # uses below; unset, the glibc -d:shimLogging build is used for the local log test as before.
      if staticShim.len > 0:
        check fileExists(staticShim)
        copyFileWithPermissions(staticShim, buildDir / "cicd-shim-logging")      # keeps the exec bit (a fresh build dir has no file to inherit it from)
      else:
        check execCmd("nim c --hints:off --warnings:off -d:shimLogging" &
          " -o:" & quoteShell(buildDir / "cicd-shim-logging") & " src/shim/shim.nim") == 0

    test "setup: test namespace exists":
      discard execCmd(kubectlBase & " create ns " & ns)   # ignore AlreadyExists

    test "setup: start core, job-controller and executor-service":
      if not remoteCore:
        var coreEnv = @[("CINIM_RQLITE_URL", rqliteUrl), ("CINIM_NAMESPACE", ns), ("CINIM_CERTS", certs),
          ("CINIM_CONTROLLER_PORT", $controllerPort), ("CINIM_EXECUTOR_PORT", $executorPort),
          ("CINIM_STEPREPORT_PORT", $stepReportPort), ("CINIM_LOGINGEST_PORT", $logIngestPort),
          ("CINIM_API_PORT", $apiPort), ("CINIM_LOG_HOLD_TIMEOUT", "20")]
        if logsReady: coreEnv.add [("CINIM_VLAGENT_URL", vlagentUrl), ("CINIM_VICTORIALOGS_URL", victoriaLogsUrl)]
        else: coreEnv.add ("CINIM_LAUNCH_GATE", "off")   # no log circuit in this setup: RUN-015 would (rightly) keep every step queued
        core = spawn(buildDir / "core", buildDir / "core.log", svcEnv(coreEnv))
      waitApiUp(apiPort)
      # job-controller and executor-service both read CINIM_CORE_ADDR, but for core's two different
      # REP listeners (ControllerAttach vs ExecutorChannel) - each needs its own value, not a shared one.
      var jcEnv = @[("CINIM_NAMESPACE", ns), ("CINIM_CERTS", certs),
        ("CINIM_CORE_ADDR", "tcp://" & host & ":" & $controllerPort),
        ("CINIM_SHIM_BIN", buildDir / (if staticShim.len > 0: "cicd-shim-logging" else: "cicd-shim")),
        ("CINIM_STATE_DIR", buildDir / "ctrl-state")]   # the controller's sqlite state stays under build/, not in the working directory
      # The addresses the Pod's shim dials and the other policy of the controller (the log wait: short, so that the logs_undelivered scenario below does not take 10 minutes)
      # are the core's to give (D-49); a remote core gives those of its Service in the cluster, which is what the Pods reach.
      if kubeconfig.len > 0: jcEnv.add ("CINIM_KUBECONFIG", kubeconfig)
      jobctl = spawn(buildDir / "jobcontroller", buildDir / "jobcontroller.log", svcEnv(jcEnv))
      execsvc = spawn(buildDir / "executorsvc", buildDir / "executorsvc.log", svcEnv({
        "CINIM_CERTS": certs, "CINIM_CORE_ADDR": "tcp://" & host & ":" & $executorPort}))
      sleep 1000   # let both clients complete their first ZeroMQ connect before the run is submitted
      # the log wait of a finished step is a profile setting (UI); short here, so the logs_undelivered scenarios do not take 10 minutes
      if remoteCore: check putProfile(%*{"log_hold_timeout": 20}){"log_hold_timeout"}.getInt == 20
      # with the launch gate on (RUN-015) core assigns nothing until it has seen a healthy log circuit for
      # gate_stabilize (10 s) - fail-closed after every start - so wait for it instead of racing it
      if remoteCore or logsReady: check waitGate(apiPort, true, 60000) >= 0

    test "RUN-009/RUN-002: a run with one ci.job + Job:sh step reaches SUCCEEDED as a real Pod":
      let script = """
        return ci.pipeline({name = "walking-skeleton", main = function(run)
          local r
          ci.job({image = "busybox:1.36"}, function(j) r = j:sh("echo hello-from-m1-skeleton") end)
          return "code=" .. tostring(r.code)
        end})"""
      let created = postRun(apiPort, "p1", script)
      let runId = created["id"].getStr
      check created["state"].getStr == "RUNNING"

      let final = waitTerminal(apiPort, runId)
      check final["state"].getStr == "SUCCEEDED"

      # the deterministic Pod (RUN-002) really ran on the cluster, not just in core's bookkeeping
      let name = podName(runId, 0, 1)
      # (the run is finished when core has the shim's result; the shim then exits, so the Pod turns Succeeded a moment later)
      check waitPodPhase(name, "Succeeded", 60000)
      let podOut = execProcess(kubectlBase & " -n " & ns & " logs " & name).strip
      # the Pod log holds the shim's CICD-SHIM events and nothing else: the build's output goes through the log pipeline only
      # (D-29) - it is read back through the platform's API below, not from `kubectl logs`
      check podOut.splitLines.allIt(it.len == 0 or it.startsWith("CICD-SHIM "))
      check "hello-from-m1-skeleton" notin podOut

      # and the shard's own bookkeeping (steps, run_journal) agrees
      var c = newRq(rqliteUrl)
      let r = c.query(%*[["SELECT state, exit_code FROM steps WHERE run_id = ? AND ordinal = 0", runId]])
      let row = r["results"][0]{"values"}[0]
      check row[0].getStr == "SUCCEEDED"
      check row[1].getInt == 0

      # D-29: the Pod log, ZeroMQ and rqlite tell the same story. The Pod log has every transition; what core stored in
      # steps.shim_* (from either route) must be that story's last line, and the step state its mapping.
      let events = podOut.splitLines.filterIt(it.startsWith("CICD-SHIM ")).mapIt(parseJson(it["CICD-SHIM ".len .. ^1]))
      check events.mapIt(it["ev"].getStr) == @["started", "command_started", "command_exited", "logs_delivering", "logs_delivered", "done"]
      check events.mapIt(it["n"].getInt) == @[1, 2, 3, 4, 5, 6]
      var cc = newRq(rqliteUrl)
      let sr = cc.query(%*[["SELECT shim_n, shim_phase, shim_json, shim_source, state FROM steps WHERE run_id = ? AND ordinal = 0", runId]])
      let srow = sr["results"][0]{"values"}[0]
      check srow[0].getInt == 6                            # the same event number as the last Pod-log line
      check srow[1].getStr == "done" and srow[4].getStr == "SUCCEEDED"
      check srow[3].getStr in ["zmq", "pod_log"]
      let stored = parseJson(srow[2].getStr)
      check stored["ev"].getStr == "done" and stored["reason"].getStr == "ok" and stored["exit"].getInt == 0
      check stored["cmd"]["exit"].getInt == events[^1]["cmd"]["exit"].getInt

    if remoteCore:
      test "RUN-007/DAT-001: the step Pod's own shim streamed its stdout to the remote core (read back via the API)":
        var c = newRq(rqliteUrl)
        let r = c.query(%*[["SELECT run_id FROM steps WHERE command LIKE '%hello-from-m1-skeleton%' ORDER BY queued_at DESC LIMIT 1"]])
        let runId = r["results"][0]{"values"}[0][0].getStr
        var lines: seq[string]
        var waited = 0
        while waited < 15000:
          let c2 = newHttpClient(timeout = 2000)
          defer: c2.close()
          try:
            let resp = c2.request("http://" & host & ":" & $apiPort & "/api/v1/runs/" & runId & "/steps/0/log", HttpGet)
            if resp.code == Http200:
              lines = parseJson(resp.body)["lines"].mapIt(it.getStr)
              if lines.len > 0: break
          except CatchableError: discard
          sleep 500
          waited += 500
        check "hello-from-m1-skeleton" in lines

    if not logsReady:
      test "skipped: CINIM_VLAGENT_URL/CINIM_VICTORIALOGS_URL not set (RUN-007/DAT-001 log pipeline)":
        skip()
    else:
      test "RUN-007/DAT-001: the real shim streams a step's stdout into real VictoriaLogs, readable via the API":
        # this runs the shim as a local subprocess rather than inside a real cluster Pod - a dedicated run/step row, independent of the
        # executor-driven run above, keeps this test focused on the log pipeline alone.
        let runId = "s1_logtest" & $int(epochTime())
        var c = newRq(rqliteUrl)
        discard c.execute(%*[
          ["INSERT INTO runs (id, tenant_id, project_id, state, version, created_at, updated_at) " &
           "VALUES (?, 't1', 'p1', 'RUNNING', 1, '0', '0')", runId],
          ["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, 'k1', 'RUNNING', 'p1')", "job-" & runId, runId],
          ["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, queued_at) " &
           "VALUES (?, ?, ?, 0, 'sh', 'RUNNING', 'p1', 'x', 'x', '0')", "step-" & runId, runId, "job-" & runId]],
          transaction = true)

        let termLog = buildDir / "logtest-term.json"
        let shimExit = execCmd(quoteShell(buildDir / "cicd-shim-logging") & " --run-dir " & quoteShell(buildDir / "logtest-run") &
          " --termination-log " & quoteShell(termLog) &
          " --collector-addr tcp://" & host & ":" & $logIngestPort &
          " --core-addr tcp://" & host & ":" & $stepReportPort &
          " --certs-dir " & quoteShell(certs) & " --log-spool-dir " & quoteShell(buildDir / "logtest-spool") &
          " --run-id " & runId & " --step-seq 0 --step-attempt 1" &
          " -- sh -c " & quoteShell("echo hello-from-the-log-pipeline"))
        check shimExit == 0

        var lines: seq[string]
        var waited = 0
        while waited < 10000:
          let c2 = newHttpClient(timeout = 2000)
          defer: c2.close()
          try:
            let resp = c2.request("http://" & host & ":" & $apiPort & "/api/v1/runs/" & runId & "/steps/0/log", HttpGet)
            if resp.code == Http200:
              lines = parseJson(resp.body)["lines"].mapIt(it.getStr)
              if lines.len > 0: break
          except CatchableError: discard
          sleep 500
          waited += 500
        check "hello-from-the-log-pipeline" in lines

    if remoteCore:
      test "RUN-015: log circuit down -> the gate closes, the step waits as logs_unavailable and no Pod is created; it resumes after recovery":
        # the real thing: VictoriaLogs is scaled to zero in the cluster (this is our own log circuit, namespace
        # `victorialogs`), core on the long-test host notices through its /health polls, and is scaled back afterwards
        proc scaleLogs(n: int) =
          discard execCmd(kubectlBase & " -n victorialogs scale statefulset victorialogs --replicas=" & $n)
        check waitGate(apiPort, true, 60000) >= 0          # the circuit is healthy at the start
        var runId = ""
        scaleLogs(0)
        try:
          let closedAfter = waitGate(apiPort, false, 30000)
          check closedAfter >= 0
          echo "  gate closed ", closedAfter, " ms after VictoriaLogs was scaled down (spec: within 10 s of the loss)"
          check launchGate(apiPort){"reason"}.getStr == "logs_unavailable"
          let script = """
            return ci.pipeline({name = "gate", main = function(run)
              local r
              ci.job({image = "busybox:1.36"}, function(j) r = j:sh("echo gate-test-step") end)
              return "code=" .. tostring(r.code)
            end})"""
          runId = postRun(apiPort, "p1", script)["id"].getStr   # creating a run is not blocked (RUN-015 b)
          sleep 8000
          let run = getRun(apiPort, runId)
          check run["state"].getStr == "RUNNING"
          check run{"wait_reason"}.getStr == "logs_unavailable"   # the API says why
          let pod = execCmdEx(kubectlBase & " -n " & ns & " get pod " & podName(runId, 0, 1))
          check pod.exitCode != 0                                 # and no Pod was created
        finally:
          scaleLogs(1)
        check waitGate(apiPort, true, 180000) >= 0             # recovered and stable for gate_stabilize -> open again
        let final = waitTerminal(apiPort, runId, 90000)         # the queue resumed by itself
        check final["state"].getStr == "SUCCEEDED"
        check final{"wait_reason"}.getStr == ""

    if remoteCore and logsReady:
      test "D-27: vlagent down while a step ends -> the Pod's shim holds the step, and finishes once vlagent is back":
        let runId = "s1_hold" & $int(epochTime())
        makeStepRows(runId)
        scaleAgent(0)
        var p: Process
        try:
          check waitGate(apiPort, false, 40000) >= 0
          p = startShim(runId, buildDir / "hold-spool", buildDir / "hold-term.json", "seq 1 3000", 10 * 1024 * 1024, 300)
          sleep 8000
          check p.running                                  # the command is long done, the step is not: its log is not delivered
          check not fileExists(buildDir / "hold-term.json")
        finally:
          scaleAgent(1)
        check p.waitForExit(180000) == 0                   # delivered -> the step ends normally
        p.close()
        var n = 0
        for _ in 0 ..< 20:
          n = storedLines(runId)
          if n == 3000: break
          sleep 1000
        check n == 3000                                    # every line, once
        check dirBytes(buildDir / "hold-spool") == 0       # and the spool is empty

      test "D-27: the log is not delivered within log_hold_timeout -> logs_undelivered (72), the command's own result is kept":
        let runId = "s1_lost" & $int(epochTime())
        makeStepRows(runId)
        scaleAgent(0)
        try:
          check waitGate(apiPort, false, 40000) >= 0
          var p = startShim(runId, buildDir / "lost-spool", buildDir / "lost-term.json", "echo about to fail; exit 3", 10 * 1024 * 1024, 12)
          check p.waitForExit(60000) == 72
          p.close()
          let term = parseJson(readFile(buildDir / "lost-term.json"))
          check term["reason"].getStr == "logs_undelivered"
          check term["command_exit_code"].getInt == 3
        finally:
          scaleAgent(1)
        check waitGate(apiPort, true, 180000) >= 0

      test "D-27: a full spool stops the step's process (backpressure) instead of losing lines or growing without bound":
        let runId = "s1_full" & $int(epochTime())
        makeStepRows(runId)
        let cap = 64 * 1024
        scaleAgent(0)
        var p: Process
        try:
          check waitGate(apiPort, false, 40000) >= 0
          p = startShim(runId, buildDir / "full-spool", buildDir / "full-term.json", "seq 1 400000", cap, 300)
          sleep 10000
          check p.running                                  # the command is blocked on its pipe, not finished and not failed
          let used = dirBytes(buildDir / "full-spool")
          echo "  spool held ", used, " bytes with a cap of ", cap, " while vlagent was down"
          check used > 0 and used <= cap + 70 * 1024         # at most one block over the cap, never unbounded
        finally:
          scaleAgent(1)
        check p.waitForExit(240000) == 0
        p.close()
        var n = 0
        for _ in 0 ..< 30:
          n = storedLines(runId)
          if n == 400000: break
          sleep 1000
        check n == 400000                                  # nothing lost, nothing doubled

    if remoteCore:
      test "D-28: the Pod vanishes after its command started -> NOT restarted (fate unknown), the reason is in the API":
        let runId = postRun(apiPort, "p1", sleepScript)["id"].getStr
        check waitPodPhase(podName(runId, 0, 1), "Running", 90000)
        check waitShimEvent(runId, 2, 60000)                    # command_started: the command is known to have run
        killPod(podName(runId, 0, 1))
        let final = waitTerminal(apiPort, runId, 90000)
        check final["state"].getStr == "INFRASTRUCTURE_ERROR"
        check stepAttempt(runId) == 1                              # no second attempt: a half-done deploy is not started again
        check final["steps"][0]["termination"].getStr == "outcome_unknown"

      test "D-28: a Pod lost before its command started is safe to repeat - up to infra_retries, then infrastructure_error":
        let never = """
          return ci.pipeline({name = "never", main = function(run)
            local r
            ci.job({image = "registry.invalid/never-pulled:1"}, function(j) r = j:sh("echo unreachable") end)
            return "code=" .. tostring(r.code)
          end})"""
        try:
          check setProfile(1){"infra_retries"}.getInt == 1
          let runId = postRun(apiPort, "p1", never)["id"].getStr
          check waitPodPhase(podName(runId, 0, 1), "Pending", 90000)   # the image can never be pulled: the container never starts
          killPod(podName(runId, 0, 1))
          check waitAttempt(runId, 2, 60000)                          # provably never started: repeated
          check waitPodPhase(podName(runId, 0, 2), "Pending", 90000)
          killPod(podName(runId, 0, 2))
          let final = waitTerminal(apiPort, runId, 90000)             # attempt 2 > infra_retries (1): give up
          check final["state"].getStr == "INFRASTRUCTURE_ERROR"
          check stepAttempt(runId) == 2
          check final["steps"][0]["termination"].getStr == "lost_never_started"
        finally:
          check setProfile(3){"infra_retries"}.getInt == 3           # defaults back for whatever runs next

    if remoteCore and logsReady:
      test "D-28: the log cannot be delivered within log_hold_timeout -> the command's result stands, the step is NOT repeated":
        let script = """
          return ci.pipeline({name = "lostlog", main = function(run)
            local r
            ci.job({image = "busybox:1.36"}, function(j) r = j:sh("sleep 25; echo result-is-known") end)
            return "code=" .. tostring(r.code)
          end})"""
        let runId = postRun(apiPort, "p1", script)["id"].getStr
        check waitPodPhase(podName(runId, 0, 1), "Running", 90000)
        scaleAgent(0)                                              # vlagent is gone while the command runs and ends
        var final: JsonNode
        try:
          final = waitTerminal(apiPort, runId, 150000)            # shim holds 20 s, exits 72 with the command's own code
        finally:
          scaleAgent(1)
        check waitGate(apiPort, true, 180000) >= 0
        check final["state"].getStr == "SUCCEEDED"                 # exit code 0 is the result
        check stepAttempt(runId) == 1                              # ... and the command is not run a second time
        check final["steps"][0]["termination"].getStr == "logs_undelivered"

    if remoteCore:
      test "D-29: core is stopped while the step runs and ends, then started again -> the shim waited, the result and the log arrive":
        let script = """
          return ci.pipeline({name = "corestop", main = function(run)
            local r
            ci.job({image = "busybox:1.36"}, function(j) r = j:sh("sleep 6; echo finished-while-core-was-away") end)
            return "code=" .. tostring(r.code)
          end})"""
        let runId = postRun(apiPort, "p1", script)["id"].getStr
        check waitPodPhase(podName(runId, 0, 1), "Running", 90000)
        check waitShimEvent(runId, 2, 60000)
        coreService("stop")
        try:
          sleep 8000                                              # the command ends meanwhile (and the shim holds for its 20 s log wait)
          check execProcess(kubectlBase & " -n " & ns & " get pod " & podName(runId, 0, 1) & " -o jsonpath={.status.phase}").strip == "Running"
        finally:
          coreService("start")                                    # the Pod is still Running: the shim is waiting for core's permission
        waitApiUp(apiPort, 60000)
        let final = waitTerminal(apiPort, runId, 120000)
        check final["state"].getStr == "SUCCEEDED"
        check stepAttempt(runId) == 1                              # nothing was repeated
        check waitPodPhase(podName(runId, 0, 1), "Succeeded", 60000)   # the shim got its permission and exited
        var lines: seq[string]
        for _ in 0 ..< 30:
          lines = stepLogLines(runId)
          if "finished-while-core-was-away" in lines: break
          sleep 1000
        check "finished-while-core-was-away" in lines              # and the log it had spooled was delivered

      test "D-29: a Pod that never comes up is killed by core after liveness_timeout, and the step is not repeated":
        let never = """
          return ci.pipeline({name = "nostart", main = function(run)
            local r
            ci.job({image = "registry.invalid/never-pulled:2"}, function(j) r = j:sh("echo unreachable") end)
            return "code=" .. tostring(r.code)
          end})"""
        try:
          check putProfile(%*{"liveness_timeout": 30}){"liveness_timeout"}.getInt == 30
          let runId = postRun(apiPort, "p1", never)["id"].getStr
          check waitPodPhase(podName(runId, 0, 1), "Pending", 90000)
          let final = waitTerminal(apiPort, runId, 120000)
          check final["state"].getStr == "INFRASTRUCTURE_ERROR"
          check final["steps"][0]["termination"].getStr == "start_timeout"
          check stepAttempt(runId) == 1
          var gone = false
          for _ in 0 ..< 30:                                        # the controller's next poll brings CancelStep for the unwanted Pod
            if execProcess(kubectlBase & " -n " & ns & " get pod " & podName(runId, 0, 1) & " 2>&1").contains("NotFound"):
              gone = true
              break
            sleep 1000
          check gone
        finally:
          check putProfile(%*{"liveness_timeout": 300}){"liveness_timeout"}.getInt == 300

      test "D-29: a shim that cannot reach core goes silent; core removes the Pod, but its undelivered log is pulled out first":
        let script = """
          return ci.pipeline({name = "cutoff", main = function(run)
            local r
            ci.job({image = "busybox:1.36"}, function(j) r = j:sh("i=0; while true; do echo tick-$i; i=$((i+1)); sleep 1; done") end)
            return "code=" .. tostring(r.code)
          end})"""
        let np = buildDir / "cutoff-np.yaml"
        try:
          check putProfile(%*{"liveness_timeout": 30}){"liveness_timeout"}.getInt == 30
          let runId = postRun(apiPort, "p1", script)["id"].getStr
          check waitPodPhase(podName(runId, 0, 1), "Running", 90000)
          check waitShimEvent(runId, 2, 60000)
          var n0 = 0
          for _ in 0 ..< 20:                                       # a few ticks reach the store the normal way first
            n0 = storedLines(runId)
            if n0 >= 3: break
            sleep 1000
          check n0 >= 3
          # cut every path from the step Pods to core (the controller, running elsewhere, keeps its own)
          writeFile(np, "apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata: {name: cutoff}\nspec:\n  podSelector: {}\n" &
            "  policyTypes: [Egress]\n  egress:\n  - to:\n    - ipBlock: {cidr: 0.0.0.0/0, except: [" & host & "/32]}\n")
          check execCmd(kubectlBase & " -n " & ns & " apply -f " & np) == 0
          sleep 3000
          let nBlocked = storedLines(runId)
          let final = waitTerminal(apiPort, runId, 150000)         # ~30 s of silence, then core ends the step
          check final["state"].getStr == "INFRASTRUCTURE_ERROR"
          check final["steps"][0]["termination"].getStr == "outcome_unknown"
          var gone = false
          for _ in 0 ..< 120:                                       # CancelStep -> pull the spool (two exec calls, ~17 s each) -> hand it to core -> delete the Pod
            if execProcess(kubectlBase & " -n " & ns & " get pod " & podName(runId, 0, 1) & " 2>&1").contains("NotFound"):
              gone = true
              break
            sleep 1000
          check gone
          var nFinal = 0
          for _ in 0 ..< 20:
            nFinal = storedLines(runId)
            if nFinal > nBlocked + 15: break
            sleep 1000
          echo "  stored before the cut ", n0, ", when it was noticed ", nBlocked, ", after the rescue ", nFinal
          check nFinal > nBlocked + 15                              # the ~30+ ticks printed while cut off came out of the spool
        finally:
          discard execCmd(kubectlBase & " -n " & ns & " delete networkpolicy cutoff --ignore-not-found")
          check putProfile(%*{"liveness_timeout": 300}){"liveness_timeout"}.getInt == 300

      test "D-29: the step's timeout from Lua ends the build, reason timeout":
        let script = """
          return ci.pipeline({name = "tmo", main = function(run)
            local r
            ci.job({image = "busybox:1.36"}, function(j) r = j:sh("sleep 120", {timeout = 8}) end)
            return "code=" .. tostring(r.code)
          end})"""
        let runId = postRun(apiPort, "p1", script)["id"].getStr
        let final = waitTerminal(apiPort, runId, 120000)        # a step that exits non-zero fails the job and so the run (6.7); only the step is checked here
        check final["steps"][0]["state"].getStr == "FAILED"
        check final["steps"][0]["termination"].getStr == "timeout"
        check final["steps"][0]["exit_code"].getInt == 124

    if remoteCore and logsReady:
      test "docs/secrets-masking.md: a value the build registers in $CICD_MASK never reaches the stored log":
        let script = """
          return ci.pipeline({name = "mask", main = function(run)
            local r
            ci.job({image = "busybox:1.36"}, function(j)
              r = j:sh("T=tok-q7x9-secret; echo $T >> \"$CICD_MASK\"; echo leaked:$T; echo b64:$(printf %s $T | base64)")
            end)
            return "code=" .. tostring(r.code)
          end})"""
        let runId = postRun(apiPort, "p1", script)["id"].getStr
        check waitTerminal(apiPort, runId, 120000)["state"].getStr == "SUCCEEDED"
        var lines: seq[string]
        for _ in 0 ..< 30:
          lines = stepLogLines(runId)
          if lines.len >= 2: break
          sleep 1000
        check "leaked:***" in lines
        check lines.allIt("tok-q7x9-secret" notin it and "dG9rLXE3eDktc2VjcmV0" notin it)

      test "log_max_bytes: the stored log is cut with a marker, the step itself is not affected":
        try:
          check putProfile(%*{"log_max_bytes": 1048576}){"log_max_bytes"}.getInt == 1048576
          let script = """
            return ci.pipeline({name = "bigout", main = function(run)
              local r
              ci.job({image = "busybox:1.36"}, function(j) r = j:sh("seq 1 400000; echo after-the-flood") end)
              return "code=" .. tostring(r.code)
            end})"""
          let runId = postRun(apiPort, "p1", script)["id"].getStr
          let final = waitTerminal(apiPort, runId, 180000)
          check final["state"].getStr == "SUCCEEDED"
          var n = 0
          for _ in 0 ..< 30:
            n = storedLines(runId)
            if n > 0: break
            sleep 1000
          check n > 1000 and n < 400000                              # about 1 MiB of lines, not 2.6 MiB
          var markers = 0
          for _ in 0 ..< 20:                                          # the marker is the last record: wait until it is stored too
            markers = storedLines(runId, "\"log truncated\"")
            if markers > 0: break
            sleep 1000
          check markers == 1                                          # exactly one marker line, where the log was cut
          var c = newRq(rqliteUrl)
          let r = c.query(%*[["SELECT shim_json FROM steps WHERE run_id = ? AND ordinal = 0", runId]])
          check parseJson(r["results"][0]{"values"}[0][0].getStr){"trunc"}.getBool
        finally:
          check putProfile(%*{"log_max_bytes": 1073741824}){"log_max_bytes"}.getInt == 1073741824

    if remoteCore:
      proc coreMetrics(): string =
        let c2 = newHttpClient(timeout = 3000)
        defer: c2.close()
        try: c2.getContent("http://" & host & ":" & $apiPort & "/metrics") except CatchableError: ""

      proc waitMetric(needle: string; timeoutMs: int): bool =
        var waited = 0
        while waited < timeoutMs:
          if needle in coreMetrics(): return true
          sleep 1000
          waited += 1000
        false

      test "docs/metrics.md: the application's own /metrics endpoint is scraped by the shim and shows up in core's /metrics":
        let script = """
          return ci.pipeline({name = "scrape", main = function(run)
            local r
            ci.job({image = "busybox:1.36"}, function(j)
              r = j:sh("mkdir -p /tmp/www; printf 'myapp_requests_total 42\\nignored_thing 1\\n' > /tmp/www/metrics; httpd -p 127.0.0.1:9404 -h /tmp/www; sleep 25",
                {metrics = {scrape = {{url = "http://127.0.0.1:9404/metrics", name = "myapp", interval = "1s", include = {"myapp_*"}}}}})
            end)
            return "code=" .. tostring(r.code)
          end})"""
        let runId = postRun(apiPort, "p1", script)["id"].getStr
        check waitMetric("cinim_inflight_app_metric_sum{source=\"myapp\",metric=\"myapp_requests_total\"} 42.000", 90000)
        check "ignored_thing" notin coreMetrics()                               # `include` filtered it in the shim
        check "cinim_inflight_scrape_up{source=\"myapp\"} 1" in coreMetrics()
        check waitTerminal(apiPort, runId, 120000)["state"].getStr == "SUCCEEDED"

      test "docs/metrics.md: a JVM's counters (hsperfdata) are read without any agent":
        let script = """
          return ci.pipeline({name = "jvm", main = function(run)
            local r
            ci.job({image = "eclipse-temurin:21-jdk"}, function(j)
              r = j:sh("cat > /tmp/Spin.java <<'EOF'\npublic class Spin { public static void main(String[] a) throws Exception { byte[] k = new byte[20 << 20]; System.gc(); Thread.sleep(25000); } }\nEOF\njava /tmp/Spin.java",
                {metrics = {runtime = "jvm"}})
            end)
            return "code=" .. tostring(r.code)
          end})"""
        let runId = postRun(apiPort, "p1", script)["id"].getStr
        check waitMetric("cinim_inflight_app_metric_sum{source=\"jvm\",metric=\"jvm_threads_current\"}", 240000)
        check "cinim_inflight_app_metric_sum{source=\"jvm\",metric=\"jvm_heap_used_bytes\"}" in coreMetrics()
        discard waitTerminal(apiPort, runId, 120000)

      test "an OOM kill is the step's own failure: reason oom_killed, nothing repeated":
        let script = """
          return ci.pipeline({name = "oom", main = function(run)
            local r
            ci.job({image = "busybox:1.36"}, function(j) r = j:sh("x=$(head -c 400000000 /dev/zero | tr '\\0' a); echo survived") end)
            return "code=" .. tostring(r.code)
          end})"""
        let runId = postRun(apiPort, "p1", script)["id"].getStr
        let final = waitTerminal(apiPort, runId, 120000)
        check final["steps"][0]["state"].getStr == "FAILED"
        check final["steps"][0]["termination"].getStr == "oom_killed"
        check final["steps"][0]["exit_code"].getInt == 137
        check stepAttempt(runId) == 1

    test "cleanup: stop the services and delete the test namespace":
      if remoteCore: discard putProfile(%*{"log_hold_timeout": 600})
      stopAll()
      discard execCmd(kubectlBase & " delete ns " & ns & " --wait=false")
