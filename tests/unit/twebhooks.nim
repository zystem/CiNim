## D-111: outbound webhooks. The pure part: what a webhook is (its address, which events, the name of a secret that signs), the body of each event, the signature, the pause between tries, and the
## addresses the shard allows. The rows and the sending are in tests/integration/twebhooks.nim.
import std/[unittest, json, strutils, sequtils]
import core/webhooks

let allowed = @["hooks.example.org", "10.1.2.3:9000", "ci.lan"]

proc spec(extra: JsonNode = nil): JsonNode =
  result = %*{"name": "mine", "url": "http://ci.lan:8080/in"}
  if extra != nil:
    for k, v in extra: result[k] = v

suite "D-111 what a webhook is":
  test "a name and an address are enough: the events are the three, it is on, and it is the whole organisation's":
    let p = parseWebhookSpec(spec(), allowed)
    check p.error == "" and p.spec.name == "mine" and p.spec.url == "http://ci.lan:8080/in"
    check p.spec.events == @["run.started", "step.failed", "run.finished"] and p.spec.enabled and p.spec.groupPath == "" and p.spec.secret == ""
  test "the events can be chosen, and only the known ones":
    check parseWebhookSpec(spec(%*{"events": ["run.finished"]}), allowed).spec.events == @["run.finished"]
    check parseWebhookSpec(spec(%*{"events": ["run.finished", "run.finished"]}), allowed).spec.events == @["run.finished"]
    check "events" in parseWebhookSpec(spec(%*{"events": ["run.exploded"]}), allowed).error
    check "events" in parseWebhookSpec(spec(%*{"events": []}), allowed).error
    check "events" in parseWebhookSpec(spec(%*{"events": "run.finished"}), allowed).error
  test "the name is a name":
    for bad in ["", "Has Space", "a".repeat(65), "x/y"]:
      check "name" in parseWebhookSpec(spec(%*{"name": bad}), allowed).error
  test "the project is a path of names of groups, and the secret is the name of a secret":
    check parseWebhookSpec(spec(%*{"project": "ci/cinim"}), allowed).spec.groupPath == "ci/cinim"
    check "project" in parseWebhookSpec(spec(%*{"project": "Bad Path"}), allowed).error
    check parseWebhookSpec(spec(%*{"secret": "HOOK_KEY"}), allowed).spec.secret == "HOOK_KEY"
    check "secret" in parseWebhookSpec(spec(%*{"secret": "has space"}), allowed).error
    check "secret" in parseWebhookSpec(spec(%*{"secret": 5}), allowed).error
  test "enabled is a boolean":
    check not parseWebhookSpec(spec(%*{"enabled": false}), allowed).spec.enabled
    check "enabled" in parseWebhookSpec(spec(%*{"enabled": "no"}), allowed).error
  test "a body that is not an object, and a field that is not one, are refused":
    check parseWebhookSpec(nil, allowed).error != ""
    check parseWebhookSpec(%*[1], allowed).error != ""
    check "unknown field" in parseWebhookSpec(spec(%*{"colour": "red"}), allowed).error

suite "D-111 the addresses the shard allows (the core sends only there: whoever sets a webhook must not point it at what is inside the cluster)":
  test "the host, or the host with its port, as the shard lists it, over http or https":
    check urlAllowed("http://ci.lan:8080/in", allowed) == ""            # a host listed without a port: any port
    check urlAllowed("https://hooks.example.org/a/b?x=1", allowed) == ""
    check urlAllowed("http://10.1.2.3:9000/x", allowed) == ""
    check urlAllowed("http://10.1.2.3:9001/x", allowed) != ""          # listed with a port: that port only
    check urlAllowed("HTTP://CI.LAN/x", allowed) == ""                  # the host and the scheme have no case
  test "everything else is refused, with the reason":
    check "allow" in urlAllowed("http://evil.example.com/x", allowed)
    check urlAllowed("http://ci.lan.evil.com/x", allowed) != ""          # a host that only starts like a listed one
    check urlAllowed("http://evil.com@ci.lan/x", allowed) != ""          # a login in the address hides the host
    check urlAllowed("ftp://ci.lan/x", allowed) != "" and urlAllowed("ci.lan/x", allowed) != "" and urlAllowed("", allowed) != ""
    check urlAllowed("http://ci.lan/x y", allowed) != ""
    check urlAllowed("http://ci.lan/" & "a".repeat(500), allowed) != ""
  test "a shard that lists nothing allows nothing, and says so":
    let why = urlAllowed("http://ci.lan/x", @[])
    check why != "" and "CINIM_WEBHOOK_HOSTS" in why
    check "CINIM_WEBHOOK_HOSTS" in parseWebhookSpec(spec(), @[]).error
  test "a webhook refuses the address on the way in":
    check "allow" in parseWebhookSpec(spec(%*{"url": "http://evil.example.com/x"}), allowed).error

suite "D-111 the signature and the pauses":
  test "the signature is the HMAC-SHA256 of the body under the secret, in the form GitHub uses":
    check signature("key", "The quick brown fox jumps over the lazy dog") == "sha256=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
    check signature("other", "x") != signature("key", "x") and signature("key", "x") != signature("key", "y")
  test "after a refusal the next try is later: 30 s, then twice as long each time, at most an hour; after the last try there is no other":
    check (0 .. 7).mapIt(backoffSeconds(it)) == @[30'i64, 60, 120, 240, 480, 960, 1920, 3600]
    check backoffSeconds(40) == 3600
    check maxAttempts == 8

suite "D-111 the events and their bodies":
  let run = RunFacts(id: "s1_run", organization: "selfci", project: "ci/cinim", state: "RUNNING", commit: "a".repeat(40), refName: "main", repository: "https://x/r.git",
                     triggerId: "s1_trg", createdAt: 1793921212, failCode: "", failMessage: "")
  test "a run has started when it is no longer queued or waiting; it has finished in a final state":
    for s in ["CREATED", "COMPILING", "QUEUED", "WAITING"]: check not hasStarted(s)
    for s in ["RUNNING", "OK", "FAILED", "ABORTED", "TIMED_OUT", "INFRASTRUCTURE_ERROR", "SKIPPED"]: check hasStarted(s)
    for s in ["OK", "FAILED", "ABORTED", "TIMED_OUT", "INFRASTRUCTURE_ERROR", "SKIPPED"]: check hasFinished(s)
    for s in ["CREATED", "QUEUED", "RUNNING", "WAITING"]: check not hasFinished(s)
  test "the ids of a step in the words of the log: job and step in base 32 (D-77)":
    check stepIds(28311556) == ("0v", "0004")
    check stepIds(13631491) == ("0d", "0003")
    check stepIds(1048576 + 1) == ("01", "0001")
  test "the body of a run event: what, where, which commit, which ref, and a link when the shard has an address":
    let b = eventBody("run.started", "dlv1", run, 1793921300, "https://ci.example.org")
    check b["event"].getStr == "run.started" and b["delivery"].getStr == "dlv1" and b["time"].getInt == 1793921300
    check b["organization"].getStr == "selfci" and b["project"].getStr == "ci/cinim"
    check b["run"]["id"].getStr == "s1_run" and b["run"]["state"].getStr == "RUNNING" and b["run"]["commit"].getStr == "a".repeat(40)
    check b["run"]["ref"].getStr == "main" and b["run"]["repository"].getStr == "https://x/r.git" and b["run"]["trigger_id"].getStr == "s1_trg"
    check b["run"]["link"].getStr == "https://ci.example.org/runs/s1_run"
    check not b.hasKey("step") and not b.hasKey("failure")
    check not eventBody("run.started", "d", run, 1, "")["run"].hasKey("link")
  test "the finish of a run that failed carries the failure":
    var r = run
    r.state = "FAILED"
    r.failCode = "script_error"
    r.failMessage = "parallel: branches failed: tests"
    let b = eventBody("run.finished", "d", r, 1, "")
    check b["run"]["state"].getStr == "FAILED" and b["failure"]["code"].getStr == "script_error" and "tests" in b["failure"]["message"].getStr
    var ok = run
    ok.state = "OK"
    check not eventBody("run.finished", "d", ok, 1, "").hasKey("failure")
  test "the body of a failed step: its ids, the number, the exit code, the way it ended":
    let st = StepFacts(number: 28311556, attempt: 1, exitCode: 124, termination: "timeout")
    let b = eventBody("step.failed", "d", run, 1, "", st)
    check b["step"]["job_id"].getStr == "0v" and b["step"]["step_id"].getStr == "0004" and b["step"]["number"].getInt == 28311556
    check b["step"]["exit_code"].getInt == 124 and b["step"]["termination"].getStr == "timeout" and b["step"]["attempt"].getInt == 1
  test "the ping, which a person sends to see that the address answers, is a body of its own":
    let b = pingBody("d", "selfci", 5)
    check b["event"].getStr == "ping" and b["organization"].getStr == "selfci" and not b.hasKey("run")
  test "the view of a webhook shows what it is and never a secret's value (it holds the name of one)":
    let w = WebhookRow(id: "wh_1", slug: "selfci", name: "mine", url: "http://ci.lan/in", secret: "HOOK_KEY", groupPath: "ci/cinim", events: @["run.finished"], enabled: true, createdAt: 3)
    let v = view(w)
    check v["id"].getStr == "wh_1" and v["secret"].getStr == "HOOK_KEY" and v["project"].getStr == "ci/cinim" and v["events"][0].getStr == "run.finished" and v["enabled"].getBool

suite "D-111 a webhook is changed: the address, the secret, the events, on or off":
  let cur = WebhookRow(id: "wh_1", slug: "selfci", name: "mine", url: "http://ci.lan/in", secret: "HOOK_KEY", groupPath: "ci/cinim", events: @["run.finished"], enabled: true)
  test "the fields named change, the rest stay, and the result is checked as a webhook that is made":
    let u = parseWebhookUpdate(%*{"url": "https://hooks.example.org/new", "enabled": false}, cur, allowed)
    check u.error == "" and u.spec.url == "https://hooks.example.org/new" and not u.spec.enabled
    check u.spec.name == "mine" and u.spec.secret == "HOOK_KEY" and u.spec.events == @["run.finished"] and u.spec.groupPath == "ci/cinim"
  test "an empty secret takes the signature off, and the events can be replaced":
    check parseWebhookUpdate(%*{"secret": ""}, cur, allowed).spec.secret == ""
    check parseWebhookUpdate(%*{"events": ["run.started", "step.failed"]}, cur, allowed).spec.events == @["run.started", "step.failed"]
  test "the name and the project are not changed here (the deliveries written for a webhook belong to them), and the words say so":
    for k in ["name", "project"]:
      let u = parseWebhookUpdate(%*{k: "other"}, cur, allowed)
      check u.error.startsWith(k & " cannot be changed")
  test "a refused address, an event that does not exist, nothing to change and an unknown field are refused":
    check "allow" in parseWebhookUpdate(%*{"url": "http://evil.example.com/x"}, cur, allowed).error
    check "events" in parseWebhookUpdate(%*{"events": ["run.exploded"]}, cur, allowed).error
    check "nothing to change" in parseWebhookUpdate(%*{}, cur, allowed).error
    check "unknown field" in parseWebhookUpdate(%*{"colour": "red"}, cur, allowed).error
    check parseWebhookUpdate(nil, cur, allowed).error != ""
  test "a webhook whose address the shard stopped allowing can still be switched off or have its address replaced":
    check parseWebhookUpdate(%*{"enabled": false, "url": "http://ci.lan/in"}, cur, allowed).error == ""
    let gone = WebhookRow(name: "mine", url: "http://old.example.org/in", events: @["run.finished"], enabled: true)
    check parseWebhookUpdate(%*{"url": "http://ci.lan/in"}, gone, allowed).error == ""
    check parseWebhookUpdate(%*{"enabled": false}, gone, allowed).error == ""
