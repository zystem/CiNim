## D-86, against a real rqlite: a secret belongs to the organisation or to a group, the nearest one by name wins, a protected one goes to a run on a protected ref only; a run is trusted
## when it was asked by a name that the project protects; a pipeline uses build or deploy only when its project allows it. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, tables]
import common/[rqlite, scriptsource]
import core/[schema, scheduler, secretvault, kekprovider, stepsecrets, groups, projectpolicy, loggate, logcircuit, runlease]

let url = getEnv("CINIM_RQLITE_URL")

suite "D-86 secrets, trusted refs and privileged profiles":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    setDekCacheSeconds(0.0)
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let tenant = "tp" & sfx
    let kek = derivedKek("trust-key-" & sfx)
    let now = getTime().toUnix()
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns", buildOn: true, deployOn: true, orgPrefix: "cinim", orgShard: "001")
    check c.createGroup(tenant, "ci", now).error.len == 0
    check c.createGroup(tenant, "team", now).error.len == 0
    let cinim = c.createProject(tenant, "ci/cinim", "https://example.test/cinim.git", now)
    let web = c.createProject(tenant, "team/web", "https://example.test/web.git", now)
    let ciGroup = c.groupIdOf(tenant, "ci").id
    check cinim.error.len == 0 and web.error.len == 0 and ciGroup.len > 0
    proc put(name, value, group: string; protected = false) =
      let gid = if group.len == 0: "" else: c.groupIdOf(tenant, group).id
      check c.putSecret(kek, tenant, name, value, now, gid, protected).ok
    proc valueOf(group, name: string; trusted = false): string =
      let g = c.getSecrets(kek, tenant, @[name], (if group.len == 0: "" else: c.groupIdOf(tenant, group).id), trusted)
      if g.ok: g.values[0][1] else: "ERR " & g.error

    test "a secret of the organisation is seen by every project, one of a group by the projects under it, one of a project by that project only":
      put("REGISTRY", "org-registry", "")
      put("CI_TOKEN", "ci-token", "ci")
      put("ONLY_CINIM", "cinim-only", "ci/cinim")
      check valueOf("ci/cinim", "REGISTRY") == "org-registry" and valueOf("team/web", "REGISTRY") == "org-registry"
      check valueOf("ci/cinim", "CI_TOKEN") == "ci-token" and valueOf("ci", "CI_TOKEN") == "ci-token"
      check valueOf("team/web", "CI_TOKEN").startsWith("ERR") and valueOf("team/web", "ONLY_CINIM").startsWith("ERR") and valueOf("ci", "ONLY_CINIM").startsWith("ERR")
    test "the nearest holder of a name wins: the project over its group over the organisation; a sibling is not touched":
      put("DB", "org-db", "")
      put("DB", "ci-db", "ci")
      check valueOf("team/web", "DB") == "org-db" and valueOf("ci", "DB") == "ci-db" and valueOf("ci/cinim", "DB") == "ci-db"
      put("DB", "cinim-db", "ci/cinim")
      check valueOf("ci/cinim", "DB") == "cinim-db" and valueOf("ci", "DB") == "ci-db" and valueOf("team/web", "DB") == "org-db"
      check c.forgetStepSecret(tenant, "DB", c.groupIdOf(tenant, "ci/cinim").id)
      check valueOf("ci/cinim", "DB") == "ci-db"                                          # the group\'s shows again
    test "a new value of a secret is a new version in its own place, and the others are not moved":
      put("VER", "v1", "ci")
      put("VER", "v2", "ci")
      put("VER", "org-v", "")
      let seen = c.visibleSecrets(tenant, c.groupIdOf(tenant, "ci/cinim").id)
      check seen["VER"].version == 2 and seen["VER"].scope == "ci" and valueOf("ci/cinim", "VER") == "v2" and valueOf("team/web", "VER") == "org-v"
    test "a protected secret goes to a trusted run only, and an unprotected one to both":
      put("PROD_KEY", "prod-secret", "ci/cinim", protected = true)
      put("PLAIN_KEY", "plain", "ci/cinim")
      check valueOf("ci/cinim", "PROD_KEY", trusted = false).startsWith("ERR") and "protected" in valueOf("ci/cinim", "PROD_KEY", trusted = false)
      check valueOf("ci/cinim", "PROD_KEY", trusted = true) == "prod-secret"
      check valueOf("ci/cinim", "PLAIN_KEY", trusted = false) == "plain" and valueOf("ci/cinim", "PLAIN_KEY", trusted = true) == "plain"
      let seen = c.visibleSecrets(tenant, c.groupIdOf(tenant, "ci/cinim").id)
      check missingSecrets(seen, @["PROD_KEY", "PLAIN_KEY"], trusted = false) == @["PROD_KEY"] and missingSecrets(seen, @["PROD_KEY"], trusted = true).len == 0
      put("PROD_KEY", "prod-secret-2", "ci/cinim", protected = false)                     # the flag is part of what is put
      check valueOf("ci/cinim", "PROD_KEY", trusted = false) == "prod-secret-2"
    test "a sealed value does not open in another place: moved to the row of another group it is refused":
      put("MOVE_ME", "ci-value", "ci")
      put("MOVE_ME", "web-value", "team/web")
      let ciRow = c.query(%*[["SELECT value_enc FROM step_secrets WHERE tenant_id = ? AND group_id = ? AND name = 'MOVE_ME'", tenant, ciGroup]])["results"][0]["values"][0][0].getStr
      discard c.execute(%*[["UPDATE step_secrets SET value_enc = ? WHERE tenant_id = ? AND group_id = ? AND name = 'MOVE_ME'", ciRow, tenant, c.groupIdOf(tenant, "team/web").id]])
      check valueOf("team/web", "MOVE_ME") == "ERR the secret MOVE_ME cannot be read"
      check valueOf("ci", "MOVE_ME") == "ci-value"
    test "the secrets of an organisation sealed before groups had them still open (the form of the AAD is kept)":
      check c.putSecret(kek, tenant, "OLD_STYLE", "org-v1", now).ok
      check valueOf("ci/cinim", "OLD_STYLE") == "org-v1"
      check c.listStepSecrets(tenant).len > 0 and c.listStepSecrets(tenant, ciGroup).len > 0
      let eff = c.effectiveSecrets(tenant, c.groupIdOf(tenant, "ci/cinim").id)
      var scopes: Table[string, string]
      for e in eff: scopes[e["name"].getStr] = e["scope"].getStr
      check scopes["REGISTRY"] == "" and scopes["CI_TOKEN"] == "ci" and scopes["ONLY_CINIM"] == "ci/cinim"
    test "protected refs: patterns are kept on the project, and a ref is protected by any of them":
      check c.setProtectedRefs(cinim.id, @["main", "release/*"]) == ""
      check c.protectedPatterns(cinim.id) == @["main", "release/*"]
      check c.isProtectedRef(cinim.id, "main") and c.isProtectedRef(cinim.id, "release/1") and not c.isProtectedRef(cinim.id, "feature/x") and not c.isProtectedRef(cinim.id, "")
      check not c.isProtectedRef(web.id, "main")                                           # another project has its own
      check c.setProtectedRefs(cinim.id, @["a b"]).len > 0 and c.setProtectedRefs(cinim.id, @["*"]).len > 0
      check c.protectedPatterns(cinim.id) == @["main", "release/*"]                         # a refused list changes nothing
    test "a run is trusted when it was asked by a name its project protects; a hash, no name, another project, another name are not":
      let prof = c.ensureOrganizationProfile(tenant, "cinim-001-" & tenant)
      proc runOn(project: string; asked: string): string =
        co.createRun("return 1", tenant, prof, groupId = c.groupIdOf(tenant, project).id,
                     source = Source(repository: "https://example.test/x.git", commit: "0123456789abcdef0123456789abcdef01234567", path: ".ci/pipeline.lua", refName: refNameOf(asked)))
      proc trustedOf(run: string): bool = c.query(%*[["SELECT trusted FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getInt > 0
      check trustedOf(runOn("ci/cinim", "main")) and trustedOf(runOn("ci/cinim", "release/2.0"))
      check not trustedOf(runOn("ci/cinim", "feature/x")) and not trustedOf(runOn("ci/cinim", "")) and not trustedOf(runOn("team/web", "main"))
      check not trustedOf(runOn("ci/cinim", "0123456789abcdef0123456789abcdef01234567"))       # by its hash: no ref
      let r = runOn("ci/cinim", "main")
      check co.getRun(r)["trusted"].getBool and co.getRun(r)["source"]["ref"].getStr == "main"
      check not co.getRun(runOn("ci/cinim", "feature/x"))["trusted"].getBool
    test "privileged profiles: build only if the project or a group above allows it, deploy also only on a protected ref":
      check c.profileProblem(cinim.id, "", false) == "" and c.profileProblem(cinim.id, "default", false) == ""
      check "not allowed" in c.profileProblem(cinim.id, "build", true) and "not allowed" in c.profileProblem(cinim.id, "deploy", true)
      check c.setAllowedProfiles(cinim.id, @["build"]) == ""
      check c.profileProblem(cinim.id, "build", false) == "" and "not allowed" in c.profileProblem(cinim.id, "deploy", true)
      check c.setAllowedProfiles(ciGroup, @["build", "deploy"]) == ""                      # a group above allows for all under it
      check c.allowedProfiles(cinim.id) == @["build", "deploy"] and c.allowedProfiles(web.id).len == 0
      check c.profileProblem(cinim.id, "build", false) == "" and c.profileProblem(cinim.id, "deploy", true) == ""
      check "protected ref" in c.profileProblem(cinim.id, "deploy", false)
      check "not allowed" in c.profileProblem(web.id, "build", true)                       # the other tree
      check c.setAllowedProfiles(cinim.id, @["root"]).len > 0
    test "the host call of a job refuses a profile the project does not allow, deploy to an untrusted run, and a protected secret to an untrusted run":
      let orgId = c.addOrganization("tp-" & sfx, "T")
      let prof = c.ensureOrganizationProfile(orgId, "cinim-001-tp-" & sfx)
      check c.createGroup(orgId, "g", now).error.len == 0
      let p1 = c.createProject(orgId, "g/p1", "https://example.test/p1.git", now)
      check p1.error.len == 0 and c.setProtectedRefs(p1.id, @["main"]) == ""
      proc runOf(asked: string): string =
        co.createRun("return 1", orgId, prof, groupId = p1.id, source = Source(repository: "https://example.test/p1.git", commit: "0123456789abcdef0123456789abcdef01234567", path: ".ci/pipeline.lua", refName: asked))
      var next = 0'u64
      proc call(run, profile, opts: string): ExecutorResponse =
        var tok = takeRunLease(c, "master", run, "test")
        if tok.len == 0:
          tok = leaseToken("master", run, c.query(%*[["SELECT lease_attempt FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getInt)
        inc next
        handleCall(c, co, HostCall(run_id: run, lease_token: tok, seq: next, kind: "job_sh", numbered: true, step_no: uint32(next),
          payload: cast[seq[byte]]("job-" & $next & "\tkaniko\t" & profile & "\t" & opts & "\techo x")), "master")
      proc ok(r: ExecutorResponse): bool = r.body.kind == ExecutorResponseBodyKind.result
      proc why(r: ExecutorResponse): string = (if r.body.kind == ExecutorResponseBodyKind.failure: r.body.failure.detail else: "")
      let feature = runOf("feature/x")
      let onMain = runOf("main")
      check ok(call(feature, "", ""))                                                                # the ordinary profile is for all
      check "not allowed for this project" in why(call(feature, "build", "")) and "not allowed for this project" in why(call(onMain, "deploy", ""))
      check c.setAllowedProfiles(p1.id, @["build", "deploy"]) == ""
      check ok(call(feature, "build", "")) and ok(call(onMain, "build", ""))
      check "protected ref" in why(call(feature, "deploy", "")) and ok(call(onMain, "deploy", ""))
      # the secrets: the one the project has, the protected one, the one nobody has
      check c.putSecret(kek, orgId, "PLAIN", "p", now, p1.id).ok and c.putSecret(kek, orgId, "PROD", "q", now, p1.id, protected = true).ok
      check ok(call(feature, "", """{"secrets":["PLAIN"]}""")) and ok(call(onMain, "", """{"secrets":["PLAIN","PROD"]}"""))
      check "PROD" in why(call(feature, "", """{"secrets":["PROD"]}""")) and "protected" in why(call(feature, "", """{"secrets":["PROD"]}"""))
      check "NOPE" in why(call(onMain, "", """{"secrets":["NOPE"]}"""))
