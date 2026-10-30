## D-93, D-95: ci.trigger in the sandbox: what the script asks of the host (the payload of the `trigger` call), the answer it gets, and what it refuses before the host is asked.
import std/[unittest, options, strutils, json, sequtils]
import executor/[sandbox, journal, replay]

proc run(script: string): tuple[r: ExecResult, calls: seq[(string, string)]] =
  var sb = newSandbox()
  var j = Journal()
  var calls: seq[(string, string)]
  let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
    calls.add (kind, payload)
    if kind == "job_sh": return some("0\nout")
    some("s1_child" & $calls.len)
  (sb.execute(j, script, host), calls)

suite "D-93 D-95 ci.trigger":
  test "a path alone: the host gets it, the id of the run comes back":
    let (r, calls) = run("local id = ci.trigger('.ci/deploy.lua') return id")
    check r.code == "ok" and r.value == "s1_child1" and calls == @[("trigger", """{"path":".ci/deploy.lua"}""")]
  test "approval, its time, the parameters and another project are said in the payload in a fixed order":
    let (r, calls) = run("ci.trigger{ project = 'team/deploy', path = '.ci/d.lua', ref = 'main', approval = { timeout = '2h' }, params = { zeta = 1, alpha = 'x', beta = true } }")
    check r.code == "ok"
    let p = parseJson(calls[0][1])
    check p["project"].getStr == "team/deploy" and p["path"].getStr == ".ci/d.lua" and p["ref"].getStr == "main" and p["approval"].getBool and p["timeout_seconds"].getInt == 7200
    check p["params"]["zeta"].getStr == "1" and p["params"]["beta"].getStr == "true"
    check calls[0][1].find("\"alpha\"") < calls[0][1].find("\"beta\"") and calls[0][1].find("\"beta\"") < calls[0][1].find("\"zeta\"")
  test "approval = true takes the project's time; false and nothing are no approval":
    check run("ci.trigger('a.lua', { approval = true })").calls[0][1] == """{"path":"a.lua","approval":true}"""
    check run("ci.trigger('a.lua', { approval = false })").calls[0][1] == """{"path":"a.lua"}"""
  test "a bad call is the author's error and the host is not asked":
    for bad in ["ci.trigger()", "ci.trigger(1)", "ci.trigger('')", "ci.trigger('a.lua', 5)", "ci.trigger('a.lua', { nope = 1 })", "ci.trigger('a.lua', { approval = 'yes' })",
                "ci.trigger('a.lua', { approval = { timeout = 'soon' } })", "ci.trigger('a.lua', { params = 5 })", "ci.trigger('a.lua', { params = { x = {} } })",
                "ci.trigger{ project = '' , path = 'a.lua' }", "ci.trigger{ ref = 'main' }", "ci.trigger('a.lua', { ref = 5 })"]:
      let (r, calls) = run(bad)
      check r.code == "script_error" and calls.len == 0
  test "the call is journaled: a replay gets the same id and the host is not asked again":
    var sb = newSandbox()
    var j = Journal()
    var asked = 0
    let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
      inc asked
      some("s1_once")
    check sb.execute(j, "return ci.trigger('a.lua')", host).value == "s1_once"
    var sb2 = newSandbox()
    check sb2.execute(j, "return ci.trigger('a.lua')", host).value == "s1_once" and asked == 1

suite "D-99 api on a step":
  test "a step that names the permissions of the API asks for the token the way it asks for a secret":
    let (r, calls) = run("ci.single['01']{ image = 'a', body = function(j) j:run(step.sh['0a']{ cmd = 'x', api = { 'run.read', 'log.read' } }) end }")
    check r.code == "ok"
    let opts = calls.filterIt(it[0] == "job_sh")[0][1]
    check "\"api\":[\"log.read\",\"run.read\"]" in opts and "\"secrets\":[\"CINIM_API_TOKEN\"]" in opts
  test "a bad list of permissions is the author\'s error":
    for bad in ["api = 'run.read'", "api = {}", "api = { 5 }", "api = { 'Run Read' }"]:
      let (r, _) = run("ci.single['01']{ image = 'a', body = function(j) j:run(step.sh['0a']{ cmd = 'x', " & bad & " }) end }")
      check r.code == "script_error"
