## D-82: a run made from a repository is told the last commit of its pipeline that went well (`source_base`, `run.source.base` in the script): the commit of the latest run of the same
## organisation, project, repository and script that ended OK, before this run was made. Against a real rqlite. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times]
import common/[rqlite, scriptsource]
import core/[schema, scheduler, groups]

let url = getEnv("CINIM_RQLITE_URL")

suite "D-82 the base of a run":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let profile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: profile, namespace: "cinim-default-ns")
    let org = c.addOrganization("sb" & newId()[^6 .. ^1].toLowerAscii, "SB")
    let orgProfile = c.ensureOrganizationProfile(org, "cinim-001-sb" & newId()[^4 .. ^1])
    let now = getTime().toUnix()
    discard c.createProject(org, "one", "https://example.test/r.git", now)
    discard c.createProject(org, "two", "https://example.test/r.git", now)
    let one = c.resolveProject(org, "one").id
    let two = c.resolveProject(org, "two").id
    func src(commit: string; path = ".ci/pipeline.lua"; repository = "https://example.test/r.git"): Source = Source(repository: repository, commit: commit, path: path)
    proc baseOf(run: string): string = c.query(%*[["SELECT source_base FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getStr
    proc state(run, s: string) = discard c.execute(%*[["UPDATE runs SET state = ? WHERE id = ?", s, run]])
    proc make(project: string; commit: string; path = ".ci/pipeline.lua"; repository = "https://example.test/r.git"): string =
      co.createRun("return 1", org, orgProfile, @[], groupId = project, source = src(commit, path, repository))

    test "the first run has none; a run after a good one has its commit; a failed or aborted or running one does not count":
      let r1 = make(one, "1".repeat(40))
      check baseOf(r1) == ""
      let r2 = make(one, "2".repeat(40))
      check baseOf(r2) == ""                                      # r1 is still going
      state(r1, "OK")
      let r3 = make(one, "3".repeat(40))
      check baseOf(r3) == "1".repeat(40)
      state(r2, "FAILED")
      state(r3, "ABORTED")
      check baseOf(make(one, "4".repeat(40))) == "1".repeat(40)    # failed and aborted are not good
    test "the newest good run is the base":
      let a = make(two, "a".repeat(40))
      state(a, "OK")
      let b = make(two, "b".repeat(40))
      state(b, "OK")
      check baseOf(make(two, "c".repeat(40))) == "b".repeat(40)
    test "another project, another script of the project, another repository or another organisation does not give its good run":
      let g = make(one, "e".repeat(40), path = ".ci/00.lua")
      state(g, "OK")
      check baseOf(make(one, "f".repeat(40), path = ".ci/01.lua")) == ""             # another script (D-68: another pipeline)
      check baseOf(make(one, "f".repeat(40), repository = "https://example.test/other.git")) == ""
      let other = c.addOrganization("sb2" & newId()[^6 .. ^1].toLowerAscii, "SB2")
      check baseOf(co.createRun("return 1", other, c.ensureOrganizationProfile(other, "cinim-001-sb2" & newId()[^4 .. ^1]), @[], groupId = "", source = src("9".repeat(40), ".ci/00.lua"))) == ""
    test "a run that did not come from a repository has no base, and getRun shows it in the source when there is one":
      check baseOf(co.createRun("return 1", org, orgProfile)) == ""
      let a = make(two, "d".repeat(40), path = ".ci/09.lua")
      state(a, "OK")
      let b = make(two, "d2".repeat(20), path = ".ci/09.lua")
      check co.getRun(b)["source"]["base"].getStr == "d".repeat(40)
      check not co.getRun(a)["source"].hasKey("base") or co.getRun(a)["source"]["base"].getStr == ""
