## Triggers (spec 6.3): the body of the creation call and what the API shows. The clock is in tcron.nim, the rows are glue over rqlite.
import std/[unittest, json, strutils]
import core/triggers

proc spec(extra: JsonNode = nil): JsonNode =
  result = %*{"name": "nightly", "kind": "schedule", "schedule": "0 2 * * *", "repository": "https://example.test/org/repo.git"}
  if extra != nil:
    for k, v in extra: result[k] = v

suite "TRG-002 trigger definitions":
  test "D-76 a poll trigger names a repository and a ref, and has no schedule: the core looks at the ref once a minute":
    let r = parseTriggerSpec(%*{"name": "main-poll", "kind": "poll", "repository": "https://example.test/org/repo.git", "ref": "main", "concurrency": "abort_previous"})
    check r.error == "" and r.spec.kind == "poll" and r.spec.ref0 == "main" and r.spec.schedule == ""
    check parseTriggerSpec(%*{"name": "p", "kind": "poll", "repository": "https://example.test/org/repo.git"}).error == ""        # no ref: the head of the repository
    check "schedule" in parseTriggerSpec(%*{"name": "p", "kind": "poll", "repository": "https://example.test/org/repo.git", "schedule": "* * * * *"}).error
    check "repository" in parseTriggerSpec(%*{"name": "p", "kind": "poll"}).error
    check "ref" in parseTriggerSpec(%*{"name": "p", "kind": "poll", "repository": "https://example.test/org/repo.git", "ref": "--x"}).error
  test "TRG-002 a schedule trigger with parameters is accepted":
    let r = parseTriggerSpec(spec(%*{"params": {"BRANCH": "main", "JOBS": 4}, "concurrency": "abort_newest"}))
    check r.error == ""
    check r.spec.kind == "schedule" and r.spec.concurrency == "abort_newest" and r.spec.enabled
    check r.spec.params == @[("BRANCH", "main"), ("JOBS", "4")]

  test "TRG-002 a webhook trigger has no schedule":
    var w = spec(%*{"kind": "webhook"})
    w.delete("schedule")
    check parseTriggerSpec(w).error == ""
    check parseTriggerSpec(spec(%*{"kind": "webhook"})).error.contains("only a schedule")

  test "TRG-002 a bad schedule is refused with the cron reason":
    let r = parseTriggerSpec(spec(%*{"schedule": "61 * * * *"}))
    check r.error.startsWith("schedule: ") and "59" in r.error
    check parseTriggerSpec(spec(%*{"schedule": "daily"})).error.startsWith("schedule: ")

  test "TRG-002 names, kinds, concurrency, project and script are checked":
    check parseTriggerSpec(spec(%*{"name": "Nightly"})).error.contains("name")
    check parseTriggerSpec(spec(%*{"name": ""})).error.contains("name")
    check parseTriggerSpec(spec(%*{"kind": "manual"})).error.contains("kind")
    check parseTriggerSpec(spec(%*{"concurrency": "cancel"})).error.contains("concurrency")
    for ok in ["parallel", "abort_newest", "abort_previous"]:
      let r = parseTriggerSpec(spec(%*{"concurrency": ok}))
      check r.error == "" and r.spec.concurrency == ok
    check parseTriggerSpec(spec(%*{"concurrency": "queue"})).error == "concurrency is parallel, abort_newest or abort_previous"
    check parseTriggerSpec(spec(%*{"group": "/team//backend/"})).spec.groupPath == "team/backend"         # the group is named by its path; the API looks it up
    check parseTriggerSpec(spec()).spec.groupPath == ""                                                    # none: the organisation itself
    check parseTriggerSpec(spec(%*{"group": 5})).error.contains("string")
    check parseTriggerSpec(spec(%*{"repository": ""})).error.contains("repository")
    check parseTriggerSpec(spec(%*{"enabled": "yes"})).error.contains("boolean")
    check parseTriggerSpec(spec(%*{"name": 5})).error.contains("string")
    check parseTriggerSpec(newJArray()).error.len > 0
    check parseTriggerSpec(nil).error.len > 0

  test "VAR-003 the parameters of a trigger follow the rules of launch parameters":
    check parseTriggerSpec(spec(%*{"params": {"PATH": "/x"}})).error.startsWith("params: ")
    check parseTriggerSpec(spec(%*{"params": {"A": [1]}})).error.startsWith("params: ")

  test "TRG-002 the view never shows the secret, its hash or the script":
    let t = TriggerRow(id: "s1_x", slug: "acme", name: "hook", kind: "webhook", secretHash: "deadbeef", script: "secret script",
                       groupPath: "", groupId: "", concurrency: "parallel", enabled: true, params: @[("A", "1")], lastRunId: "s1_r", lastResult: "started")
    let v = view(t)
    check $v notin ["deadbeef"] and "deadbeef" notin $v and "secret script" notin $v
    check v["hook"].getStr == "/api/v1/hooks/s1_x" and v["params"]["A"].getStr == "1" and v["script_bytes"].getInt == 13
    check not v.hasKey("schedule")
    check view(TriggerRow(kind: "schedule", schedule: "@daily"))["schedule"].getStr == "@daily"

suite "D-63 a trigger whose script is in a repository":
  proc repoSpec(extra: JsonNode = nil): JsonNode =
    result = %*{"name": "main-push", "kind": "webhook", "repository": "https://example.test/org/repo.git", "ref": "main"}
    if extra != nil:
      for k, v in extra: result[k] = v
  test "D-63 the repository is what a trigger has; the ref and the path are optional":
    let r = parseTriggerSpec(repoSpec())
    check r.error == "" and r.spec.repository == "https://example.test/org/repo.git" and r.spec.ref0 == "main" and r.spec.script == ""
    check parseTriggerSpec(repoSpec(%*{"path": "ci/p.lua"})).spec.scriptPath == "ci/p.lua"
    check parseTriggerSpec(repoSpec(%*{"ref": ""})).error == ""
  test "D-73 a script is read from git only: a trigger with a script is refused, with or without a repository, and a trigger without a repository too":
    for body in [repoSpec(%*{"script": "return 1"}), spec(%*{"script": "return 1"}), spec(%*{"script": ""})]:
      let r = parseTriggerSpec(body)
      check r.error.contains("script") and r.error.contains("git")
    var none = spec()
    none.delete("repository")
    let r = parseTriggerSpec(none)
    check r.error.contains("repository") and r.error.contains("git")
    var refOnly = spec(%*{"ref": "main"})
    refOnly.delete("repository")
    check parseTriggerSpec(refOnly).error.contains("repository")
  test "D-63 only https and http repositories, names git cannot take for an option, and paths inside the repository":
    for bad in ["ssh://git@example.test/r.git", "file:///etc", "git://example.test/r", "https://exa mple.test/r", "https://"]:
      check parseTriggerSpec(repoSpec(%*{"repository": bad})).error.contains("repository")
    check parseTriggerSpec(repoSpec(%*{"ref": "--upload-pack=x"})).error.contains("ref")
    check parseTriggerSpec(repoSpec(%*{"ref": "a..b"})).error.contains("ref")
    check parseTriggerSpec(repoSpec(%*{"path": "../x"})).error.contains("path")
    check parseTriggerSpec(repoSpec(%*{"path": "/etc/x"})).error.contains("path")
    check parseTriggerSpec(repoSpec(%*{"repository": 5})).error.contains("string")
  test "D-63 the view shows where the script is read from":
    let t = TriggerRow(id: "s1_x", slug: "acme", name: "hook", kind: "webhook", repository: "https://example.test/r.git", ref0: "main", concurrency: "parallel", enabled: true)
    let v = view(t)
    check v["source"]["repository"].getStr == "https://example.test/r.git" and v["source"]["ref"].getStr == "main" and v["source"]["path"].getStr == ".ci/pipeline.lua"

suite "D-63 what a webhook may say":
  let repoTrigger = TriggerRow(repository: "https://example.test/r.git", ref0: "main")
  let plainTrigger = TriggerRow()
  test "D-63 the commit, the trigger's own repository, or nothing":
    check hookCommit(%*{"commit": "3f2c1a9"}, repoTrigger) == (error: "", commit: "3f2c1a9")
    check hookCommit(%*{"commit": "v1.2", "repository": "https://example.test/r.git"}, repoTrigger).commit == "v1.2"
    check hookCommit(newJObject(), repoTrigger) == (error: "", commit: "")
    check hookCommit(newJObject(), plainTrigger) == (error: "", commit: "")
  test "D-63 no params, no other repository, no commit for a script of its own, no name git would take for an option":
    check hookCommit(%*{"params": {"A": "1"}}, repoTrigger).error.contains("no params")
    check hookCommit(%*{"repository": "https://evil.test/x.git"}, repoTrigger).error.contains("cannot point")
    check hookCommit(%*{"commit": "main"}, plainTrigger).error.contains("script of its own")
    check hookCommit(%*{"commit": "--upload-pack=x"}, repoTrigger).error.contains("SHA")
    check hookCommit(%*{"commit": 5}, repoTrigger).error.contains("text")
    check hookCommit(newJArray(), repoTrigger).error.len > 0
    check hookCommit(nil, repoTrigger).error.len > 0
