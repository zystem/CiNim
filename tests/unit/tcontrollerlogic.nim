## The job-controller's decisions against a fake cluster (D-29): no Kubernetes, no ZeroMQ.
import std/[unittest, json, tables, options, strutils, os, sequtils]
import common/spoolwire
import common/shimstate
import jobcontroller/[backend, ctrlstate, logic]

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

proc newFake(): Fake = Fake(listOk: true)

proc backendOf(f: Fake): Backend =
  Backend(
    createPod: proc (r: PodRequest): bool =
      f.creates.add r
      f.pods[r.name] = %*{"status": {"phase": "Pending"}}
      f.created[r.name] = 1000
      true,
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
    be.createPod = proc (r: PodRequest): bool =
      seenRowBeforeCreate = st.has(r.name)
      true
    check startPod(be, st, cfg, req(), 100)
    check seenRowBeforeCreate

suite "the poll round":
  test "a running Pod is in the inventory, an unseen one is not 'started'":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    check startPod(be, st, cfg, req(), 100)
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
  test "finished Pods are kept: a success for a short time, a failure for long":
    let st = openState(":memory:")
    let f = newFake()
    let be = backendOf(f)
    discard startPod(be, st, cfg, req(0), 100)
    discard startPod(be, st, cfg, req(1), 100)
    f.pods["ci-s1-run-0-1"] = succeeded()
    f.pods["ci-s1-run-1-1"] = failed(1)
    afterPoll(st, pollRound(be, st, cfg, 101.0).transitions, 1000)
    check sweep(be, st, cfg, 1000 + 599).expired.len == 0           # nothing yet
    check sweep(be, st, cfg, 1000 + 600).expired == @["ci-s1-run-0-1"]   # the success after 10 minutes
    check sweep(be, st, cfg, 1000 + 6 * 3600 - 1).expired.len == 0
    check sweep(be, st, cfg, 1000 + 6 * 3600).expired == @["ci-s1-run-1-1"]
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
