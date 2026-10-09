## SHD-007: a run belongs to an organisation and its steps go to the controller of that organisation only (against a real rqlite).
## Needs CINIM_RQLITE_URL (a scratch rqlite: the suite creates its own organisations and runs); otherwise the suite is skipped.
import std/[unittest, json, os]
import common/rqlite
import std/times
import common/ctrlauth
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
      let forB = handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-b-" & sfx, namespace: nsB, free_pod_slots: 10))
      var runsB: seq[string]
      for cmd in forB.commands:
        if cmd.body.kind == CommandBodyKind.start: runsB.add cmd.body.start.step.run_id
      check rb in runsB and ra notin runsB
      let forA = handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-a-" & sfx, namespace: nsA, free_pod_slots: 10))
      var runsA: seq[string]
      for cmd in forA.commands:
        if cmd.body.kind == CommandBodyKind.start: runsA.add cmd.body.start.step.run_id
      check ra in runsA and rb notin runsA
    test "every answer to a poll carries the settings of the shard, from the core's own environment (ControllerConfig)":
      putEnv("CINIM_BUILD", "on")
      putEnv("CINIM_BUILD_SECCOMP", "Localhost")
      putEnv("CINIM_RUN_STORAGE", "on")
      putEnv("CINIM_RUN_STORAGE_SIZE", "3Gi")
      putEnv("CINIM_COLLECTOR_ADDR", "tcp://core.test:19743")
      putEnv("CINIM_POD_RETENTION_UNREAD", "3600")
      let resp = handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-cfg-" & sfx, namespace: nsA, free_pod_slots: 0))
      check resp.config.present and resp.config.build_enabled and resp.config.build_seccomp == "Localhost"
      check resp.config.run_storage_enabled and resp.config.run_storage_size == "3Gi" and resp.config.run_storage_class == ""
      check resp.config.collector_addr == "tcp://core.test:19743" and resp.config.log_ingest_addr == "tcp://core.test:19743"
      check resp.config.log_spool_bytes == 10485760 and resp.config.log_hold_timeout_seconds == 600 and resp.config.pod_retention_unread_seconds == 3600
      delEnv("CINIM_BUILD"); delEnv("CINIM_BUILD_SECCOMP"); delEnv("CINIM_RUN_STORAGE"); delEnv("CINIM_RUN_STORAGE_SIZE"); delEnv("CINIM_COLLECTOR_ADDR"); delEnv("CINIM_POD_RETENTION_UNREAD")
      let plain = handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-cfg2-" & sfx, namespace: nsA, free_pod_slots: 0))
      check plain.config.present and not plain.config.build_enabled and not plain.config.run_storage_enabled
    test "a controller of a namespace without a profile gets nothing":
      let r = co.createRun("p", "return 1", orgA, profA)
      c.addStep(r, profA)
      let resp = handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-x-" & sfx, namespace: "elsewhere-" & sfx, free_pod_slots: 10))
      for cmd in resp.commands: check cmd.body.kind != CommandBodyKind.start
    test "a namespace with a controller identity serves only a controller that proves it (IAM-003, T-46)":
      let orgC = c.addOrganization("c-" & sfx, "C")
      let nsC = "cinim-001-c-" & sfx
      let profC = c.ensureOrganizationProfile(orgC, nsC)
      c.ensureCredentialRow(nsC, getTime().toUnix() + 3600)
      let rc = co.createRun("p", "return 1", orgC, profC)
      c.addStep(rc, profC)
      proc startsIn(resp: PollResponse): seq[string] =
        for cmd in resp.commands:
          if cmd.body.kind == CommandBodyKind.start: result.add cmd.body.start.step.run_id
      # no proof: refused, nothing assigned, nothing recorded
      let none = handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-c-" & sfx, namespace: nsC, free_pod_slots: 10))
      check none.unauthorized and none.commands.len == 0 and none.issued_credential == ""
      # a token of another namespace, and a made-up credential: refused
      check handlePoll(c, defaultProfile, "master", PollRequest(session_id: "x", namespace: nsC, free_pod_slots: 10,
        bootstrap_token: bootstrapToken("master", nsB, 1))).unauthorized
      check handlePoll(c, defaultProfile, "master", PollRequest(session_id: "x", namespace: nsC, free_pod_slots: 10,
        credential: "made-up")).unauthorized
      # the bootstrap token is exchanged for the credential; that poll assigns nothing
      let issued = handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-c-" & sfx, namespace: nsC, free_pod_slots: 10,
        bootstrap_token: bootstrapToken("master", nsC, 1)))
      check not issued.unauthorized and issued.issued_credential == controllerCredential("master", nsC, 1) and issued.commands.len == 0
      check not c.credentialRow(nsC).confirmed
      # with the credential the steps of the namespace are assigned, and the identity is recorded as in use
      let served = handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-c-" & sfx, namespace: nsC, free_pod_slots: 10,
        credential: issued.issued_credential))
      check rc in startsIn(served)
      check c.credentialRow(nsC).confirmed
      # the bootstrap token is spent now
      check handlePoll(c, defaultProfile, "master", PollRequest(session_id: "x", namespace: nsC, free_pod_slots: 10,
        bootstrap_token: bootstrapToken("master", nsC, 1))).unauthorized
      # the credential of namespace C is no credential for namespace B's controller identity row (B has none: legacy), and a
      # rotation locks the old credential out
      c.rotateCredential(nsC, getTime().toUnix() + 3600)
      check handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-c-" & sfx, namespace: nsC, free_pod_slots: 10,
        credential: issued.issued_credential)).unauthorized
      check handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-c-" & sfx, namespace: nsC, free_pod_slots: 10,
        bootstrap_token: bootstrapToken("master", nsC, 2))).issued_credential == controllerCredential("master", nsC, 2)
      c.deleteCredentialRow(nsC)
      c.deleteOrganization("c-" & sfx)
    test "a build step stays with the organisation's controller and reaches it as a build step (D-42)":
      let orgD = c.addOrganization("d-" & sfx, "D")
      let nsD = "cinim-001-d-" & sfx
      let profD = c.ensureOrganizationProfile(orgD, nsD)
      let rd = co.createRun("p", "return 1", orgD, profD)
      var withBuild = co
      withBuild.orgPrefix = "cinim"
      withBuild.orgShard = "001"
      withBuild.buildOn = true
      proc call(core: Core; run, profile: string; seq: uint64): ExecutorResponse =
        handleCall(c, core, HostCall(run_id: run, seq: seq, kind: "job_sh",
          payload: cast[seq[byte]]("job-1\tkaniko\t" & profile & "\t\techo build")))
      check call(withBuild, rd, "", 0).body.kind == ExecutorResponseBodyKind.result
      check call(withBuild, rd, "build", 1).body.kind == ExecutorResponseBodyKind.result
      # one profile, one namespace: both steps belong to it and the second one says what it is
      let rows = c.query(%*[["SELECT ordinal, profile_id, profile FROM steps WHERE run_id = ? ORDER BY ordinal", rd]])["results"][0]["values"]
      check rows[0][1].getStr == profD and rows[0][2].getStr == ""
      check rows[1][1].getStr == profD and rows[1][2].getStr == "build"
      let resp = handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-d-" & sfx, namespace: nsD, free_pod_slots: 10))
      var profiles: seq[string]
      for cmd in resp.commands:
        if cmd.body.kind == CommandBodyKind.start: profiles.add cmd.body.start.profile
      check profiles.len == 2 and "build" in profiles and "" in profiles      # claimed by queue time, which two steps may share
      # a shard without a build profile, and a run without an organisation, refuse it
      check call(co, rd, "build", 2).body.kind == ExecutorResponseBodyKind.failure
      let legacy = co.createRun("p", "return 1")
      check call(withBuild, legacy, "build", 0).body.kind == ExecutorResponseBodyKind.failure
      c.deleteOrganization("d-" & sfx)
    test "deleting an organisation takes its profile along":
      c.deleteOrganization("b-" & sfx)
      check c.profileOfNamespace(nsB) == ""
      c.deleteOrganization("a-" & sfx)
