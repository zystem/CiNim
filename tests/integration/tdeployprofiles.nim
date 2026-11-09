## D-115, against a real rqlite: the deploy profiles of an organisation (saved, changed field by field, listed, deleted), the groups that may use them (allowed_profiles), and what a step that asks
## for one by its name is given. Needs CINIM_RQLITE_URL; without it the suite is skipped.
import std/[unittest, json, os, times, strutils, algorithm]
import common/[rqlite, scriptsource, bytestr]
import core/[schema, deployprofiles, projectpolicy, scheduler, groups, loggate, logcircuit, runlease]
import ../../build/nimproto/protos

let url = getEnv("CINIM_RQLITE_URL")

suite "D-115 deploy profiles of an organisation":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let sfx = newId()
    let now = getTime().toUnix()
    let orgId = c.addOrganization("dp" & sfx, "D")
    let otherOrg = c.addOrganization("do" & sfx, "O")
    proc put(name: string; j: JsonNode; org = orgId): tuple[error: string, status: int, created: bool] = c.putDeployProfile(org, name, j, now)

    test "a profile gets an account of its own unless told otherwise, and keeps what a later request leaves out":
      let done = put("test1", %*{"namespace": "test1", "description": "the first test namespace"})
      check done.error == "" and done.created
      var p = c.deployProfileNamed(orgId, "test1").profile
      check p.serviceAccount == "deploy-test1" and p.targetNamespace == "test1" and p.description == "the first test namespace"
      check put("test1", %*{"description": "changed"}).created == false
      p = c.deployProfileNamed(orgId, "test1").profile
      check p.serviceAccount == "deploy-test1" and p.targetNamespace == "test1" and p.description == "changed"      # the account and the namespace stayed
    test "an account named by hand, no account at all (no token), and every namespace":
      check put("test2", %*{"service_account": "shared-deployer", "namespace": "test2"}).error == ""
      check put("everywhere", %*{"namespace": "*"}).error == "" and put("tests", %*{"namespace": "test*"}).error == ""
      check put("bad", %*{"namespace": "te*st"}).status == 400 and put("bad", %*{"namespace": "*test"}).status == 400
      check put("local", %*{"service_account": ""}).error == ""
      check c.deployProfileNamed(orgId, "test2").profile.serviceAccount == "shared-deployer"
      check c.deployProfileNamed(orgId, "everywhere").profile.targetNamespace == "*"
      check c.deployProfileNamed(orgId, "local").profile.serviceAccount == "" and not c.deployProfileNamed(orgId, "local").profile.view["token"].getBool
      check c.deployAccountsOf(orgId) == @["deploy-test1", "deploy-everywhere", "deploy-tests", "shared-deployer"].sorted         # each account once; none for the profile with no token
    test "what is wrong with a request is told, and nothing is saved":
      check put("Bad Name", %*{}).status == 400 and put("deploy", %*{}).status == 400 and put("build", %*{}).status == 400
      check put("x", %*{"service_account": "Bad_Account"}).status == 400
      check put("x", %*{"namespace": "not a namespace"}).status == 400
      check put("x", %*{"service_account": 1}).status == 400 and put("x", %*{"description": "d".repeat(301)}).status == 400
      check put("x", newJArray()).status == 400
      check not c.deployProfileNamed(orgId, "x").found
    test "a profile of another organisation is not seen, and the same name may be used there":
      check not c.deployProfileNamed(otherOrg, "test1").found
      check put("test1", %*{"namespace": "other"}, otherOrg).created
      check c.deployProfileNamed(orgId, "test1").profile.targetNamespace == "test1"
      check c.deployProfilesOf(otherOrg).len == 1
    test "a profile is deleted, and a second delete finds none":
      check put("gone", %*{}).created
      check c.deleteDeployProfile(orgId, "gone") and not c.deleteDeployProfile(orgId, "gone")

    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns", buildOn: true, deployOn: true, orgPrefix: "cinim", orgShard: "001")
    let prof = c.ensureOrganizationProfile(orgId, "cinim-001-dp-" & sfx)
    check c.createGroup(orgId, "g", now).error.len == 0
    let p1 = c.createProject(orgId, "g/p1", "https://example.test/p1.git", now)
    let p2 = c.createProject(orgId, "g/p2", "https://example.test/p2.git", now)
    check p1.error.len == 0 and p2.error.len == 0

    test "a group allows one profile, another the second, a third both: allowed_profiles takes the names the organisation has, and nothing else":
      check c.setAllowedProfiles(p1.id, @["test1"]) == ""
      check c.setAllowedProfiles(p2.id, @["test1", "test2", "deploy"]) == ""
      check c.allowedProfiles(p1.id) == @["test1"] and c.allowedProfiles(p2.id) == @["test1", "test2", "deploy"]
      check "has no deploy profile nowhere" in c.setAllowedProfiles(p1.id, @["nowhere"])                   # a typo does not grant nothing quietly
      check c.setAllowedProfiles(p1.id, @["Bad Name"]).len > 0
      check c.setAllowedProfiles(p1.id, @["test1", "x" & sfx]).len > 0
      check c.allowedProfiles(p1.id) == @["test1"]                                                         # a refused request changed nothing
    test "the gate: a profile of the organisation is privileged like deploy - the project must allow it and the run must be trusted":
      check c.profileProblem(p1.id, "", false) == "" and c.profileProblem(p1.id, "default", false) == ""
      check "not allowed" in c.profileProblem(p1.id, "test2", true)
      check "protected ref" in c.profileProblem(p1.id, "test1", false)
      check c.profileProblem(p1.id, "test1", true) == ""
      check c.profileProblem(p2.id, "test2", true) == ""

    test "the host call: a step that asks for a profile the project allows is made, one the organisation has not or the project does not allow is refused":
      let run = co.createRun("return 1", orgId, prof, groupId = p2.id, source = Source(repository: "https://example.test/p2.git", commit: "0123456789abcdef0123456789abcdef01234567", path: ".ci/pipeline.lua", refName: "main"))
      discard c.execute(%*[["UPDATE runs SET trusted = 1 WHERE id = ?", run]])
      var next = 0'u64
      proc call(kind, payload: string): ExecutorResponse =
        var tok = takeRunLease(c, "master", run, "test")
        if tok.len == 0:
          tok = leaseToken("master", run, c.query(%*[["SELECT lease_attempt FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getInt)
        inc next
        handleCall(c, co, HostCall(run_id: run, lease_token: tok, seq: next, kind: kind, key: "", numbered: true, step_no: uint32(next), payload: cast[seq[byte]](payload)), "master")
      proc ok(r: ExecutorResponse): bool = r.body.kind == ExecutorResponseBodyKind.result
      proc why(r: ExecutorResponse): string = (if r.body.kind == ExecutorResponseBodyKind.failure: r.body.failure.detail else: "")
      let step = proc (profile: string): ExecutorResponse = call("job_sh", "job-" & $(next + 1) & "\tbusybox\t" & profile & "\t\techo x")
      check ok(step("test1")) and ok(step("test2")) and ok(step("deploy")) and ok(step(""))
      check "has no deploy profile" in why(step("nowhere"))
      check ok(step("everywhere")) == false and "not allowed" in why(step("everywhere"))                    # the organisation has it, this project does not allow it
