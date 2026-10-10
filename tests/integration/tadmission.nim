## RUN-004: the steps of an organisation are handed to its controller within pod_limit and job_pod_limit, the run with the fewest steps in
## flight first (against a real rqlite). Needs CINIM_RQLITE_URL (a scratch rqlite: the suite makes its own organisation); otherwise the suite is skipped.
import std/[unittest, json, os, sequtils]
import common/rqlite
import core/[schema, scheduler, loggate, logcircuit, retrypolicy]

let url = getEnv("CINIM_RQLITE_URL")

proc addStep(c: var RqClient; runId, profileId: string; ordinal: int; queuedAt: int; state = "PENDING") =
  ## what a host call of the executor leaves behind: a step of the run, in the given state
  let jobId = newId()
  discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, ?, 'RUNNING', ?)", jobId, runId, "j" & $ordinal, profileId]])
  discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, journal_seq, type, state, profile_id, image, command, opts, queued_at) " &
    "VALUES (?, ?, ?, ?, ?, 'sh', ?, ?, 'alpine', 'true', '', ?)", newId(), runId, jobId, ordinal, ordinal, state, profileId, $queuedAt]])

proc handedOut(resp: PollResponse): seq[string] =
  for cmd in resp.commands:
    if cmd.body.kind == CommandBodyKind.start: result.add cmd.body.start.step.run_id

suite "RUN-004 the limits of an organisation and of a run":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    var n = 0
    proc newOrg(podLimit, percent: int): tuple[profile, ns: string] =
      inc n
      let org = c.addOrganization("lim" & $n & "-" & sfx, "L")
      let ns = "cinim-001-lim" & $n & "-" & sfx
      let prof = c.ensureOrganizationProfile(org, ns)
      var s = defaultSettings()
      s.podLimit = podLimit
      s.jobPodLimitPercent = percent
      co.setProfileSettings(s, prof)
      (prof, ns)
    proc poll(ns: string; slots: int): PollResponse =
      inc n
      handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-" & $n & "-" & sfx, namespace: ns, free_pod_slots: uint32(slots)))

    test "the settings are stored in the profile, with the defaults 20 and 20 percent":
      let o = newOrg(20, 20)
      let got = co.getProfileSettings(o.profile)
      check got["pod_limit"].getInt == 20 and got["job_pod_limit_percent"].getInt == 20
      var s = defaultSettings()
      s.podLimit = 7
      s.jobPodLimitPercent = 50
      co.setProfileSettings(s, o.profile)
      check co.getProfileSettings(o.profile)["pod_limit"].getInt == 7
      check co.getProfileSettings(o.profile)["job_pod_limit_percent"].getInt == 50
    test "a run does not get more than its share, however many steps wait and however many slots the controller has":
      let o = newOrg(20, 20)                       # a run may hold 4
      let r = co.createRun("p", "return 1", "t1", o.profile)
      for i in 1 .. 10: c.addStep(r, o.profile, i, i)
      check poll(o.ns, 100).handedOut.len == 4
      check poll(o.ns, 100).handedOut.len == 0     # the four are in flight; nothing more for this run
    test "the organisation does not get more than its limit, spread across its runs":
      let o = newOrg(6, 100)                       # a run may hold all 6, the organisation 6
      let ra = co.createRun("p", "return 1", "t1", o.profile)
      let rb = co.createRun("p", "return 1", "t1", o.profile)
      for i in 1 .. 8: c.addStep(ra, o.profile, i, i)
      for i in 1 .. 8: c.addStep(rb, o.profile, i, 100 + i)
      let got = poll(o.ns, 100).handedOut
      check got.len == 6
      check got.count(ra) == 3 and got.count(rb) == 3      # the places are shared, not given to the run that asked first
      check poll(o.ns, 100).handedOut.len == 0
    test "a finished step frees its place":
      let o = newOrg(2, 100)
      let r = co.createRun("p", "return 1", "t1", o.profile)
      for i in 1 .. 4: c.addStep(r, o.profile, i, i)
      check poll(o.ns, 100).handedOut.len == 2
      discard c.execute(%*[["UPDATE steps SET state = 'SUCCEEDED' WHERE run_id = ? AND state = 'STARTING' AND ordinal = 1", r]])
      check poll(o.ns, 100).handedOut.len == 1
    test "the run with the fewest steps in flight goes first":
      let o = newOrg(10, 100)
      let busy = co.createRun("p", "return 1", "t1", o.profile)
      let idle = co.createRun("p", "return 1", "t1", o.profile)
      for i in 1 .. 3: c.addStep(busy, o.profile, i, i, "RUNNING")
      c.addStep(busy, o.profile, 4, 1)             # the oldest waiting step is the busy run's
      c.addStep(idle, o.profile, 1, 50)
      let got = poll(o.ns, 1).handedOut
      check got == @[idle]
    test "the controller's free slots still bound one poll":
      let o = newOrg(20, 100)
      let r = co.createRun("p", "return 1", "t1", o.profile)
      for i in 1 .. 5: c.addStep(r, o.profile, i, i)
      check poll(o.ns, 2).handedOut.len == 2
    test "another organisation's limit does not touch this one":
      let a = newOrg(1, 100)
      let b = newOrg(20, 100)
      let ra = co.createRun("p", "return 1", "t1", a.profile)
      let rb = co.createRun("p", "return 1", "t1", b.profile)
      for i in 1 .. 3: c.addStep(ra, a.profile, i, i)
      for i in 1 .. 3: c.addStep(rb, b.profile, i, i)
      check poll(a.ns, 10).handedOut.len == 1
      check poll(b.ns, 10).handedOut.len == 3
