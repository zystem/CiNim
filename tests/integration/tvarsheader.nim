## VAR-005: the core names the variables for the first step of a run only (CICD_VARIABLES), so that its shim prints the header (shim/varsheader.nim). Against a real rqlite.
## Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, sequtils, times]
import common/rqlite
import core/[schema, scheduler, loggate, logcircuit, orgvars]

let url = getEnv("CINIM_RQLITE_URL")
unenrolledControllers = true       # the controller of this test has no identity (T-46)

suite "VAR-005 which step names the variables":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    var n = 0
    proc newOrg(): tuple[id, profile, ns: string] =
      inc n
      let slug = "vh" & $n & "-" & sfx
      let id = c.addOrganization(slug, "V")
      let ns = "cinim-001-" & slug
      (id, c.ensureOrganizationProfile(id, ns), ns)
    proc addStep(run, profile: string; ordinal: int) =
      let jobId = newId()
      discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, ?, 'RUNNING', ?)", jobId, run, "j" & $ordinal, profile]])
      discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at) VALUES (?, ?, ?, ?, 'sh', 'PENDING', ?, 'alpine', 'true', '', ?)",
        newId(), run, jobId, ordinal, profile, $ordinal]])
    proc poll(ns: string; slots = 1): seq[tuple[ordinal: int, env: seq[string]]] =
      inc n
      let resp = handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-" & $n & "-" & sfx, namespace: ns, free_pod_slots: uint32(slots)))
      for cmd in resp.commands:
        if cmd.body.kind == CommandBodyKind.start:
          result.add (int(cmd.body.start.step.seq), cmd.body.start.env.mapIt(it.key & "=" & it.value))

    test "the first step of the run gets the list of the names, the next ones do not":
      let o = newOrg()
      check c.setVariable(o.id, "REGION", "eu", getTime().toUnix()) == ""
      let r = co.createRun("p", "return 1", o.id, o.profile, @[("TARGET", "staging")])
      addStep(r, o.profile, 0)
      addStep(r, o.profile, 1)
      let first = poll(o.ns)
      check first.len == 1 and first[0].ordinal == 0
      check "CICD_VARIABLES=REGION,TARGET" in first[0].env and "REGION=eu" in first[0].env and "TARGET=staging" in first[0].env
      sleep 1100
      let second = poll(o.ns)
      check second.len == 1 and second[0].ordinal == 1
      check second[0].env.filterIt(it.startsWith("CICD_VARIABLES")).len == 0 and "REGION=eu" in second[0].env
    test "a run with no variables and no parameters has no header to print":
      let o = newOrg()
      let r = co.createRun("p", "return 1", o.id, o.profile)
      addStep(r, o.profile, 0)
      let got = poll(o.ns)
      check got.len == 1 and got[0].env.len == 0
    test "a step that is run again (a new attempt) does not print the header again":
      let o = newOrg()
      check c.setVariable(o.id, "A", "1", getTime().toUnix()) == ""
      let r = co.createRun("p", "return 1", o.id, o.profile)
      addStep(r, o.profile, 0)
      check poll(o.ns).len == 1
      discard c.execute(%*[["UPDATE steps SET state = 'PENDING', attempt = 2, claimed_at = 0 WHERE run_id = ?", r]])
      let again = poll(o.ns)
      check again.len == 1 and again[0].env.filterIt(it.startsWith("CICD_VARIABLES")).len == 0
