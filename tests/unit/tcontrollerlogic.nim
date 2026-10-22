## The job-controller's decisions against a fake cluster (D-29): no Kubernetes, no ZeroMQ.
import std/[unittest, json, tables, options, strutils, os, sequtils]
import common/shimstate
import common/ids
import jobcontroller/[backend, ctrlstate, logic, podverdict, conductors, drain]

type Fake = ref object
  pods: Table[string, JsonNode]          ## name -> Pod JSON as the API would return it
  created: Table[string, int64]
  logs: Table[string, string]
  deleted: seq[string]
  creates: seq[PodRequest]
  listOk: bool
  refuse: CreateOutcome                 ## when its kind is not ckOk, creating a Pod is refused like this
  events: Table[string, seq[JsonNode]]  ## name -> the Kubernetes events about the Pod

proc newFake(): Fake = Fake(listOk: true)

proc backendOf(f: Fake): Backend =
  Backend(
    createPod: proc (r: PodRequest): CreateOutcome =
      if f.refuse.kind != ckOk: return f.refuse
      f.creates.add r
      f.pods[r.name] = %*{"status": {"phase": "Pending"}}
      f.created[r.name] = 1000
      CreateOutcome(kind: ckOk),
    readEvents: proc (name: string): seq[JsonNode] = f.events.getOrDefault(name),
    readPod: proc (name: string): JsonNode =
      if name in f.pods: f.pods[name] else: %*{"kind": "Status", "code": 404, "reason": "NotFound"},
    readLogTail: proc (name: string): string = f.logs.getOrDefault(name, ""),
    deletePod: proc (name: string; grace: int): bool =
      f.deleted.add name
      f.pods.del name
      true,
    listPods: proc (): tuple[ok: bool, pods: seq[PodSummary]] =
      result.ok = f.listOk
      for n, p in f.pods: result.pods.add PodSummary(name: n, phase: p{"status", "phase"}.getStr, createdAt: f.created.getOrDefault(n, 1000)))

proc running(): JsonNode = %*{"status": {"phase": "Running", "containerStatuses": [{"state": {"running": {}}}]}}
proc succeeded(): JsonNode =
  %*{"status": {"phase": "Succeeded", "containerStatuses": [{"state": {"terminated": {"exitCode": 0, "startedAt": "2026-10-02T10:00:00Z"}}}]}}
proc failed(code: int): JsonNode =
  %*{"status": {"phase": "Failed", "containerStatuses": [{"state": {"terminated": {"exitCode": code, "startedAt": "2026-10-02T10:00:00Z"}}}]}}

let cfg = block:
  var c = defaultConfig()
  c.collectorAddr = "tcp://core:1"
  c.stepReportAddr = "tcp://core:2"
  c

proc req(seq = 0; attempt = 1; runId = "s1_run"): StartRequest =
  StartRequest(runId: runId, seq: seq, attempt: attempt, image: "busybox", command: @["sh", "-c", "echo hi"])

proc shimLine(n: int; ev: ShimEvent; reason = ""): string =
  let s = ShimState(run: "s1_run", seq: 0, attempt: 1, n: n, event: ev, phase: phaseAfter[ev], cmdStarted: true, reason: reason)
  marker & $toJson(s, 1) & "\n"

suite "creating Pods":
  test "the command carries the shim, its flags, the step's options and, after `--`, the command":
    let r = buildRequest(cfg, StartRequest(runId: "s1_a", seq: 3, attempt: 2, image: "x", command: @["sh", "-c", "true"],
                                           logMaxBytes: 5, optsJson: """{"timeout":9}"""))
    check r.name == "s1-a-3-2" and r.logging
    check r.cmd[0] == "/cicd/shim/cicd-shim"
    let dd = r.cmd.find("--")
    check r.cmd[dd + 1 .. ^1] == @["sh", "-c", "true"]
    check "--opts-json" in r.cmd and "--log-max-bytes" in r.cmd and "--collector-addr" in r.cmd
  test "D-63 the shm the job asked for reaches the Pod request, from the step's options":
    check buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x", optsJson: """{"shm":"2Gi"}""")).shm == "2Gi"
    check buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x")).shm == ""
  test "the profile's spool size and hold timeout override the controller's defaults, per step":
    let r = buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x", logSpoolBytes: 2097152, logHoldTimeout: 45))
    check r.cmd[r.cmd.find("--log-spool-bytes") + 1] == "2097152" and r.cmd[r.cmd.find("--log-hold-timeout") + 1] == "45"
    check r.spoolBytes == 2097152
    let d = buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x"))
    check d.cmd[d.cmd.find("--log-hold-timeout") + 1] == "600"
  test "a step of the build profile is a build request, any other is not (D-42)":
    check buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x", profile: "build")).build
    check not buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x")).build
  test "a step of the deploy profile is a deploy request, any other is not (D-48)":
    check buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x", profile: "deploy")).deploy
    check not buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x", profile: "deploy")).build
    check not buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x")).deploy
  test "no core addresses -> no log streaming flags":
    check not buildRequest(defaultConfig(), req()).logging
  test "the row is written before the Pod exists":
    let st = openState(":memory:")
    var seenRowBeforeCreate = false
    let f = newFake()
    var be = backendOf(f)
    be.createPod = proc (r: PodRequest): CreateOutcome =
      seenRowBeforeCreate = st.has(r.name)
      CreateOutcome(kind: ckOk)
    check startPod(be, st, cfg, req(), 100).ok
    check seenRowBeforeCreate

suite "the volume the steps of a run share (STO-001, STO-006)":
  var volCfg = cfg
  test "STO-002 the shim is told where the step's own files, the workspace and the state are":
    let r = buildRequest(volCfg, req())
    check r.cmd[r.cmd.find("--run-dir") + 1] == "/cicd/run" and r.cmd[r.cmd.find("--workspace") + 1] == "/cicd/workspace"
    check r.cmd[r.cmd.find("--state-dir") + 1] == "/cicd/state"
  test "DAT-003, D-55 the manifest of the artifacts and the log spool are on the run volume, where a drain Pod finds them after the Pod has ended":
    var c2 = volCfg
    c2.collectorAddr = "tcp://core:19743"
    c2.stepReportAddr = "tcp://core:19742"
    c2.artifactAddr = "tcp://core:19744"
    let r = buildRequest(c2, req())
    check r.cmd[r.cmd.find("--manifest-dir") + 1] == drainDir(req().seq, req().attempt)
    check r.cmd[r.cmd.find("--log-spool-dir") + 1] == drainDir(req().seq, req().attempt) & "/spool"
    check "/cicd/spool" notin r.cmd                      # there is no spool of the Pod's own any more
  test "the claim of the run is made before its first Pod, and before the row":
    let st = openState(":memory:")
    var order: seq[string]
    var be = backendOf(newFake())
    be.ensureRunVolume = proc (runId, volume: string): CreateOutcome =
      order.add "claim " & runId & (if volume.len > 0: "/" & volume else: "") & (if st.has("s1-run-0-1"): " (row exists)" else: "")
      CreateOutcome(kind: ckOk)
    be.createPod = proc (r: PodRequest): CreateOutcome =
      order.add "pod"
      CreateOutcome(kind: ckOk)
    check startPod(be, st, volCfg, req(), 100).ok
    check order == @["claim s1_run", "pod"]
  test "STO-002 the claim made is that of the step's volume: the job's when it asked for one of its own, and the Pod is told which":
    let st = openState(":memory:")
    var claimed: seq[string]
    var podVolume: string
    var be = backendOf(newFake())
    be.ensureRunVolume = proc (runId, volume: string): CreateOutcome =
      claimed.add runId & "/" & volume
      CreateOutcome(kind: ckOk)
    be.createPod = proc (r: PodRequest): CreateOutcome =
      podVolume = r.volume
      CreateOutcome(kind: ckOk)
    var r = req()
    r.volume = "s1_job"
    check startPod(be, st, volCfg, r, 100).ok
    check claimed == @["s1_run/s1_job"] and podVolume == "s1_job"
  test "a claim that is refused (the quota of claims is used up) leaves no row and no Pod, and is told like a refused Pod":
    let st = openState(":memory:")
    let f = newFake()
    var be = backendOf(f)
    be.ensureRunVolume = proc (runId, volume: string): CreateOutcome =
      CreateOutcome(kind: ckQuota, reason: "Forbidden", message: "exceeded quota: persistentvolumeclaims")
    let o = startPod(be, st, volCfg, req(), 100)
    check o.kind == ckQuota and f.creates.len == 0 and not st.has("s1-run-0-1")
  test "STO-006 the volumes core names are deleted, and the ones that are gone are reported back":
    var deleted: seq[string]
    var be = backendOf(newFake())
    be.releaseRunVolume = proc (runId: string): bool =
      deleted.add runId
      runId != "s1_stuck"
    check releaseRunVolumes(be, @["s1_a", "s1_stuck", "s1_b"]) == @["s1_a", "s1_b"]
    check deleted == @["s1_a", "s1_stuck", "s1_b"]
  test "a backend without run volumes releases nothing":
    check releaseRunVolumes(backendOf(newFake()), @["s1_a"]).len == 0

suite "the poll round":
  test "a running Pod is in the inventory, an unseen one is not 'started'":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    check startPod(be, st, cfg, req(), 100).ok
    let r1 = pollRound(be, st, cfg, 100.0)
    check r1.transitions.len == 0 and r1.inventory.len == 1 and not r1.inventory[0].started
    f.pods["s1-run-0-1"] = running()
    let r2 = pollRound(be, st, cfg, 101.0)
    check r2.inventory[0].started and r2.inventory[0].phase == "Running"
    check st.get("s1-run-0-1").started                       # remembered
  test "the Pod's end becomes a transition, with the shim's last state from the log":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["s1-run-0-1"] = running()
    discard pollRound(be, st, cfg, 101.0)
    f.pods["s1-run-0-1"] = succeeded()
    f.logs["s1-run-0-1"] = shimLine(1, seStarted) & shimLine(2, seCommandStarted)
    let r = pollRound(be, st, cfg, 102.0)
    check r.transitions.len == 1 and r.transitions[0].kind == tkSucceeded
    check parseJson(r.transitions[0].shimJson)["n"].getInt == 2
  test "a Pod that vanishes: lost, and 'may have run' only if the container was seen running":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(0), 100)
    discard startPod(be, st, cfg, req(1), 100)
    f.pods["s1-run-1-1"] = running()
    discard pollRound(be, st, cfg, 101.0)
    f.pods.clear()
    let r = pollRound(be, st, cfg, 102.0)
    check r.transitions.len == 2
    for t in r.transitions:
      check t.kind == tkLost
      check t.reason == (if t.seq == 1: "outcome_unknown" else: "lost_never_started")
  test "a failed API read concludes nothing":
    let st = openState(":memory:")
    let f = newFake()
    var be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    be.readPod = proc (name: string): JsonNode = nil
    let r = pollRound(be, st, cfg, 101.0)
    check r.transitions.len == 0 and r.inventory.len == 1
  test "the running Pod's log is read every few seconds, not on every round":
    let st = openState(":memory:")
    let f = newFake()
    var reads = 0
    var be = backendOf(f)
    be.readLogTail = proc (name: string): string =
      inc reads
      shimLine(2, seCommandStarted)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["s1-run-0-1"] = running()
    discard pollRound(be, st, cfg, 100.0)
    discard pollRound(be, st, cfg, 101.0)
    discard pollRound(be, st, cfg, 102.0)
    check reads == 1
    discard pollRound(be, st, cfg, 106.0)
    check reads == 2

  test "the kernel's OOM kill (the whole container goes) is reported as oom_killed, the step's own failure":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["s1-run-0-1"] = %*{"status": {"phase": "Failed", "containerStatuses": [{"state": {"terminated":
      {"exitCode": 137, "reason": "OOMKilled", "startedAt": "2026-10-02T10:00:00Z"}}}]}}
    let r = pollRound(be, st, cfg, 101.0)
    check r.transitions[0].kind == tkFailed and r.transitions[0].reason == "oom_killed" and r.transitions[0].exitCode == 137

  test "DAT-003 a Pod that ended with its artifacts undelivered is reported as that, not as an undelivered log: the drain core orders is another one":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["s1-run-0-1"] = %*{"status": {"phase": "Failed", "containerStatuses": [{"state": {"terminated":
      {"exitCode": 76, "message": $(%*{"exit_code": 76, "reason": "artifacts_undelivered", "command_exit_code": 0}), "startedAt": "2026-10-02T10:00:00Z"}}}]}}
    let r = pollRound(be, st, cfg, 101.0)
    check r.transitions[0].kind == tkSucceeded and r.transitions[0].reason == "artifacts_undelivered" and not r.transitions[0].fullyRead
  test "a Pod evicted for its own storage limit is reported as ephemeral_storage_exceeded with what Kubernetes said":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["s1-run-0-1"] = %*{"status": {"phase": "Failed", "reason": "Evicted",
      "message": "Pod ephemeral local storage usage exceeds the total limit of containers 1Gi. ",
      "containerStatuses": [{"state": {"terminated": {"exitCode": 137, "startedAt": "2026-10-02T10:00:00Z"}}}]}}
    let r = pollRound(be, st, cfg, 101.0)
    check r.transitions[0].kind == tkFailed and r.transitions[0].reason == "ephemeral_storage_exceeded"
    check r.transitions[0].podReason == "Evicted" and "exceeds the total limit" in r.transitions[0].podMessage

suite "the secrets of a step":
  test "the shim is told to fetch them with the step's credential; the Pod gets a placeholder per name and no value":
    let r = buildRequest(cfg, StartRequest(runId: "s1_run", seq: 0, attempt: 1, image: "busybox", command: @["sh", "-c", "true"],
                                           secretNames: @["REGISTRY_PASSWORD", "DEPLOY_KEY"], stepToken: "tok123"))
    check r.secrets == @["REGISTRY_PASSWORD", "DEPLOY_KEY"]
    let at = r.cmd.find("--fetch-secrets")
    check at >= 0 and r.cmd[r.cmd.find("--step-token") + 1] == "tok123"
    check r.cmd.find("--") > at
  test "a step without secrets has none of this":
    let r = buildRequest(cfg, StartRequest(runId: "s1_run", seq: 0, attempt: 1, image: "busybox"))
    check r.secrets.len == 0 and "--fetch-secrets" notin r.cmd and "--step-token" notin r.cmd
  test "names without a credential are not turned into a fetch the shim cannot make":
    let r = buildRequest(cfg, StartRequest(runId: "s1_run", seq: 0, attempt: 1, image: "busybox", secretNames: @["A"]))
    check r.secrets.len == 0 and "--fetch-secrets" notin r.cmd

suite "the launch parameters of a run":
  test "VAR-002 they reach the container as plain environment variables, next to the placeholders of the secrets":
    let r = buildRequest(cfg, StartRequest(runId: "s1_run", seq: 0, attempt: 1, image: "busybox", secretNames: @["TOKEN"], stepToken: "t",
                                           env: @[("BRANCH", "main"), ("JOBS", "4")]))
    check r.podEnv == @[("BRANCH", "main"), ("JOBS", "4"), ("TOKEN", "cinim-secret:TOKEN")]
  test "VAR-002 a secret of the same name as a parameter wins, and the parameter value is not in the Pod":
    let r = buildRequest(cfg, StartRequest(runId: "s1_run", seq: 0, attempt: 1, image: "busybox", secretNames: @["TOKEN"], stepToken: "t",
                                           env: @[("TOKEN", "from-a-parameter")]))
    check r.podEnv == @[("TOKEN", "cinim-secret:TOKEN")]
  test "VAR-002 a step without parameters and secrets has no environment of its own":
    check buildRequest(cfg, StartRequest(runId: "s1_run", seq: 0, attempt: 1, image: "busybox")).podEnv.len == 0

suite "what the cluster says about a Pod, and a Pod that cannot be made":
  test "a used-up quota leaves no row behind and says what the API server said":
    let st = openState(":memory:")
    let f = newFake()
    f.refuse = CreateOutcome(kind: ckQuota, reason: "Forbidden", message: "pods \"x\" is forbidden: exceeded quota: cinim-default, requested: pods=1, used: pods=100, limited: pods=100")
    let be = backendOf(f)
    let o = startPod(be, st, cfg, req(), 100)
    check o.kind == ckQuota and not o.ok and "exceeded quota" in o.message
    check not st.has("s1-run-0-1")                   # nothing to find 404 later: core is told, the step waits
  test "a refusal for good is also not left as a row, and a transport failure is (the next poll finds out)":
    let st = openState(":memory:")
    let f = newFake()
    f.refuse = CreateOutcome(kind: ckRejected, reason: "Forbidden", message: "violates PodSecurity")
    check startPod(backendOf(f), st, cfg, req(), 100).kind == ckRejected and not st.has("s1-run-0-1")
    f.refuse = CreateOutcome(kind: ckTransport, reason: "NoResponse", message: "")
    check startPod(backendOf(f), st, cfg, req(), 100).ok and st.has("s1-run-0-1")
  test "a Pod that waits says why: the image cannot be pulled, or no node fits":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["s1-run-0-1"] = %*{"status": {"phase": "Pending", "containerStatuses": [{"state": {"waiting":
      {"reason": "ImagePullBackOff", "message": "Back-off pulling image \"x:1\""}}}]}}
    var r = pollRound(be, st, cfg, 101.0)
    check r.inventory[0].podReason == "ImagePullBackOff" and "Back-off" in r.inventory[0].podMessage
    f.pods["s1-run-0-1"] = %*{"status": {"phase": "Pending", "conditions": [{"type": "PodScheduled", "status": "False",
      "reason": "Unschedulable", "message": "0/6 nodes are available: 6 Insufficient cpu."}]}}
    r = pollRound(be, st, cfg, 102.0)
    check r.inventory[0].podReason == "Unschedulable" and "Insufficient cpu" in r.inventory[0].podMessage
    f.pods["s1-run-0-1"] = %*{"status": {"phase": "Pending", "containerStatuses": [{"state": {"waiting": {"reason": "ContainerCreating"}}}]}}
    check pollRound(be, st, cfg, 103.0).inventory[0].podReason == ""      # the normal wait says nothing
  test "the end of a Pod carries the diagnosis: containers, conditions, node, events":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["s1-run-0-1"] = %*{"spec": {"nodeName": "node-3", "containers": [{"name": "step", "resources": {"limits": {"memory": "128Mi"}}}]},
      "status": {"phase": "Failed", "reason": "Evicted", "message": "The node was low on resource: ephemeral-storage.", "qosClass": "Burstable",
                 "conditions": [{"type": "DisruptionTarget", "status": "True", "reason": "TerminationByKubelet", "message": "The node was low on resource"}],
                 "containerStatuses": [{"name": "step", "restartCount": 0, "imageID": "docker.io/library/busybox@sha256:abc",
                   "state": {"terminated": {"exitCode": 137, "reason": "Error", "signal": 9, "startedAt": "2026-10-02T10:00:00Z", "finishedAt": "2026-10-02T10:05:00Z"}}}]}}
    f.events["s1-run-0-1"] = @[%*{"type": "Warning", "reason": "Evicted", "message": "The node was low on resource: ephemeral-storage.", "count": 1}]
    let r = pollRound(be, st, cfg, 101.0)
    let d = parseJson(r.transitions[0].podDiag)
    check d["node"].getStr == "node-3" and d["qos"].getStr == "Burstable"
    check d["containers"][0]["state"]["terminated"]["signal"].getInt == 9 and d["containers"][0]["image_id"].getStr.endsWith("sha256:abc")
    check d["conditions"][0]["reason"].getStr == "TerminationByKubelet"
    check d["events"][0]["reason"].getStr == "Evicted"
    check d["resources"][0]["resources"]["limits"]["memory"].getStr == "128Mi"
  test "the diagnosis stays within its size: events are given up first":
    var evs: seq[JsonNode]
    for i in 0 ..< 40: evs.add %*{"type": "Warning", "reason": "BackOff", "message": "x".repeat(400), "count": i}
    let d = podDiag(%*{"status": {"phase": "Failed"}}, evs)
    check d.len <= maxDiag and parseJson(d)["events"].len <= 20

suite "adoption after a restart":
  test "a new controller process continues with the Pods the old one tracked":
    let path = getTempDir() / "ctrlstate-test.sqlite"
    removeFile path
    let f = newFake()
    let be = backendOf(f)
    block:
      let st = openState(path)
      discard startPod(be, st, cfg, req(), 100)
      f.pods["s1-run-0-1"] = running()
      discard pollRound(be, st, cfg, 101.0)
      st.close()                                           # the controller dies here
    f.pods["s1-run-0-1"] = succeeded()
    let st2 = openState(path)                              # ... and a new one starts
    let r = pollRound(be, st2, cfg, 200.0)
    check r.transitions.len == 1 and r.transitions[0].kind == tkSucceeded
    st2.close()
    removeFile path
  test "an end that was never acknowledged is reported again":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["s1-run-0-1"] = failed(2)
    check pollRound(be, st, cfg, 101.0).transitions.len == 1
    check pollRound(be, st, cfg, 102.0).transitions.len == 1       # core did not acknowledge (the poll failed): same again
    afterPoll(st, pollRound(be, st, cfg, 103.0).transitions, 103)
    check pollRound(be, st, cfg, 104.0).transitions.len == 0       # acknowledged: no more

suite "cancel, retention, orphans":
  test "a cancelled Pod is deleted and forgotten":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    cancelPod(be, st, "s1_run", 0, 1, 5)
    check f.deleted == @["s1-run-0-1"] and not st.has("s1-run-0-1")
  test "a Pod whose result core has and whose log was delivered is removed at once, a failed one too":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(0), 100)
    discard startPod(be, st, cfg, req(1), 100)
    f.pods["s1-run-0-1"] = succeeded()
    f.pods["s1-run-1-1"] = failed(1)
    afterPoll(st, pollRound(be, st, cfg, 101.0).transitions, 1000)
    check sweep(be, st, cfg, 1000).expired.len == 2                 # nothing is left in them that the platform does not have
    check f.deleted.len == 2 and not st.has("s1-run-0-1") and not st.has("s1-run-1-1")
  test "a Pod core could not read (log not delivered, end unknown) is kept 14 days, a success or not, and is listed as unread":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(0), 100)
    discard startPod(be, st, cfg, req(1), 100)
    # the end was reported, but the log was not delivered (a success) / the Pod vanished with the command started (unknown, so not a success)
    st.markReported("s1-run-0-1", ok = true, fullyRead = false, now = 1000, reason = "logs_undelivered")
    st.markReported("s1-run-1-1", ok = false, fullyRead = false, now = 2000, reason = "outcome_unknown")
    f.pods["s1-run-0-1"] = succeeded()
    f.pods["s1-run-1-1"] = failed(1)
    check cfg.retentionUnread == 14 * 86400
    check st.unread().mapIt(it.name) == @["s1-run-1-1", "s1-run-0-1"]            # newest first
    check st.unread()[0].endReason == "outcome_unknown"
    check sweep(be, st, cfg, 1000 + 14 * 86400 - 1).expired.len == 0
    check sweep(be, st, cfg, 1000 + 14 * 86400).expired == @["s1-run-0-1"]
    check sweep(be, st, cfg, 2000 + 14 * 86400).expired == @["s1-run-1-1"]
    check st.unread().len == 0                                                           # a removed Pod is no longer an alert
  test "DAT-003 a Pod whose leavings a drain delivered has nothing left to show: it goes with the next sweep, and is no longer an alert":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(0), 100)
    st.markReported("s1-run-0-1", ok = true, fullyRead = false, now = 1000, reason = "artifacts_undelivered")
    f.pods["s1-run-0-1"] = succeeded()
    check st.unread().len == 1
    check sweep(be, st, cfg, 1001).expired.len == 0                  # not drained yet: kept
    st.markDrained("s1-run-0-1")
    check st.unread().len == 0
    check sweep(be, st, cfg, 1001).expired == @["s1-run-0-1"]
    st.markDrained("s1-run-nothing-1")                            # a name that is not tracked changes nothing
  test "the time a fully read Pod is kept can be set, to look at it":
    var c = cfg
    c.retentionRead = 300
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, c, req(0), 100)
    f.pods["s1-run-0-1"] = failed(2)
    afterPoll(st, pollRound(be, st, c, 101.0).transitions, 1000)
    check sweep(be, st, c, 1299).expired.len == 0
    check sweep(be, st, c, 1300).expired == @["s1-run-0-1"]
  test "a Pod whose end is not yet reported is never swept":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["s1-run-0-1"] = succeeded()
    check sweep(be, st, cfg, 99999).expired.len == 0 and f.deleted.len == 0
  test "orphans: step Pods (named from the run id, `s1-...`) the controller has no record of are removed after the grace period, the platform's own and other Pods are left alone":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    f.pods["s1-old-0-1"] = running()
    f.created["s1-old-0-1"] = 1000
    f.pods["s1-new-0-1"] = running()
    f.created["s1-new-0-1"] = 1950                                # younger than the grace period
    for other in ["somebody-elses-pod", conductorPodName(1), drainPodName("s1_old", 0, 1), "cinim-job-controller-7"]:
      f.pods[other] = running()
      f.created[other] = 10
    let r = sweep(be, st, cfg, 2000)
    check r.orphans == @["s1-old-0-1"]
    check "somebody-elses-pod" in f.pods and "s1-new-0-1" in f.pods
    check conductorPodName(1) in f.pods and drainPodName("s1_old", 0, 1) in f.pods and "cinim-job-controller-7" in f.pods
  test "the Pods of the platform other than steps never start with the shard's prefix, which is how a step Pod is told (the name of a step Pod is its run id)":
    check podName("s1_x", 0, 1).startsWith(shardId & "-")
    for other in [conductorPodName(1), conductorPodName(20), drainPodName("s1_x", 0, 1), "cinim-job-controller-1"]:
      check not other.startsWith(shardId & "-")
  test "an unreadable pod list sweeps nothing":
    let st = openState(":memory:")
    let f = newFake()
    f.listOk = false
    f.pods["s1-old-0-1"] = running()
    check sweep(backendOf(f), st, cfg, 99999).orphans.len == 0
  test "a Pod we track is never an orphan":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    check sweep(be, st, cfg, 99999).orphans.len == 0

