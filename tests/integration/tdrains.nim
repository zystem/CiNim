## DAT-003, D-27: what a step left on the run's volume because the shim could not hand it to the core (core/drains.nim), against a real rqlite. The core remembers the step, names the
## order to its organisation's controller in every answer until the controller says it is done, waits after a failure that may pass, gives up after a day, keeps the run's volume
## meanwhile and lets the ArtifactIngest take the files of a step that has ended. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, times, options]
import common/[rqlite, ctrlauth, shimstate]
import core/[schema, scheduler, loggate, logcircuit, runstorage, drains]

let url = getEnv("CINIM_RQLITE_URL")
unenrolledControllers = true       # the controllers of these tests have no identity (T-46)

suite "DAT-003 the drain of a step's leavings":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let org = c.addOrganization("d-" & sfx, "D")
    let ns = "cinim-001-d-" & sfx
    let prof = c.ensureOrganizationProfile(org, ns)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    putEnv("CINIM_RUN_STORAGE", "on")
    putEnv("CINIM_STORAGE_RETENTION_SUCCEEDED", "0")
    runstorage.coreStartedAt = 0
    proc now(): int64 = getTime().toUnix()
    const uploads = """{"artifacts":{"upload":["dist/**"]}}"""
    proc runWithStep(opts: string): string =
      let r = co.createRun("p", "return 1", org, prof)
      let jobId = newId()
      discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, 'job-1', 'RUNNING', ?)", jobId, r, prof]])
      discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at, attempt, claimed_at) " &
        "VALUES (?, ?, ?, 0, 'sh', 'RUNNING', ?, 'alpine', 'true', ?, '1', 1, ?)", newId(), r, jobId, prof, opts, now()]])
      r
    proc poll(transitions: seq[PodTransition] = @[]; drained: seq[StepDrained] = @[]; released: seq[string] = @[]; push = false): PollResponse =
      handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-d-" & sfx, namespace: ns, free_pod_slots: 0, transitions: transitions, steps_drained: drained, storage_released: released), push = push)
    proc ends(r, reason: string; exit = 0; shim = ""): PollResponse =
      poll(@[PodTransition(step: StepRef(run_id: r, seq: 0, attempt: 1), state: (if exit == 0: STEP_STATE_SUCCEEDED else: STEP_STATE_FAILED), exit_code: int32(exit),
                           termination_reason: reason, shim_state_json: shim)])
    proc podLog(run: string; exit: int; reason: string; logs: LogsState; arts: ArtifactsState): string =
      ## the last line of the shim in the Pod's log, which the controller sends when the core never heard the shim (it was away)
      $toJson(ShimState(run: run, seq: 0, attempt: 1, n: 9, event: seDone, phase: spDone, cmdStarted: true, cmdExit: some(exit), logs: logs, artifacts: arts,
                        result: (if exit == 0: "success" else: "failed"), reason: reason, exitCode: some(if reason == "logs_undelivered": 72 else: exit)), 1000)
    proc orderOf(resp: PollResponse; r: string): seq[DrainStep] =
      for d in resp.drain_steps:
        if d.step.run_id == r: result.add d
    proc clean() = discard c.execute(%*[["UPDATE step_drains SET state = 'done' WHERE profile_id = ? AND state = 'pending'", prof]])      # a poll names a few drains at a time: the ones of other tests would crowd this one out
    proc setRun(r, state: string) = discard c.execute(%*[["UPDATE runs SET state = ?, updated_at = ? WHERE id = ?", state, $(now() - 5), r]])

    test "a step that ended artifacts_undelivered is named to its controller, with the step's credential, until the controller says it is done":
      clean()
      let r = runWithStep(uploads)
      let first = ends(r, "artifacts_undelivered")
      let o = first.orderOf(r)
      check o.len == 1 and o[0].artifacts and not o[0].logs and o[0].image == "alpine"
      check o[0].step_token == stepToken("master", r, 0, 1)
      check poll().orderOf(r).len == 1                 # named again: a lost answer costs nothing
      check c.isDraining(r, 0, 1)
      discard poll(drained = @[StepDrained(step: StepRef(run_id: r, seq: 0, attempt: 1), ok: true)])
      check poll().orderOf(r).len == 0 and not c.isDraining(r, 0, 1)
    test "a step whose log was not delivered is named with logs, and with artifacts too when it declared some":
      clean()
      let a = runWithStep("")
      let b = runWithStep(uploads)
      discard ends(a, "logs_undelivered")
      let resp = ends(b, "logs_undelivered")
      check resp.orderOf(a).len == 1 and resp.orderOf(a)[0].logs and not resp.orderOf(a)[0].artifacts
      check resp.orderOf(b).len == 1 and resp.orderOf(b)[0].logs and resp.orderOf(b)[0].artifacts
    test "D-53 a core that never heard the shim restores it from the Pod's log: the log and the artifacts both undelivered, only the log, only the artifacts":
      clean()
      let both = runWithStep(uploads)
      let onlyLog = runWithStep(uploads)
      let onlyArts = runWithStep(uploads)
      discard ends(both, "logs_undelivered", shim = podLog(both, 0, "logs_undelivered", lsUndelivered, asUndelivered))
      discard ends(onlyLog, "logs_undelivered", shim = podLog(onlyLog, 0, "logs_undelivered", lsUndelivered, asDelivered))
      let resp = ends(onlyArts, "artifacts_undelivered", shim = podLog(onlyArts, 0, "artifacts_undelivered", lsDelivered, asUndelivered))
      check resp.orderOf(both)[0].logs and resp.orderOf(both)[0].artifacts
      check resp.orderOf(onlyLog)[0].logs and not resp.orderOf(onlyLog)[0].artifacts       # declared, but the Pod's log says they were delivered
      check not resp.orderOf(onlyArts)[0].logs and resp.orderOf(onlyArts)[0].artifacts
    test "D-53 a command that failed has a log to fetch and no artifacts, whether the Pod's log says so or the core has only the exit code":
      clean()
      let withLog = runWithStep(uploads)
      let bare = runWithStep(uploads)
      discard ends(withLog, "logs_undelivered", exit = 3, shim = podLog(withLog, 3, "logs_undelivered", lsUndelivered, asNone))
      let resp = ends(bare, "logs_undelivered", exit = 3)
      check resp.orderOf(withLog)[0].logs and not resp.orderOf(withLog)[0].artifacts
      check resp.orderOf(bare)[0].logs and not resp.orderOf(bare)[0].artifacts
    test "a step that ended well, or failed on its own, leaves nothing to drain":
      clean()
      let ok = runWithStep(uploads)
      let bad = runWithStep(uploads)
      discard ends(ok, "ok")
      let resp = ends(bad, "failed", 3)
      check resp.orderOf(ok).len == 0 and resp.orderOf(bad).len == 0
    test "a failure that may pass is not ordered again at once; a failure for good ends it":
      clean()
      let r = runWithStep(uploads)
      discard ends(r, "artifacts_undelivered")
      let soon = poll(drained = @[StepDrained(step: StepRef(run_id: r, seq: 0, attempt: 1), detail: "store_unavailable")])
      check soon.orderOf(r).len == 0 and c.isDraining(r, 0, 1)
      discard c.execute(%*[["UPDATE step_drains SET next_at = 0 WHERE run_id = ?", r]])      # the wait is over
      check poll().orderOf(r).len == 1
      discard poll(drained = @[StepDrained(step: StepRef(run_id: r, seq: 0, attempt: 1), final: true, detail: "the volume is gone")])
      check poll().orderOf(r).len == 0 and not c.isDraining(r, 0, 1)
      check c.query(%*[["SELECT state, detail FROM step_drains WHERE run_id = ?", r]])["results"][0]["values"][0] == %*["failed", "the volume is gone"]
    test "a drain that has been tried for a day is given up":
      clean()
      let r = runWithStep(uploads)
      discard ends(r, "artifacts_undelivered")
      discard c.execute(%*[["UPDATE step_drains SET created_at = ? WHERE run_id = ?", now() - 2 * 86400, r]])
      check poll().orderOf(r).len == 0 and not c.isDraining(r, 0, 1)
    test "the volume of a run with a drain under way is kept, and released once it is done":
      clean()
      let r = runWithStep(uploads)
      discard ends(r, "artifacts_undelivered")
      setRun(r, "SUCCEEDED")
      check r notin poll(released = @["s1_nothing"]).release_storage       # a poll that carries an answer looks at once (see trunstorage)
      discard poll(drained = @[StepDrained(step: StepRef(run_id: r, seq: 0, attempt: 1), ok: true)])
      check r in poll(released = @["s1_nothing"]).release_storage
    test "another organisation's controller is not told, and the push channel names no drains of its own":
      clean()
      let r = runWithStep(uploads)
      discard ends(r, "artifacts_undelivered")
      let other = handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-o-" & sfx, namespace: "cinim-001-nobody-" & sfx, free_pod_slots: 0))
      check other.orderOf(r).len == 0
      check poll(push = true).orderOf(r).len == 0
    test "no orders when the shard has no run volumes: there is nothing on a volume to fetch":
      clean()
      putEnv("CINIM_RUN_STORAGE", "off")
      let r = runWithStep(uploads)
      check ends(r, "artifacts_undelivered").orderOf(r).len == 0
      putEnv("CINIM_RUN_STORAGE", "on")
