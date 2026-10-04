## SHD-007: a run belongs to an organisation and its steps go to the controller of that organisation only (against a real rqlite).
## Needs CINIM_RQLITE_URL (a scratch rqlite: the suite creates its own organisations and runs); otherwise the suite is skipped.
import std/[unittest, json, os]
import common/rqlite
import core/[schema, scheduler, loggate, logcircuit]

let url = getEnv("CINIM_RQLITE_URL")

proc addStep(c: var RqClient; runId, profileId: string) =
  ## what a host call of the executor leaves behind: a pending step in the profile of the run
  let jobId = newId()
  discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, 'j', 'RUNNING', ?)", jobId, runId, profileId]])
  discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at) " &
    "VALUES (?, ?, ?, 1, 'sh', 'PENDING', ?, 'alpine', 'true', '', ?)", newId(), runId, jobId, profileId, "1"]])

suite "SHD-007 runs and controllers per organisation":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))      # no log circuit in this test: the launch gate stays open
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let orgA = c.addOrganization("a-" & sfx, "A")
    let orgB = c.addOrganization("b-" & sfx, "B")
    let nsA = "cinim-001-a-" & sfx
    let nsB = "cinim-001-b-" & sfx
    let profA = c.ensureOrganizationProfile(orgA, nsA)
    let profB = c.ensureOrganizationProfile(orgB, nsB)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")

    test "an organisation has one profile of its own, placing its steps in its namespace":
      check profA != profB and profA != defaultProfile
      check c.ensureOrganizationProfile(orgA, nsA) == profA            # asking again returns the same one
      check c.profileOfNamespace(nsA) == profA and c.profileOfNamespace(nsB) == profB
      check c.profileOfNamespace("no-such-namespace") == ""
    test "a run keeps the organisation and the profile it was made with":
      let r = co.createRun("p", "return 1", orgA, profA)
      check c.profileOfRun(r, "x") == profA
      let j = co.getRun(r)
      check j["organization"].getStr == "a-" & sfx
      let legacy = co.createRun("p", "return 1")                        # no organisation: the default tenant and profile
      check c.profileOfRun(legacy, "x") == defaultProfile and co.getRun(legacy)["organization"].getStr == ""
    test "a controller gets the steps of its own namespace and of no other":
      let ra = co.createRun("p", "return 1", orgA, profA)
      let rb = co.createRun("p", "return 1", orgB, profB)
      c.addStep(ra, profA)
      c.addStep(rb, profB)
      let forB = handlePoll(c, defaultProfile, PollRequest(session_id: "jc-b-" & sfx, namespace: nsB, free_pod_slots: 10))
      var runsB: seq[string]
      for cmd in forB.commands:
        if cmd.body.kind == CommandBodyKind.start: runsB.add cmd.body.start.step.run_id
      check rb in runsB and ra notin runsB
      let forA = handlePoll(c, defaultProfile, PollRequest(session_id: "jc-a-" & sfx, namespace: nsA, free_pod_slots: 10))
      var runsA: seq[string]
      for cmd in forA.commands:
        if cmd.body.kind == CommandBodyKind.start: runsA.add cmd.body.start.step.run_id
      check ra in runsA and rb notin runsA
    test "a controller of a namespace without a profile gets nothing":
      let r = co.createRun("p", "return 1", orgA, profA)
      c.addStep(r, profA)
      let resp = handlePoll(c, defaultProfile, PollRequest(session_id: "jc-x-" & sfx, namespace: "elsewhere-" & sfx, free_pod_slots: 10))
      for cmd in resp.commands: check cmd.body.kind != CommandBodyKind.start
    test "deleting an organisation takes its profile along":
      c.deleteOrganization("b-" & sfx)
      check c.profileOfNamespace(nsB) == ""
      c.deleteOrganization("a-" & sfx)
