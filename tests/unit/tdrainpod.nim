## The drain of a step's leavings (DAT-003, D-27, D-53, docs/artifacts.md): the controller makes a Pod on the run's volume that runs `cicd-shim --drain`, and reads how it ended;
## the shim in that mode reads the manifest and the log spool the step's shim left on the volume and sends them to the core. The controller against a fake cluster, the shim as
## a real process against a core nobody listens on (what is checked is what it does before and when the core does not answer; the bytes through a real core are checked live).
import std/[unittest, os, osproc, json, strutils, tables, sequtils]
import checksums/sha2
import common/spoolwire
import jobcontroller/[backend, drain, logic]

func sha(data: string): string =
  for c in secureHash(Sha_256, data): result.add toHex(ord(c), 2).toLowerAscii

type World = ref object
  pods: Table[string, JsonNode]
  cmds: Table[string, seq[string]]
  deleted: seq[string]
  refuse: CreateOutcome

proc backendOf(w: World): Backend =
  Backend(
    readPod: proc (name: string): JsonNode =
      if name in w.pods: w.pods[name] else: %*{"kind": "Status", "code": 404, "reason": "NotFound"},
    createDrainPod: proc (name, runId, image: string; cmd: seq[string]): CreateOutcome =
      if w.refuse.kind != ckOk: return w.refuse
      w.pods[name] = %*{"status": {"phase": "Pending"}}
      w.cmds[name] = cmd
      CreateOutcome(kind: ckOk),
    deletePod: proc (name: string; grace: int): bool =
      w.deleted.add name
      w.pods.del name
      true,
    listPods: proc (): tuple[ok: bool, pods: seq[PodSummary]] =
      result.ok = true
      for n, p in w.pods: result.pods.add PodSummary(name: n, phase: p{"status", "phase"}.getStr, createdAt: 1000))

func order(artifacts = true, logs = false): DrainOrder =
  DrainOrder(runId: "s1_run", seq: 2, attempt: 1, image: "img", token: "tok-123", artifacts: artifacts, logs: logs)

let addrs = DrainAddrs(collectorAddr: "tcp://core:19743", artifactAddr: "tcp://core:19744")
let podName = drainPodName("s1_run", 2, 1)

func ended(code: int; reason, detail: string): JsonNode =
  %*{"status": {"phase": (if code == 0: "Succeeded" else: "Failed"), "containerStatuses": [{"state": {"terminated":
    {"exitCode": code, "message": $(%*{"exit_code": code, "reason": reason, "detail": detail})}}}]}}

suite "DAT-003 the Pod of a drain":
  test "the first look makes the Pod, on the volume, with the shim's drain flags: the step's paths, its credential, the core's addresses, and what is to be drained":
    let w = World()
    let be = w.backendOf
    check drainStep(be, order(), addrs).state == dsMore
    let cmd = w.cmds[podName]
    check cmd[0] == "/cicd/shim/cicd-shim" and cmd[1] == "--drain"
    check cmd[cmd.find("--run-id") + 1] == "s1_run" and cmd[cmd.find("--step-seq") + 1] == "2" and cmd[cmd.find("--step-attempt") + 1] == "1"
    check cmd[cmd.find("--manifest-dir") + 1] == drainDir(2, 1) and cmd[cmd.find("--log-spool-dir") + 1] == drainDir(2, 1) & "/spool"
    check cmd[cmd.find("--step-token") + 1] == "tok-123" and cmd[cmd.find("--artifact-addr") + 1] == "tcp://core:19744"
    check cmd[cmd.find("--collector-addr") + 1] == "tcp://core:19743"
    check "--artifacts" in cmd and "--logs" notin cmd
    let logsOnly = World()
    discard drainStep(logsOnly.backendOf, order(artifacts = false, logs = true), addrs)
    check "--logs" in logsOnly.cmds[podName] and "--artifacts" notin logsOnly.cmds[podName]
  test "a Pod that is being made or is working is waited for, and not made twice":
    let w = World()
    let be = w.backendOf
    discard drainStep(be, order(), addrs)
    check drainStep(be, order(), addrs).state == dsMore
    w.pods[podName] = %*{"status": {"phase": "Running"}}
    check drainStep(be, order(), addrs).state == dsMore and w.cmds.len == 1
  test "a Pod that ended well is a drain that is done, and the Pod is removed":
    let w = World()
    w.pods[podName] = ended(0, "drained", "")
    check drainStep(w.backendOf, order(), addrs).state == dsDone
    check w.deleted == @[podName]
  test "a Pod that ended with the shim's answer 'failed' (the file is not the one recorded, the core refused for good) fails the drain, with what the shim said":
    let w = World()
    w.pods[podName] = ended(78, "failed", "dist/a.txt: the file is not the one the shim recorded (SHA-256), a later step changed it")
    let r = drainStep(w.backendOf, order(), addrs)
    check r.state == dsFailed and "SHA-256" in r.detail and w.deleted == @[podName]
  test "a Pod that ended because the core or the store did not answer (77), or in a way nobody explained, is tried again later":
    let w = World()
    w.pods[podName] = ended(77, "retry", "dist/a.txt: store_unavailable: the store did not answer")
    let r = drainStep(w.backendOf, order(), addrs)
    check r.state == dsRetry and "store_unavailable" in r.detail and w.deleted == @[podName]
    let v = World()
    v.pods[podName] = %*{"status": {"phase": "Failed", "containerStatuses": [{"state": {"terminated": {"exitCode": 137}}}]}}
    check drainStep(v.backendOf, order(), addrs).state == dsRetry and v.deleted == @[podName]
  test "a Pod that waits for the run's claim, which is gone, fails the drain; one that is only slow is waited for":
    let w = World()
    w.pods[podName] = %*{"status": {"phase": "Pending", "conditions": [{"type": "PodScheduled", "status": "False", "reason": "Unschedulable",
      "message": "0/3 nodes are available: persistentvolumeclaim \"cicd-run-s1-run\" not found."}]}}
    let r = drainStep(w.backendOf, order(), addrs)
    check r.state == dsFailed and "volume is gone" in r.detail and w.deleted == @[podName]
    let v = World()
    v.pods[podName] = %*{"status": {"phase": "Pending"}}
    check drainStep(v.backendOf, order(), addrs).state == dsMore
  test "a Pod the cluster refused fails the drain, one the quota refused is tried again":
    let w = World()
    w.refuse = CreateOutcome(kind: ckRejected, message: "violates PodSecurity")
    check drainStep(w.backendOf, order(), addrs).state == dsFailed
    w.refuse = CreateOutcome(kind: ckQuota, message: "exceeded quota")
    check drainStep(w.backendOf, order(), addrs).state == dsRetry
  test "a drain Pod older than any drain is removed, a young one and a step's Pod are not":
    let w = World()
    w.pods["cdrain-old"] = %*{"status": {"phase": "Running"}}
    w.pods["ci-step"] = %*{"status": {"phase": "Running"}}
    check sweepDrainPods(w.backendOf, 1000 + 3 * 3600) == @["cdrain-old"]
    check sweepDrainPods(w.backendOf, 1000 + 60).len == 0

suite "DAT-003 the shim's drain mode":
  let exe = getTempDir() / "cinim-shim-drain-pod-test"
  let certs = getCurrentDir() / "tests" / "certs"
  var available = false

  test "setup: compile the logging shim":
    available = execCmd("nim c --hints:off --warnings:off -d:shimLogging --nimcache:" & exe & ".nc -o:" & exe & " src/shim/shim.nim") == 0 and dirExists(certs / "curve")
    if not available: skip()

  proc drainShim(dir: string; extra: seq[string]): tuple[code: int, term: JsonNode] =
    let tl = dir / "tl"
    removeFile(tl)
    let p = startProcess(exe, args = @["--drain", "--run-id", "s1_m", "--step-seq", "0", "--step-attempt", "1", "--workspace", dir / "ws",
      "--manifest-dir", dir / "state", "--log-spool-dir", dir / "state" / "spool", "--certs-dir", certs, "--step-token", "tok",
      "--collector-addr", "tcp://127.0.0.1:1", "--artifact-addr", "tcp://127.0.0.1:1", "--termination-log", tl, "--wait", "2"] & extra, options = {poStdErrToStdout})
    result.code = p.waitForExit(60000)
    p.close()
    result.term = if fileExists(tl): parseJson(readFile(tl)) else: newJNull()

  proc volume(name: string; files: seq[(string, string)]): string =
    result = getTempDir() / name
    removeDir(result)
    createDir(result / "ws")
    createDir(result / "state")
    var a = newJArray()
    for (path, data) in files:
      createDir(parentDir(result / "ws" / path))
      writeFile(result / "ws" / path, data)
      a.add %*{"path": path, "size": data.len, "sha256": sha(data)}
    if files.len > 0: writeFile(result / "state" / "artifacts.manifest", $a)

  test "nothing on the volume is a drain that is done":
    if not available: skip()
    else:
      let d = volume("drainpod-1", @[])
      let r = drainShim(d, @["--artifacts", "--logs"])
      check r.code == 0 and r.term["reason"].getStr == "drained"
  test "a file that is not the one the shim recorded is refused for good, before anything is sent (exit 78), and the manifest is left":
    if not available: skip()
    else:
      let d = volume("drainpod-2", @[("a.txt", "recorded")])
      writeFile(d / "ws" / "a.txt", "changed!")
      let r = drainShim(d, @["--artifacts"])
      check r.code == 78 and r.term["reason"].getStr == "failed" and "SHA-256" in r.term["detail"].getStr
      check fileExists(d / "state" / "artifacts.manifest")
  test "a path outside the workspace in the manifest is refused":
    if not available: skip()
    else:
      let d = volume("drainpod-3", @[])
      writeFile(d / "state" / "artifacts.manifest", $(%*[{"path": "../etc/passwd", "size": 1, "sha256": sha("x")}]))
      let r = drainShim(d, @["--artifacts"])
      check r.code == 78
  test "a core that does not answer is a drain to be tried again (exit 77); the manifest and the spool stay":
    if not available: skip()
    else:
      let d = volume("drainpod-4", @[("a.txt", "x")])
      let r = drainShim(d, @["--artifacts"])
      check r.code == 77 and r.term["reason"].getStr == "retry"
      check fileExists(d / "state" / "artifacts.manifest")
  test "a drain asked for without the credential does nothing":
    if not available: skip()
    else:
      let d = volume("drainpod-5", @[("a.txt", "x")])
      let p = startProcess(exe, args = @["--drain", "--run-id", "s1_m", "--certs-dir", certs, "--termination-log", d / "tl", "--artifacts"], options = {poStdErrToStdout})
      check p.waitForExit(30000) == 78
      p.close()
