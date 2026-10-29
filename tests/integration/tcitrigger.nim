## D-93, D-95, against a real rqlite: `ci.trigger` makes a run of its own (of this project, or of another project of the organisation), once for each call, that is not led before its script is read;
## another project is started by the person who started the parent if they may start runs there, or if the project names the parent's project as a caller. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, tables]
import common/[rqlite, scriptsource]
import core/[schema, scheduler, apiauth, groups, projectpolicy, approvals, loggate, logcircuit, runlease]

let url = getEnv("CINIM_RQLITE_URL")

suite "D-93 D-95 ci.trigger":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let slug = "ct" & sfx
    let org = c.addOrganization(slug, "A")
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let prof = c.ensureOrganizationProfile(org, "cinim-001-" & slug)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let now = getTime().toUnix()
    check c.createGroup(org, "ci", now).error.len == 0
    check c.createGroup(org, "team", now).error.len == 0
    check c.createProject(org, "ci/app", "https://example.test/app.git", now).error.len == 0
    check c.createProject(org, "team/deploy", "https://example.test/deploy.git", now).error.len == 0
    let app = c.groupIdOf(org, "ci/app").id
    let dep = c.groupIdOf(org, "team/deploy").id
    check c.setProtectedRefs(dep, @["main"]) == ""
    var n = 0
    proc person(role: string; scope = ""): string =
      inc n
      let name = "t" & sfx & $n
      check c.createUser(name, role, "a-long-password-of-" & name, now, (if scope.len == 0: "org:" & slug else: scope))
      name
    proc reset() =
      discard c.execute(%*[["DELETE FROM role_bindings WHERE scope = ? OR scope LIKE ?", "org:" & slug, "org:" & slug & "/%"]])
      c.setRequiredApprovals(app, 1)
      discard c.setAllowedCallers(dep, @[])
    proc parentRun(actor: string): string =
      co.createRun("return 1", org, prof, @[], groupId = app, source = Source(repository: "https://example.test/app.git", commit: "b".repeat(40), path: ".ci/pipeline.lua", refName: "main"), actor = actor)
    proc rowOf(id: string): JsonNode = co.getRun(id)
    proc pendingOf(id: string): int = c.query(%*[["SELECT script_pending FROM runs WHERE id = ?", id]])["results"][0]["values"][0][0].getInt

    test "a pipeline of this repository: a run of its own at the same commit and ref, started by the same person, not led until its script is read":
      reset()
      let boss = person("rw")
      let p = parentRun("user:" & boss)
      let made = c.startChildRun(co, p, "trigger#0", """{"path":".ci/deploy.lua"}""")
      check made.error == ""
      let r = rowOf(made.id)
      check r["state"].getStr == "QUEUED" and r["source"]["commit"].getStr == "b".repeat(40) and r["source"]["ref"].getStr == "main" and r["source"]["path"].getStr == ".ci/deploy.lua"
      check r["started_by"].getStr == "user:" & boss and r["project"].getStr == "ci/app" and r["trusted"].getBool == false
      check pendingOf(made.id) == 1 and c.takeRunLease("m", made.id, "o") == ""            # no script yet: nobody leads it
      discard c.execute(%*[["UPDATE runs SET script_pending = 0 WHERE id = ?", made.id]])
      check c.takeRunLease("m", made.id, "o").len > 0 and rowOf(made.id)["state"].getStr == "RUNNING"
    test "the same call again (a replay) is the same run, another call is another":
      reset()
      let p = parentRun("user:x")
      let a = c.startChildRun(co, p, "trigger#0", """{"path":".ci/a.lua"}""")
      check c.startChildRun(co, p, "trigger#0", """{"path":".ci/a.lua"}""").id == a.id
      check c.startChildRun(co, p, "trigger#1", """{"path":".ci/a.lua"}""").id != a.id
    test "with approval the run waits in WAITING and asks the project for its number; the one who started the parent does not approve":
      reset()
      let author = person("dev")
      let boss = person("rw")
      c.setRequiredApprovals(app, 1)
      let p = parentRun("user:" & author)
      let made = c.startChildRun(co, p, "trigger#0", """{"path":".ci/deploy.lua","approval":true,"timeout_seconds":600}""")
      check rowOf(made.id)["state"].getStr == "WAITING" and rowOf(made.id)["approval"]["required"].getInt == 1
      check c.answerApproval(made.id, author, "approve", "", now).outcome == aoOwnRun
      check c.answerApproval(made.id, boss, "approve", "", now).outcome == aoApproved
      let alone = parentRun("user:" & boss)
      discard c.execute(%*[["DELETE FROM role_bindings WHERE user_name = ?", author]])
      check rowOf(c.startChildRun(co, alone, "trigger#0", """{"path":".ci/deploy.lua","approval":true}""").id)["state"].getStr == "ABORTED"          # nobody but the author could approve
    test "bad calls are refused with the reason: a path, a ref, parameters, a run with no repository, too many":
      reset()
      let p = parentRun("user:x")
      check c.startChildRun(co, p, "k1", "{").error.startsWith("ci.trigger: {project")
      check c.startChildRun(co, p, "k2", """{"path":"../x"}""").error.contains("path of a pipeline")
      check c.startChildRun(co, p, "k3", """{"path":"a.lua","ref":"a b"}""").error.contains("ref is")
      check c.startChildRun(co, p, "k4", """{}""").error.contains("path of a pipeline in the repository is expected")
      check c.startChildRun(co, p, "k5", """{"path":"a.lua","params":{"x y":"1"}}""").error.startsWith("ci.trigger:")
      let bare = co.createRun("return 1", org, prof, @[], groupId = app, actor = "user:x")
      check c.startChildRun(co, bare, "k6", """{"path":"a.lua"}""").error.contains("not read from a repository")
      for i in 0 ..< maxChildrenOfRun: check c.startChildRun(co, p, "many" & $i, """{"path":"a.lua"}""").error == ""
      check c.startChildRun(co, p, "many-over", """{"path":"a.lua"}""").error.contains("at most")
    test "pipelines that start pipelines go only so deep":
      reset()
      var cur = parentRun("user:x")
      for i in 1 ..< maxRunDepth:
        let made = c.startChildRun(co, cur, "d", """{"path":"a.lua"}""")
        check made.error == ""
        cur = made.id
      check c.startChildRun(co, cur, "d", """{"path":"a.lua"}""").error.contains("deep at most")
    test "another project: refused when nothing allows it, then allowed by the rights of the person who started the parent":
      reset()
      let ann = person("dev", "org:" & slug & "/ci")                 # may start runs under ci, not under team
      let p = parentRun("user:" & ann)
      let call = """{"project":"team/deploy","path":".ci/deploy.lua","ref":"develop"}"""
      check c.startChildRun(co, p, "x1", call).error.contains("does not allow pipelines of ci/app")
      check c.setMember("org:" & slug & "/team/deploy", ann, @["dev"]) == ""
      let made = c.startChildRun(co, p, "x1", call)
      check made.error == ""
      let r = rowOf(made.id)
      check r["project"].getStr == "team/deploy" and r["source"]["repository"].getStr == "https://example.test/deploy.git" and r["source"]["ref"].getStr == "develop" and r["trusted"].getBool == false
    test "a protected ref of the other project needs run.start.protected of the person, or the project's own word":
      reset()
      let ann = person("dev")
      check c.setMember("org:" & slug & "/team/deploy", ann, @["dev"]) == ""
      let p = parentRun("user:" & ann)
      let onMain = """{"project":"team/deploy","path":".ci/deploy.lua","ref":"main"}"""
      check c.startChildRun(co, p, "y1", onMain).error.contains("does not allow")
      check c.setMember("org:" & slug & "/team/deploy", ann, @["rw"]) == ""
      let made = c.startChildRun(co, p, "y1", onMain)
      check made.error == "" and rowOf(made.id)["trusted"].getBool
    test "a project that names the caller allows a run that no person started, and one that does not name it does not":
      reset()
      let p = parentRun("trigger:t1")
      let call = """{"project":"team/deploy","path":".ci/deploy.lua","ref":"main"}"""
      check c.startChildRun(co, p, "z1", call).error.contains("does not allow")
      check c.setAllowedCallers(dep, @["ci/app"]) == ""
      let made = c.startChildRun(co, p, "z1", call)
      check made.error == "" and rowOf(made.id)["trusted"].getBool and rowOf(made.id)["started_by"].getStr == "trigger:t1"
      check c.setAllowedCallers(dep, @["team"]) == ""
      check c.startChildRun(co, p, "z2", call).error.contains("does not allow")
      check c.setAllowedCallers(dep, @["ci"]) == ""                      # a group names all the projects under it
      check c.startChildRun(co, p, "z2", call).error == ""
      check c.setAllowedCallers(dep, @["Bad Path"]) != "" and c.allowedCallers(dep) == @["ci"]
      check c.startChildRun(co, p, "z3", """{"project":"nothing/here","path":"a.lua"}""").error.contains("no project")
