## STO-002: a job with `workspace = "isolated"` has a volume of its own. The core names it to the controller: `StartStep.volume` and `DrainStep.volume` are the id of the job, "" for the
## run's volume. Against a real rqlite; needs CINIM_RQLITE_URL.
import std/[unittest, json, os, times, tables]
import common/[rqlite, ctrlauth, stepenv]
import core/[schema, scheduler, loggate, logcircuit, drains]

let url = getEnv("CINIM_RQLITE_URL")
unenrolledControllers = true

suite "STO-002 the volume of a job in the core":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let org = c.addOrganization("ws-" & sfx, "WS")
    let ns = "cinim-001-ws-" & sfx
    let prof = c.ensureOrganizationProfile(org, ns)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    var polls = 0
    proc addStep(runId, opts: string; ordinal: int): string =
      ## a job and its step, as a host call leaves them; returns the id of the job
      let jobId = newId()
      discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, ?, 'RUNNING', ?)", jobId, runId, "job-" & $ordinal, prof]])
      discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at) " &
        "VALUES (?, ?, ?, ?, 'sh', 'PENDING', ?, 'alpine', 'true', ?, '1')", newId(), runId, jobId, ordinal, prof, opts]])
      jobId
    proc poll(): PollResponse =
      inc polls
      handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-ws-" & $polls & sfx, namespace: ns, free_pod_slots: 10))

    test "the options say it: isolatedWorkspace":
      check isolatedWorkspace("""{"workspace":"isolated"}""") and isolatedWorkspace("""{"env":{"A":"1"},"workspace":"isolated"}""")
      check not isolatedWorkspace("") and not isolatedWorkspace("""{"workspace":"shared"}""") and not isolatedWorkspace("{not json")
    test "a step of an isolated job is started with the id of its job as the volume, one of a shared job with none":
      let r = co.createRun("return 1", org, prof)
      let isolated = addStep(r, """{"workspace":"isolated"}""", 0)
      discard addStep(r, "", 1)
      let resp = poll()
      var vols: Table[int, string]
      for cmd in resp.commands:
        if cmd.body.kind == CommandBodyKind.start and cmd.body.start.step.run_id == r: vols[int(cmd.body.start.step.seq)] = cmd.body.start.volume
      check vols.len == 2 and vols[0] == isolated and vols[1] == ""
    test "the drain of a step of an isolated job is ordered with the volume of the job":
      let r = co.createRun("return 1", org, prof)
      let isolated = addStep(r, """{"workspace":"isolated","artifacts":{"upload":["dist/**"]}}""", 0)
      discard c.execute(%*[["UPDATE steps SET state = 'SUCCEEDED', attempt = 1 WHERE run_id = ? AND ordinal = 0", r]])
      c.noteUndelivered(r, 0, 1, "artifacts_undelivered", 0, getTime().toUnix())
      let resp = poll()
      var found = false
      for d in resp.drain_steps:
        if d.step.run_id == r:
          found = true
          check d.volume == isolated
      check found
