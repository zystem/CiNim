## The job-controller's decisions against a fake cluster (D-29): no Kubernetes, no ZeroMQ.
import std/[unittest, json, tables, options, strutils, os, sequtils]
import common/spoolwire
import common/shimstate
import jobcontroller/[backend, ctrlstate, logic, podverdict]

type Fake = ref object
  pods: Table[string, JsonNode]          ## name -> Pod JSON as the API would return it
  created: Table[string, int64]
  logs: Table[string, string]
  deleted: seq[string]
  spool: seq[Frame]                     ## what the fake Pod's spool holds
  acked: uint64
  damageFirstReads: int                 ## the first N reads come back damaged (the lossy exec)
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
    execInPod: proc (name, container, command: string): tuple[ok: bool, output: string] =
      if name notin f.pods or f.pods[name]{"status", "phase"}.getStr != "Running": return
      result.ok = true
      let parts = command.split(' ')
      if "--ack-spool" in parts:
        f.acked = parseBiggestUInt(parts[parts.find("--upto") + 1])
        f.spool = f.spool.filterIt(it.seq > f.acked)
        return
      let after = parseBiggestUInt(parts[parts.find("--after-seq") + 1])
      let budget = parseInt(parts[parts.find("--max-bytes") + 1])
      var sent = 0
      for fr in f.spool:
        if fr.seq <= after: continue
        let enc = encodeFrame(fr)
        if sent > 0 and sent + enc.len > budget: break
        result.output.add enc
        sent += enc.len
      if f.damageFirstReads > 0 and result.output.len > 100:
        dec f.damageFirstReads
        result.output[result.output.len div 2] = char(ord(result.output[result.output.len div 2]) xor 1),
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
    check r.name == "ci-s1-a-3-2" and r.logging
    check r.cmd[0] == "/cicd/shim/cicd-shim"
    let dd = r.cmd.find("--")
    check r.cmd[dd + 1 .. ^1] == @["sh", "-c", "true"]
    check "--opts-json" in r.cmd and "--log-max-bytes" in r.cmd and "--collector-addr" in r.cmd
  test "the profile's spool size and hold timeout override the controller's defaults, per step":
    let r = buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x", logSpoolBytes: 2097152, logHoldTimeout: 45))
    check r.cmd[r.cmd.find("--log-spool-bytes") + 1] == "2097152" and r.cmd[r.cmd.find("--log-hold-timeout") + 1] == "45"
    check r.spoolBytes == 2097152
    let d = buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x"))
    check d.cmd[d.cmd.find("--log-hold-timeout") + 1] == "600"
  test "a step of the build profile is a build request, any other is not (D-42)":
    check buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x", profile: "build")).build
    check not buildRequest(cfg, StartRequest(runId: "s1_a", seq: 0, attempt: 1, image: "x")).build
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

suite "the poll round":
  test "a running Pod is in the inventory, an unseen one is not 'started'":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    check startPod(be, st, cfg, req(), 100).ok
    let r1 = pollRound(be, st, cfg, 100.0)
    check r1.transitions.len == 0 and r1.inventory.len == 1 and not r1.inventory[0].started
    f.pods["ci-s1-run-0-1"] = running()
    let r2 = pollRound(be, st, cfg, 101.0)
    check r2.inventory[0].started and r2.inventory[0].phase == "Running"
    check st.get("ci-s1-run-0-1").started                       # remembered
  test "the Pod's end becomes a transition, with the shim's last state from the log":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["ci-s1-run-0-1"] = running()
    discard pollRound(be, st, cfg, 101.0)
    f.pods["ci-s1-run-0-1"] = succeeded()
    f.logs["ci-s1-run-0-1"] = shimLine(1, seStarted) & shimLine(2, seCommandStarted)
    let r = pollRound(be, st, cfg, 102.0)
    check r.transitions.len == 1 and r.transitions[0].kind == tkSucceeded
    check parseJson(r.transitions[0].shimJson)["n"].getInt == 2
  test "a Pod that vanishes: lost, and 'may have run' only if the container was seen running":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(0), 100)
    discard startPod(be, st, cfg, req(1), 100)
    f.pods["ci-s1-run-1-1"] = running()
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
    f.pods["ci-s1-run-0-1"] = running()
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
    f.pods["ci-s1-run-0-1"] = %*{"status": {"phase": "Failed", "containerStatuses": [{"state": {"terminated":
      {"exitCode": 137, "reason": "OOMKilled", "startedAt": "2026-10-02T10:00:00Z"}}}]}}
    let r = pollRound(be, st, cfg, 101.0)
    check r.transitions[0].kind == tkFailed and r.transitions[0].reason == "oom_killed" and r.transitions[0].exitCode == 137

  test "a Pod evicted for its own storage limit is reported as ephemeral_storage_exceeded with what Kubernetes said":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["ci-s1-run-0-1"] = %*{"status": {"phase": "Failed", "reason": "Evicted",
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

suite "what the cluster says about a Pod, and a Pod that cannot be made":
  test "a used-up quota leaves no row behind and says what the API server said":
    let st = openState(":memory:")
    let f = newFake()
    f.refuse = CreateOutcome(kind: ckQuota, reason: "Forbidden", message: "pods \"x\" is forbidden: exceeded quota: cinim-default, requested: pods=1, used: pods=100, limited: pods=100")
    let be = backendOf(f)
    let o = startPod(be, st, cfg, req(), 100)
    check o.kind == ckQuota and not o.ok and "exceeded quota" in o.message
    check not st.has("ci-s1-run-0-1")                   # nothing to find 404 later: core is told, the step waits
  test "a refusal for good is also not left as a row, and a transport failure is (the next poll finds out)":
    let st = openState(":memory:")
    let f = newFake()
    f.refuse = CreateOutcome(kind: ckRejected, reason: "Forbidden", message: "violates PodSecurity")
    check startPod(backendOf(f), st, cfg, req(), 100).kind == ckRejected and not st.has("ci-s1-run-0-1")
    f.refuse = CreateOutcome(kind: ckTransport, reason: "NoResponse", message: "")
    check startPod(backendOf(f), st, cfg, req(), 100).ok and st.has("ci-s1-run-0-1")
  test "a Pod that waits says why: the image cannot be pulled, or no node fits":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["ci-s1-run-0-1"] = %*{"status": {"phase": "Pending", "containerStatuses": [{"state": {"waiting":
      {"reason": "ImagePullBackOff", "message": "Back-off pulling image \"x:1\""}}}]}}
    var r = pollRound(be, st, cfg, 101.0)
    check r.inventory[0].podReason == "ImagePullBackOff" and "Back-off" in r.inventory[0].podMessage
    f.pods["ci-s1-run-0-1"] = %*{"status": {"phase": "Pending", "conditions": [{"type": "PodScheduled", "status": "False",
      "reason": "Unschedulable", "message": "0/6 nodes are available: 6 Insufficient cpu."}]}}
    r = pollRound(be, st, cfg, 102.0)
    check r.inventory[0].podReason == "Unschedulable" and "Insufficient cpu" in r.inventory[0].podMessage
    f.pods["ci-s1-run-0-1"] = %*{"status": {"phase": "Pending", "containerStatuses": [{"state": {"waiting": {"reason": "ContainerCreating"}}}]}}
    check pollRound(be, st, cfg, 103.0).inventory[0].podReason == ""      # the normal wait says nothing
  test "the end of a Pod carries the diagnosis: containers, conditions, node, events":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["ci-s1-run-0-1"] = %*{"spec": {"nodeName": "node-3", "containers": [{"name": "step", "resources": {"limits": {"memory": "128Mi"}}}]},
      "status": {"phase": "Failed", "reason": "Evicted", "message": "The node was low on resource: ephemeral-storage.", "qosClass": "Burstable",
                 "conditions": [{"type": "DisruptionTarget", "status": "True", "reason": "TerminationByKubelet", "message": "The node was low on resource"}],
                 "containerStatuses": [{"name": "step", "restartCount": 0, "imageID": "docker.io/library/busybox@sha256:abc",
                   "state": {"terminated": {"exitCode": 137, "reason": "Error", "signal": 9, "startedAt": "2026-10-02T10:00:00Z", "finishedAt": "2026-10-02T10:05:00Z"}}}]}}
    f.events["ci-s1-run-0-1"] = @[%*{"type": "Warning", "reason": "Evicted", "message": "The node was low on resource: ephemeral-storage.", "count": 1}]
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
      f.pods["ci-s1-run-0-1"] = running()
      discard pollRound(be, st, cfg, 101.0)
      st.close()                                           # the controller dies here
    f.pods["ci-s1-run-0-1"] = succeeded()
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
    f.pods["ci-s1-run-0-1"] = failed(2)
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
    discard cancelPod(be, st, "s1_run", 0, 1, 5)
    check f.deleted == @["ci-s1-run-0-1"] and not st.has("ci-s1-run-0-1")
  test "a Pod whose result core has and whose log was delivered is removed at once, a failed one too":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(0), 100)
    discard startPod(be, st, cfg, req(1), 100)
    f.pods["ci-s1-run-0-1"] = succeeded()
    f.pods["ci-s1-run-1-1"] = failed(1)
    afterPoll(st, pollRound(be, st, cfg, 101.0).transitions, 1000)
    check sweep(be, st, cfg, 1000).expired.len == 2                 # nothing is left in them that the platform does not have
    check f.deleted.len == 2 and not st.has("ci-s1-run-0-1") and not st.has("ci-s1-run-1-1")
  test "a Pod core could not read (log not delivered, end unknown) is kept 14 days, a success or not, and is listed as unread":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(0), 100)
    discard startPod(be, st, cfg, req(1), 100)
    # the end was reported, but the log was not delivered (a success) / the Pod vanished with the command started (unknown, so not a success)
    st.markReported("ci-s1-run-0-1", ok = true, fullyRead = false, now = 1000, reason = "logs_undelivered")
    st.markReported("ci-s1-run-1-1", ok = false, fullyRead = false, now = 2000, reason = "outcome_unknown")
    f.pods["ci-s1-run-0-1"] = succeeded()
    f.pods["ci-s1-run-1-1"] = failed(1)
    check cfg.retentionUnread == 14 * 86400
    check st.unread().mapIt(it.name) == @["ci-s1-run-1-1", "ci-s1-run-0-1"]            # newest first
    check st.unread()[0].endReason == "outcome_unknown"
    check sweep(be, st, cfg, 1000 + 14 * 86400 - 1).expired.len == 0
    check sweep(be, st, cfg, 1000 + 14 * 86400).expired == @["ci-s1-run-0-1"]
    check sweep(be, st, cfg, 2000 + 14 * 86400).expired == @["ci-s1-run-1-1"]
    check st.unread().len == 0                                                           # a removed Pod is no longer an alert
  test "the time a fully read Pod is kept can be set, to look at it":
    var c = cfg
    c.retentionRead = 300
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, c, req(0), 100)
    f.pods["ci-s1-run-0-1"] = failed(2)
    afterPoll(st, pollRound(be, st, c, 101.0).transitions, 1000)
    check sweep(be, st, c, 1299).expired.len == 0
    check sweep(be, st, c, 1300).expired == @["ci-s1-run-0-1"]
  test "a Pod whose end is not yet reported is never swept":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["ci-s1-run-0-1"] = succeeded()
    check sweep(be, st, cfg, 99999).expired.len == 0 and f.deleted.len == 0
  test "orphans: ci- Pods the controller has no record of are removed after the grace period, other Pods are left alone":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    f.pods["ci-s1-old-0-1"] = running()
    f.created["ci-s1-old-0-1"] = 1000
    f.pods["ci-s1-new-0-1"] = running()
    f.created["ci-s1-new-0-1"] = 1950                                # younger than the grace period
    f.pods["somebody-elses-pod"] = running()
    f.created["somebody-elses-pod"] = 10
    let r = sweep(be, st, cfg, 2000)
    check r.orphans == @["ci-s1-old-0-1"]
    check "somebody-elses-pod" in f.pods and "ci-s1-new-0-1" in f.pods
  test "an unreadable pod list sweeps nothing":
    let st = openState(":memory:")
    let f = newFake()
    f.listOk = false
    f.pods["ci-s1-old-0-1"] = running()
    check sweep(backendOf(f), st, cfg, 99999).orphans.len == 0
  test "a Pod we track is never an orphan":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    check sweep(be, st, cfg, 99999).orphans.len == 0

suite "pulling the spool out of a running Pod before it is removed (the exec fallback)":
  proc frame(n: uint64): Frame = Frame(seq: n, firstLn: n * 10, lines: 10, encoding: "gzip", data: "block-" & $n & repeat("x", 3000))

  test "drain returns the blocks in order, in several small exec calls":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["ci-s1-run-0-1"] = running()
    for n in 1'u64 .. 30'u64: f.spool.add frame(n)
    let got = drainSpool(be, "ci-s1-run-0-1")
    check got.mapIt(it.seq) == (1'u64 .. 30'u64).toSeq
  test "a spool that does not start at 1 (earlier blocks were delivered by the shim itself) is drained from where it starts":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["ci-s1-run-0-1"] = running()
    for n in 6'u64 .. 25'u64: f.spool.add frame(n)
    check drainSpool(be, "ci-s1-run-0-1").mapIt(it.seq) == (6'u64 .. 25'u64).toSeq
  test "a gap inside the spool stops the drain at the gap":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["ci-s1-run-0-1"] = running()
    for n in [3'u64, 4, 5, 9, 10]: f.spool.add frame(n)
    check drainSpool(be, "ci-s1-run-0-1").mapIt(it.seq) == @[3'u64, 4, 5]
  test "damaged reads are repeated with a smaller budget, nothing is skipped or doubled":
    let st = openState(":memory:")
    let f = newFake()
    f.damageFirstReads = 2
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["ci-s1-run-0-1"] = running()
    for n in 1'u64 .. 10'u64: f.spool.add frame(n)
    check drainSpool(be, "ci-s1-run-0-1").mapIt(it.seq) == (1'u64 .. 10'u64).toSeq
  test "a Pod that is not running has nothing to pull":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["ci-s1-run-0-1"] = succeeded()
    for n in 1'u64 .. 3'u64: f.spool.add frame(n)
    check drainSpool(be, "ci-s1-run-0-1").len == 0
  test "cancel rescues first (core gets the blocks, the spool is acknowledged), then deletes the Pod":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["ci-s1-run-0-1"] = running()
    for n in 1'u64 .. 5'u64: f.spool.add frame(n)
    var delivered: seq[uint64]
    let rescue: Deliver = proc (runId: string; seq, attempt: int; frames: seq[Frame]): uint64 =
      for fr in frames: delivered.add fr.seq
      frames[^1].seq
    check cancelPod(be, st, "s1_run", 0, 1, 5, rescue) == 5
    check delivered == @[1'u64, 2, 3, 4, 5] and f.acked == 5 and f.spool.len == 0
    check f.deleted == @["ci-s1-run-0-1"]
  test "when core does not take the blocks they are not acknowledged (they stay in the spool) and the Pod is still removed":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(), 100)
    f.pods["ci-s1-run-0-1"] = running()
    for n in 1'u64 .. 3'u64: f.spool.add frame(n)
    let refuse: Deliver = proc (runId: string; seq, attempt: int; frames: seq[Frame]): uint64 = 0
    check cancelPod(be, st, "s1_run", 0, 1, 5, refuse) == 0
    check f.acked == 0 and f.spool.len == 3 and f.deleted.len == 1
