## Real Lua API v1 subset : ci.pipeline/ci.job/Job:sh on top of the same journal/replay
## mechanics proven in tjournal.nim. The ci.sh fixture (tests/unit/support/fixture.nim) is separate
## and keeps testing sandbox/journal mechanics; this file tests the new host-call shape and run_id threading.
import std/[unittest, options, strutils]
import executor/[sandbox, journal, replay]

proc fakeHost(seq: int; kind, payload: string): Option[string] =
  case kind
  of "job_sh":
    let parts = payload.split('\t', 4)         # key, image, profile, options, command
    if parts[4] == "fail": some("1\n")
    else: some("0\nout-" & $seq)
  of "now": some("1000")
  else: some("")

const pipelineOneStep = """
return ci.pipeline({
  name = "p",
  main = function(run)
    local seen_run_id = run.run_id
    local r
    ci.single['01']{ image = "alpine", body = function(j)
      r = j:run(step.sh['1']{ cmd = "echo hi" })
     end }
    return seen_run_id .. "|" .. tostring(r.code)
  end,
})
"""

const pipelineTwoJobs = """
return ci.pipeline({
  main = function(run)
    local keys = {}
    ci.single['02']{ image = "a", body = function(j) j:run(step.sh['1']{ cmd = "one" })  end }
    ci.single['03']{ image = "b", body = function(j) j:run(step.sh['1']{ cmd = "two" })  end }
    return "ok"
  end,
})
"""

const pipelineJobFails = """
return ci.pipeline({
  main = function(run)
    local ok, err = pcall(function()
      ci.single['04']{ image = "a", body = function(j)
        local r = j:run(step.sh['1']{ cmd = "fail" })
        if r.code ~= 0 then error("step failed") end
       end }
    end)
    return tostring(ok)
  end,
})
"""

const pipelineStepFails = """
return ci.pipeline({
  main = function(run)
    ci.single['05']{ image = "a", body = function(j) j:run(step.sh['1']{ cmd = "fail" })  end }
    return "not reached"
  end,
})
"""

const pipelineIgnoreFailure = """
return ci.pipeline({
  main = function(run)
    local r
    ci.single['06']{ image = "a", body = function(j) r = j:run(step.sh['1']{ cmd = "fail", ignore_failure = true })  end }
    return "code=" .. tostring(r.code)
  end,
})
"""

suite "real Lua API (ci.pipeline, ci.job, Job:sh)":
  test "6.7: a step that exits non-zero fails the job and the run, and the replay fails at the same call":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, pipelineStepFails, fakeHost, runId = "s1_abc")
    check r.code == "script_error"
    check "step failed with code 1" in r.message
    check j.entries.len == 1 and j.entries[0].kind == "job_sh"
    var sb2 = newSandbox()
    let again = sb2.execute(j, pipelineStepFails, fakeHost, runId = "s1_abc")
    check again.code == "script_error" and j.entries.len == 1          # nothing new is called: the journal answers

  test "6.7: ignore_failure returns the non-zero code to the script instead":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, pipelineIgnoreFailure, fakeHost, runId = "s1_abc")
    check r.code == "ok" and r.value == "code=1"

  test "6.7: ignore_failure must be a boolean":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['07']{ image = 'a', body = function(j) j:run(step.sh['1']{ cmd = 'x', ignore_failure = 'yes' })  end } end})", fakeHost, runId = "s1_abc")
    check r.code == "script_error" and "ignore_failure" in r.message

  test "6.7: secrets are names in the journalled options, sorted, a job's and a step's together, no repeats":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['08']{ image = 'a', secrets = {'REGISTRY_PASSWORD', 'A_TOKEN'}, body = function(j) j:run(step.sh['1']{ cmd = 'x', secrets = {'A_TOKEN', 'DEPLOY_KEY'} })  end } end})", fakeHost, runId = "s1_abc")
    check r.code == "ok"
    check j.entries[0].payload == "08\ta\t\t{\"secrets\":[\"A_TOKEN\",\"DEPLOY_KEY\",\"REGISTRY_PASSWORD\"]}\tx"

  test "6.7: a step without secrets has no secrets key":
    var sb = newSandbox()
    var j = Journal()
    discard sb.execute(j, pipelineOneStep, fakeHost, runId = "s1_abc")
    check "secrets" notin j.entries[0].payload

  test "VAR-004 the env of the pipeline, of the job, of j:env and of the step are in the journalled options: the first three together as env (the pipeline's under the job's), the step's apart":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, "return ci.pipeline({env = {A = 'pipeline', B = 'pipeline'}, main = function(run) ci.single['09']{ image = 'a', env = {B = 'job', C = 3}, body = function(j) j:run(step.sh['1']{ cmd = 'x' }); j:env({D = true, A = 'later'}); j:run(step.sh['2']{ cmd = 'y', env = {E = 'step', B = 'step'} })  end } end})", fakeHost, runId = "s1_abc")
    check r.code == "ok"
    check j.entries[0].payload == "09\ta\t\t{\"env\":{\"A\":\"pipeline\",\"B\":\"job\",\"C\":\"3\"}}\tx"
    check j.entries[1].payload == "09\ta\t\t{\"env\":{\"A\":\"later\",\"B\":\"job\",\"C\":\"3\",\"D\":\"true\"},\"step_env\":{\"B\":\"step\",\"E\":\"step\"}}\ty"
  test "VAR-004 a step with no env has no env key, so the journal of an older run still replays":
    var sb = newSandbox()
    var j = Journal()
    discard sb.execute(j, pipelineOneStep, fakeHost, runId = "s1_abc")
    check "env" notin j.entries[0].payload
  test "VAR-004 a name that is not an environment name, a value that is not text, a control character and too many variables are refused before the run goes on":
    for bad in ["{lower = 'x'}", "{['1A'] = 'x'}", "{A = {}}", "{A = 'x\\1'}", "{A = string.rep('x', 9000)}", "'text'"]:
      var sb = newSandbox()
      var j = Journal()
      let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['01']{ image = 'a', env = " & bad & ", body = function(j) j:run(step.sh['1']{ cmd = 'x' }) end } end})", fakeHost, runId = "s1_abc")
      check r.code == "script_error" and "env" in r.message
    var sb = newSandbox()
    var j = Journal()
    let many = sb.execute(j, "local t = {} for i = 1, 101 do t['V' .. i] = 'x' end return ci.pipeline({main = function(run) ci.single['0a']{ image = 'a', body = function(j) j:env(t)  end } end})", fakeHost, runId = "s1_abc")
    check many.code == "script_error" and "at most 100" in many.message

  test "DAT-004 the cache of a step is in the journalled options: a table or a list, a job's and a step's together, the same key is the step's":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['0b']{ image = 'a', cache = {key = 'deps-1', paths = {'node_modules'}, restore_keys = {'deps-'}}, body = function(j) j:run(step.sh['1']{ cmd = 'x' }); j:run(step.sh['2']{ cmd = 'y', cache = {{key = 'deps-1', paths = {'other'}}, {key = 'pip', paths = {'.pip', 'wheels/a'}}} })  end } end})", fakeHost, runId = "s1_abc")
    check r.code == "ok"
    check j.entries[0].payload == "0b\ta\t\t{\"cache\":[{\"key\":\"deps-1\",\"paths\":[\"node_modules\"],\"restore_keys\":[\"deps-\"]}]}\tx"
    check j.entries[1].payload == "0b\ta\t\t{\"cache\":[{\"key\":\"deps-1\",\"paths\":[\"other\"],\"restore_keys\":[]},{\"key\":\"pip\",\"paths\":[\".pip\",\"wheels/a\"],\"restore_keys\":[]}]}\ty"
  test "DAT-004 a key with a slash, no paths, a path outside the workspace, an unknown field and too many caches are refused before the run goes on":
    for bad in ["{key = 'a/b', paths = {'x'}}", "{key = 'a', paths = {}}", "{key = 'a'}", "{key = 'a', paths = {'/etc'}}", "{key = 'a', paths = {'../x'}}", "{key = 'a', paths = {'x'}, mode = 1}",
                "{key = 'a', paths = {'x'}, restore_keys = {'a/'}}", "{key = '', paths = {'x'}}", "'text'",
                "{{key='1',paths={'x'}},{key='2',paths={'x'}},{key='3',paths={'x'}},{key='4',paths={'x'}},{key='5',paths={'x'}}}"]:
      var sb = newSandbox()
      var j = Journal()
      let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['01']{ image = 'a', body = function(j) j:run(step.sh['1']{ cmd = 'x', cache = " & bad & " }) end } end})", fakeHost, runId = "s1_abc")
      check r.code == "script_error" and "cache" in r.message
  test "DAT-004 j.cache.restore and j.cache.save are steps of their own with the mode in the cache options; the answer of a restore is the key the host gave":
    var sb = newSandbox()
    var j = Journal()
    let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] = some("0\ndeps-1")
    let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['0c']{ image = 'a', cache = {key = 'base', paths = {'b'}}, body = function(j) local got = j:run(step.cache_restore['1']{ keys = {'deps-2', 'deps-'} }); j:run(step.cache_save['2']{ key = 'deps-2', paths = {'node_modules', 'x/y'} }); j:run(step.sh['3']{ cmd = 'after ' .. tostring(got.hit) .. ' ' .. tostring(got.key) })  end } end})", host, runId = "s1_abc")
    check r.code == "ok"
    check j.entries[0].kind == "job_sh" and j.entries[0].payload == "0c\ta\t\t{\"cache\":[{\"key\":\"deps-2\",\"mode\":\"restore\",\"paths\":[],\"restore_keys\":[\"deps-\"]}]}\ttrue"
    check j.entries[1].payload == "0c\ta\t\t{\"cache\":[{\"key\":\"deps-2\",\"mode\":\"save\",\"paths\":[\"node_modules\",\"x/y\"],\"restore_keys\":[]}]}\ttrue"
    check "\"key\":\"base\"" in j.entries[2].payload and "mode" notin j.entries[2].payload and j.entries[2].payload.endsWith("\tafter true deps-1")   # the job's own cache option belongs to the steps of j:sh only
  test "DAT-004 j.cache.restore tells a hit from a miss, and a failing step fails the job":
    for (answer, hit, key) in [("0\ndeps-1", true, "deps-1"), ("0\n", false, "nil")]:
      var sb = newSandbox()
      var j = Journal()
      let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] = some(answer)
      let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['0d']{ image = 'a', body = function(j) local got = j:run(step.cache_restore['1']{ keys = {'deps-1'} }); j:run(step.sh['2']{ cmd = 'hit=' .. tostring(got.hit) .. ' key=' .. tostring(got.key) })  end } end})", host, runId = "s1_abc")
      check r.code == "ok"
      check j.entries[1].payload.endsWith("\thit=" & $hit & " key=" & key)
    var sb = newSandbox()
    var j = Journal()
    let failing: HostCallProc = proc (seq: int; kind, payload: string): Option[string] = some("3\n")
    let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['0e']{ image = 'a', body = function(j) j:run(step.cache_save['1']{ key = 'k', paths = {'x'} })  end } end})", failing, runId = "s1_abc")
    check r.code == "script_error" and "step failed with code 3" in r.message
  test "DAT-004 j.cache.restore and j.cache.save refuse what the option refuses before a step is made":
    for bad in ["j:run(step.cache_restore['1']{ keys = {} })", "j:run(step.cache_restore['1']{ keys = 'deps' })", "j:run(step.cache_restore['1']{ keys = {'a/b'} })",
                "j:run(step.cache_restore['1']{ keys = {'a','b','c','d','e','f','g'} })", "j:run(step.cache_save['1']{ key = 'a/b', paths = {'x'} })",
                "j:run(step.cache_save['1']{ key = 'a', paths = {} })", "j:run(step.cache_save['1']{ key = 'a' })", "j:run(step.cache_save['1']{ key = 'a', paths = {'../x'} })",
                "j:run(step.cache_save['1']{ key = 'a', paths = {'/etc'} })"]:
      var sb = newSandbox()
      var j = Journal()
      let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['01']{ image = 'a', body = function(j) " & bad & " end } end})", fakeHost, runId = "s1_abc")
      check r.code == "script_error" and ("ache" in r.message)
      check j.entries.len == 0
  test "a call that the core refuses for good fails the run with the core's words; it is not suspended":
    var sb = newSandbox()
    var j = Journal()
    let refusing: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
      raise (ref HostRefusal)(code: "script_error", msg: "the organisation has no secret DEPLOY_KEY")
    let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['0f']{ image = 'a', body = function(j) j:run(step.sh['1']{ cmd = 'x' })  end } end})", refusing, runId = "s1_abc")
    check r.status == esFailed and r.code == "script_error" and "no secret DEPLOY_KEY" in r.message
    check j.entries.len == 0                      # nothing was journalled: the refusal is not a result

  test "6.7: a secret name is a capital-letter environment name; anything else is refused before the run goes on":
    for bad in ["'lower'", "'1ABC'", "'A-B'", "42", "'" & "A".repeat(65) & "'", "{}"]:
      var sb = newSandbox()
      var j = Journal()
      let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['01']{ image = 'a', body = function(j) j:run(step.sh['1']{ cmd = 'x', secrets = {" & bad & "} }) end } end})", fakeHost, runId = "s1_abc")
      check r.code == "script_error" and "secrets" in r.message
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['0g']{ image = 'a', secrets = 'X', body = function(j) j:run(step.sh['1']{ cmd = 'x' })  end } end})", fakeHost, runId = "s1_abc")
    check r.code == "script_error" and "secrets" in r.message

  test "run.run_id reaches main(), Job:sh yields job_sh and returns StepResult.code":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, pipelineOneStep, fakeHost, runId = "s1_abc")
    check r.code == "ok"
    check r.value == "s1_abc|0"
    check j.entries.len == 1
    check j.entries[0].kind == "job_sh"
    check j.entries[0].payload == "01\talpine\t\t\techo hi"

  test "RUN-004, A.13: a job may ask for the build profile; the profile is a field of the journalled call":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, """return ci.pipeline({ main = function(run)
      ci.single['0h']{ image = "kaniko", profile = "build", body = function(j) j:run(step.sh['1']{ cmd = "build" })  end }
      ci.single['0j']{ image = "a", profile = "default", body = function(j) j:run(step.sh['1']{ cmd = "plain" })  end }
      return "ok" end })""", fakeHost)
    check r.code == "ok"
    check j.entries[0].payload == "0h\tkaniko\tbuild\t\tbuild"
    check j.entries[1].payload == "0j\ta\t\t\tplain"       # "default" is the ordinary profile: the field is empty
  test "D-48: a job may ask for the deploy profile too":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, """return ci.pipeline({ main = function(run)
      ci.single['0k']{ image = "alpine/k8s", profile = "deploy", body = function(j) j:run(step.sh['1']{ cmd = "kubectl version" })  end }
      return "ok" end })""", fakeHost)
    check r.code == "ok"
    check j.entries[0].payload == "0k\talpine/k8s\tdeploy\t\tkubectl version"
  test "an unknown profile is a script error":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, """return ci.pipeline({ main = function(run)
      ci.single['0m']{ image = "a", profile = "privileged", body = function(j) j:run(step.sh['1']{ cmd = "x" })  end }
      return "ok" end })""", fakeHost)
    check r.code != "ok"
  test "the key of a job is its id (D-67), and a step is told by one number made of the ids":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, pipelineTwoJobs, fakeHost)
    check r.code == "ok"
    check j.entries.len == 2
    check j.entries[0].payload == "02\ta\t\t\tone"
    check j.entries[1].payload == "03\tb\t\t\ttwo"

  test "a failing step's StepResult.code lets the script fail its own job with pcall":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, pipelineJobFails, fakeHost)
    check r.code == "ok"
    check r.value == "false"     # pcall caught the script's own error("step failed")

  test "replay of a ci.pipeline script makes no host calls and gives the same result":
    var sb = newSandbox()
    var j = Journal()
    let r1 = sb.execute(j, pipelineOneStep, fakeHost, runId = "s1_abc")
    var calls = 0
    let counting: HostCallProc = proc(seq: int; kind, payload: string): Option[string] =
      inc calls
      fakeHost(seq, kind, payload)
    var sb2 = newSandbox()
    var j2 = j
    let r2 = sb2.execute(j2, pipelineOneStep, counting, runId = "s1_abc")
    check calls == 0
    check r2.value == r1.value and r2.code == "ok"

  test "a plain-return script (no ci.pipeline) still works, run argument ignored":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, "return ci.now()", fakeHost, runId = "ignored")
    check r.code == "ok"
    check r.value == "1000"

const pipelineMetrics = """
return ci.pipeline({
  main = function(run)
    ci.single['01']{ image = "a", metrics = {runtime = "jvm"}, body = function(j)
      j:run(step.sh['1']{ cmd = "one" })                                                   -- inherits the job's declaration
      j:run(step.sh['2']{ cmd = "two", metrics = {scrape = {{url = "http://127.0.0.1:9404/metrics", interval = "10s", include = {"jvm_*"}}}} })
      j:run(step.sh['3']{ cmd = "three", metrics = false })                              -- switched off for this step
    end }
    return "ok"
  end,
})
"""

proc metricsRun(body: string): tuple[code, value: string] =
  var sb = newSandbox()
  var j = Journal()
  let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['01']{ image = 'a', body = function(j) " & body &
    " end } return 'ok' end})", fakeHost)
  (r.code, r.value & r.message)

suite "application metrics declaration (docs/metrics.md)":
  test "canonical JSON per step; the job's declaration is inherited, replaced or switched off":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, pipelineMetrics, fakeHost)
    check r.code == "ok"
    check j.entries.len == 3
    check j.entries[0].payload == "01\ta\t\t" & """{"metrics":{"runtime":"jvm","scrape":[]}}""" & "\tone"
    check j.entries[1].payload == "01\ta\t\t" &
      """{"metrics":{"runtime":"none","scrape":[{"format":"prometheus","include":["jvm_*"],"interval":10,"name":"app1","timeout":5,"url":"http://127.0.0.1:9404/metrics"}]}}""" & "\ttwo"
    check j.entries[2].payload == "01\ta\t\t\tthree"
  test "only the step's own Pod may be scraped":
    for url in ["http://example.com/metrics", "http://10.0.0.5:9000/", "https://127.0.0.1/m", "http://127.0.0.1.evil.com/m"]:
      check metricsRun("j:run(step.sh['1']{ cmd = 'x', metrics = {scrape = {{url = '" & url & "'}}}})").code != "ok"
    check metricsRun("j:run(step.sh['1']{ cmd = 'x', metrics = {scrape = {{url = 'http://localhost:8080/m'}}}})").code == "ok"
    check metricsRun("j:run(step.sh['1']{ cmd = 'x', metrics = {scrape = {{url = 'http://[::1]:8080/m'}}}})").code == "ok"
  test "bad declarations fail before anything runs":
    for m in ["{runtime = 'cobol'}", "{scrape = {{url = 'http://127.0.0.1/m', interval = 0}}}",
              "{scrape = {{url = 'http://127.0.0.1/m', interval = '5s', timeout = '9s'}}}",
              "{scrape = {{url = 'http://127.0.0.1/m', format = 'xml'}}}",
              "{scrape = {{url = 'http://127.0.0.1/m', name = 'Bad Name'}}}",
              "{scrape = {{url = 'http://127.0.0.1/m', include = {'a b'}}}}",
              "{scrape = {{url = 'http://127.0.0.1/m'}, {url = 'http://127.0.0.1/m'}, {url = 'http://127.0.0.1/m'}, {url = 'http://127.0.0.1/m'}, {url = 'http://127.0.0.1/m'}}}",
              "{unknown = 1}", "{scrape = {{url = 'http://127.0.0.1/m', typo = 1}}}", "'text'"]:
      check metricsRun("j:run(step.sh['1']{ cmd = 'x', metrics = " & m & "})").code != "ok"

suite "step options: mask and timeout (docs/secrets-masking.md)":
  test "mask, metrics and timeout travel as one canonical object, keys sorted, job defaults inherited per key":
    var sb = newSandbox()
    var j = Journal()
    let script = """
      return ci.pipeline({main = function(run)
        ci.single['0n']{ image = "a", timeout = "10m", mask = {min_length = 8}, body = function(j)
          j:run(step.sh['1']{ cmd = "one" })
          j:run(step.sh['2']{ cmd = "two", timeout = 90, mask = false })
          j:run(step.sh['3']{ cmd = "three", metrics = {runtime = "jvm"} })
         end }
        return "ok"
      end})"""
    check sb.execute(j, script, fakeHost).code == "ok"
    check j.entries[0].payload == "0n\ta\t\t" & """{"mask":{"min_length":8,"runtime":true,"variants":true},"timeout":600}""" & "\tone"
    check j.entries[1].payload == "0n\ta\t\t" & """{"mask":{"min_length":4,"runtime":false,"variants":false},"timeout":90}""" & "\ttwo"
    check j.entries[2].payload == "0n\ta\t\t" & """{"mask":{"min_length":8,"runtime":true,"variants":true},"metrics":{"runtime":"jvm","scrape":[]},"timeout":600}""" & "\tthree"
  test "nothing set -> no options at all (the shim's defaults apply: runtime values and variants on)":
    var sb = newSandbox()
    var j = Journal()
    check sb.execute(j, pipelineOneStep, fakeHost).code == "ok"
    check j.entries[0].payload == "01\talpine\t\t\techo hi"
  test "bad mask and timeout fail before anything runs":
    for o in ["{mask = 'yes'}", "{mask = {runtime = 'x'}}", "{mask = {min_length = 2}}", "{mask = {typo = 1}}",
              "{timeout = 0}", "{timeout = '5x'}", "{timeout = 100000}"]:
      check metricsRun("j:run(step.sh['1']{ cmd = 'x', " & o[1 ..< o.len - 1] & " })").code != "ok"

suite "PIP-014 the lock of a job (ci.job{lock = ...})":
  const lockedJob = "return ci.pipeline({main = function(run) ci.single['0p']{ image = 'a', lock = 'stand', body = function(j) j:run(step.sh['1']{ cmd = 'deploy' }) j:run(step.sh['2']{ cmd = 'test' })  end } return 'done' end})"
  proc kindsOf(j: Journal): seq[string] =
    for e in j.entries: result.add e.kind

  test "the job asks for the lock before its first step and lets go after its last: lock, steps, unlock; the names are in the journal":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, lockedJob, fakeHost, runId = "s1_abc")
    check r.code == "ok" and r.value == "done"
    check kindsOf(j) == @["lock", "job_sh", "job_sh", "unlock"]
    check j.entries[0].payload == "stand\t0p" and j.entries[3].payload == "stand"       # the lock names the job that asks, the unlock only the lock
    check j.entries[0].key == "lock#0" and j.entries[3].key == "unlock#0"
  test "a job without a lock makes no lock calls":
    var sb = newSandbox()
    var j = Journal()
    discard sb.execute(j, pipelineOneStep, fakeHost, runId = "s1_abc")
    check kindsOf(j) == @["job_sh"]
  test "the lock is let go also when the job ends with an error, and the error goes on":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['0q']{ image = 'a', lock = 'stand', body = function(j) j:run(step.sh['1']{ cmd = 'fail' })  end } end})", fakeHost, runId = "s1_abc")
    check r.code == "script_error" and "step failed" in r.message
    check kindsOf(j) == @["lock", "job_sh", "unlock"]
  test "a job in a job with the same lock asks twice and lets go twice (the core counts the depth)":
    var sb = newSandbox()
    var j = Journal()
    let s = "return ci.pipeline({main = function(run) ci.single['0r']{ image = 'a', lock = 'x', body = function(j) ci.single['z1']{ image = 'b', lock = 'x', body = function(k) k:run(step.sh['1']{ cmd = 'in' }) end }  end } end})"
    check sb.execute(j, s, fakeHost, runId = "s1_abc").code == "ok"
    check kindsOf(j) == @["lock", "lock", "job_sh", "unlock", "unlock"]
    check j.entries[1].key == "lock#1" and j.entries[4].key == "unlock#1"
  test "a lock the core cannot give yet suspends the run at that call, and nothing after it is done":
    var sb = newSandbox()
    var j = Journal()
    var called: seq[string]
    let busy = proc (seq: int; kind, payload: string): Option[string] =
      called.add kind
      if kind == "lock": none(string) else: fakeHost(seq, kind, payload)
    let r = sb.execute(j, lockedJob, busy, runId = "s1_abc")
    check r.status == esSuspended
    check called == @["lock"] and j.entries.len == 0
  test "when the lock has been granted (the core wrote its record) the run goes on from there and does not ask again":
    var j = Journal()
    discard j.append("lock#0", "lock", "stand\t0p", "")           # what the core writes when it is the waiter's turn
    var called: seq[string]
    let host = proc (seq: int; kind, payload: string): Option[string] =
      called.add kind
      fakeHost(seq, kind, payload)
    var sb = newSandbox()
    let r = sb.execute(j, lockedJob, host, runId = "s1_abc")
    check r.code == "ok"
    check called == @["job_sh", "job_sh", "unlock"]
  test "a lock that is not a name is refused when the job is made":
    for bad in ["''", "'a b'", "'x/y'", "5", "true", "'" & "n".repeat(65) & "'"]:
      var sb = newSandbox()
      var j = Journal()
      let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.single['01']{ image = 'a', lock = " & bad & ", body = function(j) j:run(step.sh['1']{ cmd = 'x' }) end } end})", fakeHost, runId = "s1_abc")
      check r.code == "script_error" and "lock is a name" in r.message
      check j.entries.len == 0

suite "PIP-015 running again only what failed (replay with a retry record)":
  const twoJobs = "return ci.pipeline({main = function(run) ci.single['0s']{ image = 'a', body = function(j) j:run(step.sh['1']{ cmd = 'one' })  end } ci.single['0t']{ image = 'a', body = function(j) j:run(step.sh['1']{ cmd = 'two' })  end } return 'done' end})"
  const secondStep = "s" & $(26 * 1048576 + 1)                # the job '0t' (the number 26) and its step '1': a step is `s<job * 2^20 + step>` (D-67)
  proc hostFailing(seq: int; kind, payload: string): Option[string] =
    if kind == "job_sh" and payload.endsWith("\ttwo"): some("1\n") else: some("0\nout")

  test "a record that supersedes the failed step makes the replay ask the host for that step again, and for no other":
    var j = Journal()
    var sb = newSandbox()
    check sb.execute(j, twoJobs, hostFailing, runId = "s1_abc").code == "script_error"
    check j.entries.len == 2 and j.entries[1].key == secondStep and j.entries[1].result == "1\n"
    discard j.append("retry#0", "retry", "[\"" & secondStep & "\"]", "")
    var asked: seq[string]
    let healed = proc (seq: int; kind, payload: string): Option[string] =
      asked.add payload.split('\t')[^1]
      some("0\nfixed")
    var sb2 = newSandbox()
    let r = sb2.execute(j, twoJobs, healed, runId = "s1_abc")
    check r.code == "ok" and r.value == "done"
    check asked == @["two"]                                  # the step that succeeded is answered by the journal
    check j.entries[^1].key == secondStep & "~1" and j.entries[^1].result == "0\nfixed"
    check j.entries[1].result == "1\n"                       # the old record stays, chained, and is not the answer
  test "a second retry supersedes the answer of the first: the step is found under <key>~2":
    var j = Journal()
    var sb = newSandbox()
    discard sb.execute(j, twoJobs, hostFailing, runId = "s1_abc")
    discard j.append("retry#0", "retry", "[\"" & secondStep & "\"]", "")
    var sb2 = newSandbox()
    check sb2.execute(j, twoJobs, hostFailing, runId = "s1_abc").code == "script_error"       # failed again, now recorded as s1~1
    check j.entries[^1].key == secondStep & "~1"
    discard j.append("retry#1", "retry", "[\"" & secondStep & "~1\"]", "")
    var asked = 0
    let healed = proc (seq: int; kind, payload: string): Option[string] =
      inc asked
      some("0\nok")
    var sb3 = newSandbox()
    check sb3.execute(j, twoJobs, healed, runId = "s1_abc").code == "ok"
    check asked == 1 and j.entries[^1].key == secondStep & "~2"
  test "while the step is waiting to run again the replay suspends at it and asks nothing else":
    var j = Journal()
    var sb = newSandbox()
    discard sb.execute(j, twoJobs, hostFailing, runId = "s1_abc")
    discard j.append("retry#0", "retry", "[\"" & secondStep & "\"]", "")
    var kinds: seq[string]
    let waiting = proc (seq: int; kind, payload: string): Option[string] =
      kinds.add kind
      none(string)
    var sb2 = newSandbox()
    check sb2.execute(j, twoJobs, waiting, runId = "s1_abc").status == esSuspended
    check kinds == @["job_sh"]
  test "a retry record that names a key that is not there, or is not a list, changes nothing":
    var j = Journal()
    var sb = newSandbox()
    check sb.execute(j, twoJobs, hostFailing, runId = "s1_abc").code == "script_error"
    discard j.append("retry#0", "retry", "[\"s9\"]", "")
    discard j.append("retry#1", "retry", "not json", "")
    var sb2 = newSandbox()
    let again = sb2.execute(j, twoJobs, hostFailing, runId = "s1_abc")
    check again.code == "script_error"                       # the failed step still answers: the key was not superseded
