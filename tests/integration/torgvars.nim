## VAR-001..VAR-004: the plain variables of an organisation, against a real rqlite: stored, listed, deleted; the limits; what a step's environment is (the variables of the
## organisation under the launch parameters); and what the run's view says about where each value came from. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times]
import common/rqlite
import core/[schema, scheduler, orgvars]

let url = getEnv("CINIM_RQLITE_URL")

suite "VAR-001 variables of an organisation":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let orgA = c.addOrganization("va" & sfx, "A")
    let orgB = c.addOrganization("vb" & sfx, "B")
    let now = getTime().toUnix()
    proc get(name: string; org = orgA): string =
      for (k, v) in c.listVariables(org):
        if k == name: return v
    proc sourceOf(env: seq[EffectiveVariable]; name: string): string =
      for e in env:
        if e.name == name: return e.source & ":" & e.value

    test "a variable is set, changed, listed in the order of names, and deleted":
      check c.setVariable(orgA, "B_URL", "https://b", now) == ""
      check c.setVariable(orgA, "A_URL", "https://a", now) == ""
      check c.listVariables(orgA) == @[("A_URL", "https://a"), ("B_URL", "https://b")]
      check c.setVariable(orgA, "A_URL", "https://a2", now) == ""
      check get("A_URL") == "https://a2" and c.listVariables(orgA).len == 2
      check c.deleteVariable(orgA, "A_URL") and not c.deleteVariable(orgA, "A_URL")
      check c.listVariables(orgA) == @[("B_URL", "https://b")]
    test "organisations do not see each other's variables":
      check c.setVariable(orgB, "ONLY_B", "b", now) == ""
      check get("ONLY_B", orgA) == "" and get("ONLY_B", orgB) == "b"
    test "a name or a value that may not be is refused with the reason, and nothing is stored":
      check c.setVariable(orgA, "path", "x", now) != ""
      check c.setVariable(orgA, "PATH", "x", now) != ""
      check c.setVariable(orgA, "OK", "a".repeat(9000), now) != ""
      check get("PATH") == "" and get("OK") == ""
    test "at most a hundred variables, and a change of one that exists does not count twice":
      let org = c.addOrganization("vc" & sfx, "C")
      for i in 1 .. 100: check c.setVariable(org, "V" & $i, "x", now) == ""
      check c.setVariable(org, "V101", "x", now) != ""
      check c.setVariable(org, "V50", "changed", now) == ""
      check c.listVariables(org).len == 100
    test "at most 64 KiB of values in all":
      let org = c.addOrganization("vd" & sfx, "D")
      for i in 1 .. 8: check c.setVariable(org, "BIG" & $i, "z".repeat(8000), now) == ""        # 64000 bytes
      check c.setVariable(org, "BIG9", "z".repeat(2000), now) != ""
      check c.setVariable(org, "BIG1", "z".repeat(8192), now) == ""                              # a bigger value in place of one that exists: 64192
    test "a step's environment is the variables of the organisation, and a launch parameter of the same name wins; the run's view says which came from where":
      check c.setVariable(orgA, "TARGET", "from-the-organisation", now) == ""
      check c.setVariable(orgA, "REGION", "eu", now) == ""
      let r = co.createRun("return 1", orgA, defaultProfile, @[("TARGET", "from-the-launch"), ("JOBS", "4")])
      let env = c.effectiveVariables(r)
      check sourceOf(env, "TARGET") == "launch:from-the-launch"
      check sourceOf(env, "REGION") == "organization:eu"
      check sourceOf(env, "JOBS") == "launch:4"
      var pairs: seq[string]
      for (k, v) in c.stepEnv(r): pairs.add k & "=" & v
      check "TARGET=from-the-launch" in pairs and "REGION=eu" in pairs and "JOBS=4" in pairs and pairs.len == c.effectiveVariables(r).len
      let view = co.getRun(r)
      var seen: seq[string]
      for v in view["variables"]: seen.add v["name"].getStr & ":" & v["source"].getStr
      check "TARGET:launch" in seen and "REGION:organization" in seen
    test "a run of another organisation, or of none, gets none of them":
      let other = co.createRun("return 1", orgB, defaultProfile)
      check sourceOf(c.effectiveVariables(other), "REGION") == ""
      let none = co.createRun("return 1", "t1", defaultProfile)
      check c.effectiveVariables(none).len == 0
      check not co.getRun(none).hasKey("variables")
    test "a variable changed after a run began is seen by the steps that start after the change (VAR-002: the current value)":
      let r = co.createRun("return 1", orgA, defaultProfile)
      check c.setVariable(orgA, "LATE", "one", now) == ""
      check sourceOf(c.effectiveVariables(r), "LATE") == "organization:one"
      check c.setVariable(orgA, "LATE", "two", now) == ""
      check sourceOf(c.effectiveVariables(r), "LATE") == "organization:two"
