## RUN-009 / IAM-003: the answer to a controller's report carries the plan of the organisation's conductors (docs/conductors.md section 5): how many,
## the image, the credential of each. Against a real rqlite; needs CINIM_RQLITE_URL (a scratch rqlite), otherwise the suite is skipped.
import std/[unittest, json, os, sequtils]
import common/[rqlite, ctrlauth]
import core/[schema, scheduler, loggate, logcircuit, retrypolicy]
import common/conductorplan

let url = getEnv("CINIM_RQLITE_URL")

suite "RUN-009 the plan of the conductors in the answer to a report":
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
    proc newOrg(per = 10, minimum = 1, podLimit = 20): tuple[profile, ns: string] =
      inc n
      let org = c.addOrganization("pl" & $n & "-" & sfx, "P")
      let ns = "cinim-001-pl" & $n & "-" & sfx
      let prof = c.ensureOrganizationProfile(org, ns)
      var s = defaultSettings()
      s.podLimit = podLimit
      s.runsPerConductor = per
      s.conductorMin = minimum
      co.setProfileSettings(s, prof)
      (prof, ns)
    proc report(ns: string; push = false): PollResponse =
      inc n
      handlePoll(c, defaultProfile, "master", PollRequest(session_id: "pl-" & $n & "-" & sfx, namespace: ns, free_pod_slots: 5), push = push)

    test "without a conductor image the answer says nothing about conductors":
      let o = newOrg()
      conductorImage = ""
      check not report(o.ns).conductors.present
    conductorImage = "registry.example/cinim-conductor:t"
    planCacheSeconds = 0.0           # these tests change the runs and look at the plan at once
    test "one warm conductor for an organisation with no runs, with the image, the settings and its credential":
      let o = newOrg()
      let p = report(o.ns).conductors
      check p.present and p.desired == 1 and p.image == conductorImage and p.runs_per_conductor == 10 and p.drain_seconds > 0
      check p.credentials.len == 1 and p.credentials[0].id == "cond-1"
      check p.credentials[0].credential == conductorCredential("master", o.ns, "cond-1")
    test "the number follows the runs: 25 runs with 10 to a conductor are 3, cut to what pod_limit allows":
      let o = newOrg(podLimit = 20)
      for i in 0 ..< 25: discard co.createRun("p", "return 1", "t1", o.profile)
      let p = report(o.ns).conductors
      check p.desired == 2                                # at most 20 runs are active, 10 to a conductor
      check p.credentials.mapIt(it.id) == @["cond-1", "cond-2"]
      let o2 = newOrg(podLimit = 100)
      for i in 0 ..< 25: discard co.createRun("p", "return 1", "t1", o2.profile)
      check report(o2.ns).conductors.desired == 3
    test "conductor_min 0 lets an organisation scale to zero, and the first run brings a conductor":
      let o = newOrg(minimum = 0)
      check report(o.ns).conductors.desired == 0
      discard co.createRun("p", "return 1", "t1", o.profile)
      check report(o.ns).conductors.desired == 1
    test "the credential of one organisation's conductor is not another's":
      let a = newOrg()
      let b = newOrg()
      check report(a.ns).conductors.credentials[0].credential != report(b.ns).conductors.credentials[0].credential
    test "a push (a look at the queue without news) carries no plan":
      let o = newOrg()
      check not report(o.ns, push = true).conductors.present
    test "the settings of the conductors are read and written through the profile":
      let o = newOrg(per = 4, minimum = 0)
      let g = co.getProfileSettings(o.profile)
      check g["runs_per_conductor"].getInt == 4 and g["conductor_min"].getInt == 0
    conductorImage = ""
