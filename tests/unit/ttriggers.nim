## Triggers (spec 6.3): the body of the creation call and what the API shows. The clock is in tcron.nim, the rows are glue over rqlite.
import std/[unittest, json, strutils]
import core/triggers

proc spec(extra: JsonNode = nil): JsonNode =
  result = %*{"name": "nightly", "kind": "schedule", "schedule": "0 2 * * *", "project_id": "p1", "script": "return ci.pipeline({main=function() end})"}
  if extra != nil:
    for k, v in extra: result[k] = v

suite "TRG-002 trigger definitions":
  test "TRG-002 a schedule trigger with parameters is accepted":
    let r = parseTriggerSpec(spec(%*{"params": {"BRANCH": "main", "JOBS": 4}, "concurrency": "skip"}))
    check r.error == ""
    check r.spec.kind == "schedule" and r.spec.concurrency == "skip" and r.spec.enabled
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
    check parseTriggerSpec(spec(%*{"project_id": ""})).error.contains("project_id")
    check parseTriggerSpec(spec(%*{"script": ""})).error.contains("script")
    check parseTriggerSpec(spec(%*{"script": "x".repeat(maxScriptBytes + 1)})).error.contains("longer")
    check parseTriggerSpec(spec(%*{"enabled": "yes"})).error.contains("boolean")
    check parseTriggerSpec(spec(%*{"name": 5})).error.contains("string")
    check parseTriggerSpec(newJArray()).error.len > 0
    check parseTriggerSpec(nil).error.len > 0

  test "VAR-003 the parameters of a trigger follow the rules of launch parameters":
    check parseTriggerSpec(spec(%*{"params": {"PATH": "/x"}})).error.startsWith("params: ")
    check parseTriggerSpec(spec(%*{"params": {"A": [1]}})).error.startsWith("params: ")

  test "TRG-002 the view never shows the secret, its hash or the script":
    let t = TriggerRow(id: "s1_x", slug: "acme", name: "hook", kind: "webhook", secretHash: "deadbeef", script: "secret script",
                       projectId: "p", concurrency: "allow", enabled: true, params: @[("A", "1")], lastRunId: "s1_r", lastResult: "started")
    let v = view(t)
    check $v notin ["deadbeef"] and "deadbeef" notin $v and "secret script" notin $v
    check v["hook"].getStr == "/api/v1/hooks/s1_x" and v["params"]["A"].getStr == "1" and v["script_bytes"].getInt == 13
    check not v.hasKey("schedule")
    check view(TriggerRow(kind: "schedule", schedule: "@daily"))["schedule"].getStr == "@daily"
