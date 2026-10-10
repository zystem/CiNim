## RUN-004 / RUN-008 / docs/conductors.md section 4: what the core leases to a conductor of an organisation: only that organisation's runs, only
## versions the conductor runs, within its free places, and new runs only while the organisation has fewer active runs than its pod_limit.
## Needs CINIM_RQLITE_URL (a scratch rqlite: the suite makes its own organisations); otherwise the suite is skipped.
import std/[unittest, json, os, sequtils]
import common/rqlite
import core/[schema, scheduler, loggate, logcircuit, retrypolicy]

let url = getEnv("CINIM_RQLITE_URL")

suite "RUN-004 leases to a conductor":
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
    proc newOrg(podLimit = 20): string =
      inc n
      let org = c.addOrganization("cl" & $n & "-" & sfx, "C")
      let prof = c.ensureOrganizationProfile(org, "cinim-001-cl" & $n & "-" & sfx)
      var s = defaultSettings()
      s.podLimit = podLimit
      co.setProfileSettings(s, prof)
      prof
    proc lease(profile, owner: string; places: int; versions = @[1]): seq[string] =
      for g in c.leaseForConductor(profile, "master", owner, versions, places): result.add g.run_id

    test "a conductor gets the runs of its own organisation and no other's":
      let a = newOrg()
      let b = newOrg()
      let ra = co.createRun("p", "return 1", "t1", a)
      let rb = co.createRun("p", "return 1", "t1", b)
      check lease(a, "c-a", 5) == @[ra]
      check lease(b, "c-b", 5) == @[rb]
    test "no more runs than the conductor has free places":
      let a = newOrg()
      var ids: seq[string]
      for i in 0 ..< 5: ids.add co.createRun("p", "return 1", "t1", a)
      let got = lease(a, "c-a", 3)
      check got.len == 3 and got == ids[0 .. 2]                 # the oldest first
      check lease(a, "c-a", 0).len == 0
    test "a lease carries the token, the script, the parameters and the version of the API":
      let a = newOrg()
      let r = co.createRun("p", "return 42", "t1", a, @[("KEY", "v")])
      let g = c.leaseForConductor(a, "master", "c-a", @[1], 1)
      check g.len == 1 and g[0].run_id == r and g[0].script == "return 42"
      check g[0].lease_token.len > 0 and g[0].params.len == 1 and g[0].params[0].key == "KEY" and g[0].api_version == 1
    test "a run of a version the conductor cannot run is not leased to it":
      let a = newOrg()
      let r = co.createRun("p", "return 1", "t1", a)
      discard c.execute(%*[["UPDATE runs SET api_version = 9 WHERE id = ?", r]])
      check lease(a, "c-a", 5, versions = @[1, 2, 3]).len == 0
      check lease(a, "c-a", 5, versions = @[8, 9]) == @[r]
    test "new runs are leased only while the organisation has fewer active runs than its pod_limit":
      let a = newOrg(podLimit = 2)
      var ids: seq[string]
      for i in 0 ..< 4: ids.add co.createRun("p", "return 1", "t1", a)
      check lease(a, "c-a", 10) == ids[0 .. 1]                  # two places of the organisation
      check c.activeRuns(a) == 2
      check lease(a, "c-a", 10).len == 0                        # both are held (or waiting for a step): the others wait in the queue of runs
      discard c.execute(%*[["UPDATE runs SET state = 'SUCCEEDED', lease_until = 0 WHERE id = ?", ids[0]]])
      check lease(a, "c-a", 10) == @[ids[2]]                    # a place is free again
    test "a run that was led and waits for its step goes back to a conductor without a new place":
      let a = newOrg(podLimit = 1)
      let r1 = co.createRun("p", "return 1", "t1", a)
      let r2 = co.createRun("p", "return 1", "t1", a)
      check lease(a, "c-a", 5) == @[r1]
      discard c.execute(%*[["UPDATE runs SET lease_until = 0 WHERE id = ?", r1]])    # suspended, given back
      check lease(a, "c-a", 5) == @[r1]                          # again r1 - it holds the place; r2 still waits
      check lease(a, "c-a", 5).len == 0
      check r2.len > 0
    test "a run with a step in flight is not offered":
      let a = newOrg()
      let r = co.createRun("p", "return 1", "t1", a)
      let jobId = newId()
      discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, 'j', 'RUNNING', ?)", jobId, r, a]])
      discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at) " &
        "VALUES (?, ?, ?, 1, 'sh', 'PENDING', ?, 'alpine', 'true', '', '1')", newId(), r, jobId, a]])
      check lease(a, "c-a", 5).len == 0
    test "the executor service still leases any run, as before":
      let a = newOrg()
      let r = co.createRun("p", "return 1", "t1", a)
      check c.leaseCandidates(only = r).len == 1
