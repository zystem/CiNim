## D-99, against a real rqlite: a person\'s token with a subset of their permissions (never an administrator, never more than the person holds, gone with the person\'s roles), and the token of a step
## (for the project of its run, the permissions it named, only as much as the person who started the run holds, gone when the run ends). Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, tables, sequtils, sets]
import common/[rqlite, scriptsource]
import core/[schema, scheduler, apiauth, audit, groups, loggate, logcircuit, runlease]

let url = getEnv("CINIM_RQLITE_URL")

suite "D-99 tokens with a subset of permissions":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let slug = "tk" & sfx
    let org = c.addOrganization(slug, "A")
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let prof = c.ensureOrganizationProfile(org, "cinim-001-" & slug)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let now = getTime().toUnix()
    check c.createGroup(org, "ci", now).error.len == 0
    check c.createProject(org, "ci/app", "https://example.test/app.git", now).error.len == 0
    check c.createProject(org, "ci/other", "https://example.test/other.git", now).error.len == 0
    var n = 0
    proc person(role: string; scope = ""): string =
      inc n
      let name = "k" & sfx & $n
      check c.createUser(name, role, "a-long-password-of-" & name, now, (if scope.len == 0: "org:" & slug else: scope))
      name

    test "the token holds the permissions it names and no more; the person\'s other rights are not in it; it is not an administrator":
      let dev = person("dev")
      let made = c.createRestrictedToken(dev, "ci read", TokenRestrict(permissions: @["run.read", "log.read"]), now + 86400, now)
      check made.error == "" and made.token.len > 0
      let p = c.authenticate("", made.token, now + 1)
      check p.ok and p.limited and p.user == dev and not p.admin
      check p.grants.holds("run.read", slug) and p.grants.holds("log.read", slug) and not p.grants.holds("run.start", slug) and not p.grants.holds("run.abort", slug)
      check p.mayCall("GET", "/api/v1/runs") and not p.mayCall("POST", "/api/v1/runs") and not p.mayCall("POST", "/api/v1/runs/x:abort")
      check not p.mayCall("GET", "/api/v1/me/tokens") and actorOf(p) == "token:" & made.id
    test "an administrator\'s token with a subset is not an administrator, and for an organisation it holds there only":
      let boss = person("admin", "shard")
      let made = c.createRestrictedToken(boss, "read acme", TokenRestrict(permissions: @["run.read", "run.start"], organization: slug), now + 86400, now)
      check made.error == ""
      let p = c.authenticate("", made.token, now + 1)
      check p.limited and not p.admin and p.grants.holds("run.read", slug) and p.grants.holds("run.start", slug, "ci/app") and not p.grants.holds("run.read", "another") and card(p.grants.shard) == 0
      check not p.mayCall("GET", "/api/v1/users") and not p.mayCall("POST", "/api/v1/organizations")
    test "a permission the person does not hold is refused; so is a shard\'s own in a token for an organisation; so is a bad request":
      let ro = person("ro")
      check c.createRestrictedToken(ro, "x", TokenRestrict(permissions: @["run.start"]), now + 100, now).error.contains("you do not hold run.start")
      check c.createRestrictedToken(ro, "x", TokenRestrict(permissions: @["audit.read"], organization: slug), now + 100, now).error.contains("shard")
      check c.createRestrictedToken(ro, "x", TokenRestrict(permissions: @["nope.read"]), now + 100, now).error.contains("no such permission")
      check c.createRestrictedToken(ro, "x", TokenRestrict(), now + 100, now).error.contains("1 to 40")
      check c.createRestrictedToken(ro, "x", TokenRestrict(permissions: @["run.read"], organization: "other-org"), now + 100, now).error.contains("do not hold")
    test "a token for a project holds there and not in its sibling":
      let dev = person("dev")
      let made = c.createRestrictedToken(dev, "app", TokenRestrict(permissions: @["run.read", "run.start"], organization: slug, group: "ci/app"), now + 86400, now)
      check made.error == ""
      let p = c.authenticate("", made.token, now + 1)
      check p.grants.holds("run.start", slug, "ci/app") and not p.grants.holds("run.start", slug, "ci/other") and not p.grants.holds("run.start", slug)
    test "the token goes with the person\'s roles (it can lose rights with its person, never gain), expires, and can be revoked by its person only":
      let dev = person("dev")
      let other = person("dev")
      let made = c.createRestrictedToken(dev, "t", TokenRestrict(permissions: @["run.start"]), now + 1000, now)
      check c.authenticate("", made.token, now + 1).ok
      check c.authenticate("", made.token, now + 2000).why == "expired"
      check not c.revokeOwnToken(other, made.id, now + 2) and c.listOwnTokens(dev).len == 1 and c.listOwnTokens(dev)[0]["restrict"]["permissions"] == %*["run.start"]
      check c.setMember("org:" & slug, dev, @["ro"]) == ""
      check c.authenticate("", made.token, now + 3).limited and not c.authenticate("", made.token, now + 3).grants.holds("run.start", slug)          # the person lost run.start: the token has it no more
      check c.revokeOwnToken(dev, made.id, now + 4) and c.authenticate("", made.token, now + 5).why == "revoked"
      check c.setMember("org:" & slug, dev, @[]) == ""

suite "D-99 the token of a step":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let slug = "st" & sfx
    let org = c.addOrganization(slug, "A")
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let prof = c.ensureOrganizationProfile(org, "cinim-001-" & slug)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let now = getTime().toUnix()
    check c.createGroup(org, "ci", now).error.len == 0
    check c.createProject(org, "ci/app", "https://example.test/app.git", now).error.len == 0
    check c.createProject(org, "ci/other", "https://example.test/other.git", now).error.len == 0
    let app = c.groupIdOf(org, "ci/app").id
    let dev = "d" & sfx
    check c.createUser(dev, "dev", "a-long-password-of-" & dev, now, "org:" & slug)
    proc run(actor: string): string = co.createRun("return 1", org, prof, @[], groupId = app, actor = actor)

    test "a step started by a person gets the permissions it names that the person holds, for its project only":
      let id = run("user:" & dev)
      let t = c.mintStepToken(id, 1, 1, @["run.read", "run.abort"], now)
      check t.error == "" and t.token.startsWith("cnm_")
      let p = c.authenticate("", t.token, now + 1)
      check p.ok and p.limited and p.grants.holds("run.read", slug, "ci/app") and p.grants.holds("run.abort", slug, "ci/app/x")
      check not p.grants.holds("run.read", slug, "ci/other") and not p.grants.holds("run.read", slug) and not p.grants.holds("run.start", slug, "ci/app")
      check actorOf(p).startsWith("token:") and not p.mayCall("GET", "/api/v1/users")
    test "what the person does not hold, and what a step may never have, is refused":
      let id = run("user:" & dev)
      check c.mintStepToken(id, 1, 1, @["run.delete"], now).error.contains("cannot be given to a step")
      check c.mintStepToken(id, 1, 1, @["access.write"], now).error.contains("cannot be given")
      let ro = "r" & sfx
      check c.createUser(ro, "ro", "a-long-password-of-" & ro, now, "org:" & slug)
      check c.mintStepToken(run("user:" & ro), 1, 1, @["run.abort"], now).error.contains("does not hold run.abort")
      check c.mintStepToken(run("trigger:t1"), 1, 1, @["run.abort"], now).error.contains("started by a person")
      check c.mintStepToken(run("trigger:t1"), 1, 1, @["run.read", "log.read"], now).error == ""            # reading is for any run
      check c.mintStepToken(id, 1, 1, @[], now).error.contains("1 to 10") and c.mintStepToken("nope", 1, 1, @["run.read"], now).error == "no such run"
    test "the token is gone when the run ends, and a second token for the same attempt replaces the first":
      let id = run("user:" & dev)
      let a = c.mintStepToken(id, 2, 1, @["run.read"], now)
      let b = c.mintStepToken(id, 2, 1, @["run.read"], now + 1)
      check c.authenticate("", a.token, now + 2).why == "revoked" and c.authenticate("", b.token, now + 2).ok
      discard c.execute(%*[["UPDATE runs SET state = 'OK' WHERE id = ?", id]])
      check c.authenticate("", b.token, now + 3).why == "revoked"
    test "the step token expires after its time":
      let id = run("user:" & dev)
      let t = c.mintStepToken(id, 3, 1, @["run.read"], now)
      check c.authenticate("", t.token, now + stepTokenSeconds + 1).why == "expired"
