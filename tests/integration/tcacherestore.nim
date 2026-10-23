## DAT-004: the answer of a `j.cache.restore` step (core/scheduler.nim `restoredCacheKey`): the key the shim restored goes into the step's result in the journal - after the exit code and a
## newline, as the script reads it - from the newest shim state, the controller's (read from the Pod's log) or the stored one. Any other step's result stays the exit code and a newline.
## Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, times, options]
import common/[rqlite, ctrlauth, shimstate]
import core/[schema, scheduler, loggate, logcircuit]

let url = getEnv("CINIM_RQLITE_URL")
unenrolledControllers = true       # the controllers of these tests have no identity (T-46)

suite "DAT-004 the answer of a cache restore step":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let org = c.addOrganization("cr-" & sfx, "CR")
    let ns = "cinim-001-cr-" & sfx
    let prof = c.ensureOrganizationProfile(org, ns)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    proc now(): int64 = getTime().toUnix()
    proc runWithStep(opts: string): string =
      let r = co.createRun("return 1", org, prof)
      let jobId = newId()
      discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, 'job-1', 'RUNNING', ?)", jobId, r, prof]])
      discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at, attempt, claimed_at) " &
        "VALUES (?, ?, ?, 0, 'sh', 'RUNNING', ?, 'alpine', 'true', ?, '1', 1, ?)", newId(), r, jobId, prof, opts, now()]])
      r
    proc shimLine(run: string; restored: seq[string]; n = 9): string =
      $toJson(ShimState(run: run, seq: 0, attempt: 1, n: n, event: seDone, phase: spDone, cmdStarted: true, cmdExit: some(0), logs: lsDelivered, result: "success",
                        reason: "ok", exitCode: some(0), cache: restored), 1000)
    proc ends(r: string; shim: string; exit = 0) =
      discard handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-cr-" & sfx, namespace: ns, free_pod_slots: 0,
        transitions: @[PodTransition(step: StepRef(run_id: r, seq: 0, attempt: 1), state: (if exit == 0: STEP_STATE_OK else: STEP_STATE_FAILED), exit_code: int32(exit),
                                     termination_reason: "ok", shim_state_json: shim)]), push = false)
    proc journalled(r: string): string =
      let v = c.query(%*[["SELECT result FROM run_journal WHERE run_id = ? AND kind = 'job_sh'", r]])["results"][0]{"values"}
      if v != nil and v.len > 0: v[0][0].getStr else: "(none)"
    const restoreOpts = """{"cache":[{"key":"deps-2","mode":"restore","paths":[],"restore_keys":["deps-"]}]}"""

    test "a restore step answers with the key the shim restored":
      let r = runWithStep(restoreOpts)
      ends(r, shimLine(r, @["deps-1"]))
      check journalled(r) == "0\ndeps-1"
    test "a miss answers with nothing after the exit code":
      let r = runWithStep(restoreOpts)
      ends(r, shimLine(r, @[""]))
      check journalled(r) == "0\n"
    test "the shim state stored with the step is used when the transition carries none":
      let r = runWithStep(restoreOpts)
      discard c.execute(%*[["UPDATE steps SET shim_json = ? WHERE run_id = ?", shimLine(r, @["deps-7"]), r]])
      ends(r, "")
      check journalled(r) == "0\ndeps-7"
    test "the newer of the two states wins":
      let r = runWithStep(restoreOpts)
      discard c.execute(%*[["UPDATE steps SET shim_json = ? WHERE run_id = ?", shimLine(r, @["old"], n = 5), r]])
      ends(r, shimLine(r, @["new"], n = 9))
      check journalled(r) == "0\nnew"
    test "a step with the cache option, a save step and a plain step keep the result of the exit code only":
      for opts in ["""{"cache":[{"key":"k","paths":["x"],"restore_keys":[]}]}""", """{"cache":[{"key":"k","mode":"save","paths":["x"],"restore_keys":[]}]}""", ""]:
        let r = runWithStep(opts)
        ends(r, shimLine(r, @["k"]))
        check journalled(r) == "0\n"
    test "a restore step that failed answers with the exit code only":
      let r = runWithStep(restoreOpts)
      ends(r, shimLine(r, @["deps-1"]), exit = 2)
      check journalled(r) == "2\n"

suite "STO-003 the outputs of a step in its answer":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let org = c.addOrganization("so-" & sfx, "SO")
    let ns = "cinim-001-so-" & sfx
    let prof = c.ensureOrganizationProfile(org, ns)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    proc runWithStep(opts: string): string =
      let r = co.createRun("return 1", org, prof)
      let jobId = newId()
      discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, 'job-1', 'RUNNING', ?)", jobId, r, prof]])
      discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at, attempt, claimed_at) " &
        "VALUES (?, ?, ?, 0, 'sh', 'RUNNING', ?, 'alpine', 'true', ?, '1', 1, ?)", newId(), r, jobId, prof, opts, getTime().toUnix()]])
      r
    proc shimLine(run, outputs: string; exit = 0): string =
      $toJson(ShimState(run: run, seq: 0, attempt: 1, n: 9, event: seDone, phase: spDone, cmdStarted: true, cmdExit: some(exit), logs: lsDelivered, result: (if exit == 0: "success" else: "failed"),
                        reason: "ok", exitCode: some(exit), outputs: outputs), 1000)
    proc ends(r, shim: string; exit = 0) =
      discard handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-so-" & sfx, namespace: ns, free_pod_slots: 0,
        transitions: @[PodTransition(step: StepRef(run_id: r, seq: 0, attempt: 1), state: (if exit == 0: STEP_STATE_OK else: STEP_STATE_FAILED), exit_code: int32(exit),
                                     termination_reason: "ok", shim_state_json: shim)]), push = false)
    proc journalled(r: string): string =
      let v = c.query(%*[["SELECT result FROM run_journal WHERE run_id = ? AND kind = 'job_sh'", r]])["results"][0]{"values"}
      if v != nil and v.len > 0: v[0][0].getStr else: "(none)"

    test "the outputs the shim validated come after the exit code and a newline, for the script to read":
      let r = runWithStep("")
      ends(r, shimLine(r, "SHA=ab12\nTAG=20261018-ab12\n"))
      check journalled(r) == "0\nSHA=ab12\nTAG=20261018-ab12\n"
    test "a step with none answers as before, and so does one whose state carries none":
      let r = runWithStep("")
      ends(r, shimLine(r, ""))
      check journalled(r) == "0\n"
    test "a failed step carries them too (the script may have asked to go on)":
      let r = runWithStep("")
      ends(r, shimLine(r, "WHY=disk\n", exit = 3), exit = 3)
      check journalled(r) == "3\nWHY=disk\n"
    test "a cache restore step answers with its key, not with outputs":
      let r = runWithStep("""{"cache":[{"key":"deps-2","mode":"restore","paths":[],"restore_keys":["deps-"]}]}""")
      var s = ShimState(run: r, seq: 0, attempt: 1, n: 9, event: seDone, phase: spDone, cmdStarted: true, cmdExit: some(0), logs: lsDelivered, result: "success", reason: "ok", exitCode: some(0),
                        cache: @["deps-1"], outputs: "X=1\n")
      ends(r, $toJson(s, 1000))
      check journalled(r) == "0\ndeps-1"
