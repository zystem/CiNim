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
    ci.job({image = "alpine"}, function(j)
      r = j:sh("echo hi")
    end)
    return seen_run_id .. "|" .. tostring(r.code)
  end,
})
"""

const pipelineTwoJobs = """
return ci.pipeline({
  main = function(run)
    local keys = {}
    ci.job({image = "a"}, function(j) j:sh("one") end)
    ci.job({image = "b"}, function(j) j:sh("two") end)
    return "ok"
  end,
})
"""

const pipelineJobFails = """
return ci.pipeline({
  main = function(run)
    local ok, err = pcall(function()
      ci.job({image = "a"}, function(j)
        local r = j:sh("fail")
        if r.code ~= 0 then error("step failed") end
      end)
    end)
    return tostring(ok)
  end,
})
"""

const pipelineStepFails = """
return ci.pipeline({
  main = function(run)
    ci.job({image = "a"}, function(j) j:sh("fail") end)
    return "not reached"
  end,
})
"""

const pipelineIgnoreFailure = """
return ci.pipeline({
  main = function(run)
    local r
    ci.job({image = "a"}, function(j) r = j:sh("fail", {ignore_failure = true}) end)
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
    let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.job({image = 'a'}, function(j) j:sh('x', {ignore_failure = 'yes'}) end) end})", fakeHost, runId = "s1_abc")
    check r.code == "script_error" and "ignore_failure" in r.message

  test "6.7: secrets are names in the journalled options, sorted, a job's and a step's together, no repeats":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.job({image = 'a', secrets = {'REGISTRY_PASSWORD', 'A_TOKEN'}}, function(j) j:sh('x', {secrets = {'A_TOKEN', 'DEPLOY_KEY'}}) end) end})", fakeHost, runId = "s1_abc")
    check r.code == "ok"
    check j.entries[0].payload == "job-1\ta\t\t{\"secrets\":[\"A_TOKEN\",\"DEPLOY_KEY\",\"REGISTRY_PASSWORD\"]}\tx"

  test "6.7: a step without secrets has no secrets key":
    var sb = newSandbox()
    var j = Journal()
    discard sb.execute(j, pipelineOneStep, fakeHost, runId = "s1_abc")
    check "secrets" notin j.entries[0].payload

  test "a call that the core refuses for good fails the run with the core's words; it is not suspended":
    var sb = newSandbox()
    var j = Journal()
    let refusing: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
      raise (ref HostRefusal)(code: "script_error", msg: "the organisation has no secret DEPLOY_KEY")
    let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.job({image = 'a'}, function(j) j:sh('x') end) end})", refusing, runId = "s1_abc")
    check r.status == esFailed and r.code == "script_error" and "no secret DEPLOY_KEY" in r.message
    check j.entries.len == 0                      # nothing was journalled: the refusal is not a result

  test "6.7: a secret name is a capital-letter environment name; anything else is refused before the run goes on":
    for bad in ["'lower'", "'1ABC'", "'A-B'", "42", "'" & "A".repeat(65) & "'", "{}"]:
      var sb = newSandbox()
      var j = Journal()
      let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.job({image = 'a'}, function(j) j:sh('x', {secrets = {" & bad & "}}) end) end})", fakeHost, runId = "s1_abc")
      check r.code == "script_error" and "secrets" in r.message
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.job({image = 'a', secrets = 'X'}, function(j) j:sh('x') end) end})", fakeHost, runId = "s1_abc")
    check r.code == "script_error" and "secrets" in r.message

  test "run.run_id reaches main(), Job:sh yields job_sh and returns StepResult.code":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, pipelineOneStep, fakeHost, runId = "s1_abc")
    check r.code == "ok"
    check r.value == "s1_abc|0"
    check j.entries.len == 1
    check j.entries[0].kind == "job_sh"
    check j.entries[0].payload == "job-1\talpine\t\t\techo hi"

  test "RUN-004, A.13: a job may ask for the build profile; the profile is a field of the journalled call":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, """return ci.pipeline({ main = function(run)
      ci.job({image = "kaniko", profile = "build"}, function(j) j:sh("build") end)
      ci.job({image = "a", profile = "default"}, function(j) j:sh("plain") end)
      return "ok" end })""", fakeHost)
    check r.code == "ok"
    check j.entries[0].payload == "job-1\tkaniko\tbuild\t\tbuild"
    check j.entries[1].payload == "job-2\ta\t\t\tplain"       # "default" is the ordinary profile: the field is empty
  test "an unknown profile is a script error":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, """return ci.pipeline({ main = function(run)
      ci.job({image = "a", profile = "privileged"}, function(j) j:sh("x") end)
      return "ok" end })""", fakeHost)
    check r.code != "ok"
  test "each ci.job call gets a sequential job key (job-1, job-2, ...)":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, pipelineTwoJobs, fakeHost)
    check r.code == "ok"
    check j.entries.len == 2
    check j.entries[0].payload == "job-1\ta\t\t\tone"
    check j.entries[1].payload == "job-2\tb\t\t\ttwo"

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
    ci.job({image = "a", metrics = {runtime = "jvm"}}, function(j)
      j:sh("one")                                                   -- inherits the job's declaration
      j:sh("two", {metrics = {scrape = {{url = "http://127.0.0.1:9404/metrics", interval = "10s", include = {"jvm_*"}}}}})
      j:sh("three", {metrics = false})                              -- switched off for this step
    end)
    return "ok"
  end,
})
"""

proc metricsRun(body: string): tuple[code, value: string] =
  var sb = newSandbox()
  var j = Journal()
  let r = sb.execute(j, "return ci.pipeline({main = function(run) ci.job({image = 'a'}, function(j) " & body &
    " end) return 'ok' end})", fakeHost)
  (r.code, r.value & r.message)

suite "application metrics declaration (docs/metrics.md)":
  test "canonical JSON per step; the job's declaration is inherited, replaced or switched off":
    var sb = newSandbox()
    var j = Journal()
    let r = sb.execute(j, pipelineMetrics, fakeHost)
    check r.code == "ok"
    check j.entries.len == 3
    check j.entries[0].payload == "job-1\ta\t\t" & """{"metrics":{"runtime":"jvm","scrape":[]}}""" & "\tone"
    check j.entries[1].payload == "job-1\ta\t\t" &
      """{"metrics":{"runtime":"none","scrape":[{"format":"prometheus","include":["jvm_*"],"interval":10,"name":"app1","timeout":5,"url":"http://127.0.0.1:9404/metrics"}]}}""" & "\ttwo"
    check j.entries[2].payload == "job-1\ta\t\t\tthree"
  test "only the step's own Pod may be scraped":
    for url in ["http://example.com/metrics", "http://10.0.0.5:9000/", "https://127.0.0.1/m", "http://127.0.0.1.evil.com/m"]:
      check metricsRun("j:sh('x', {metrics = {scrape = {{url = '" & url & "'}}}})").code != "ok"
    check metricsRun("j:sh('x', {metrics = {scrape = {{url = 'http://localhost:8080/m'}}}})").code == "ok"
    check metricsRun("j:sh('x', {metrics = {scrape = {{url = 'http://[::1]:8080/m'}}}})").code == "ok"
  test "bad declarations fail before anything runs":
    for m in ["{runtime = 'cobol'}", "{scrape = {{url = 'http://127.0.0.1/m', interval = 0}}}",
              "{scrape = {{url = 'http://127.0.0.1/m', interval = '5s', timeout = '9s'}}}",
              "{scrape = {{url = 'http://127.0.0.1/m', format = 'xml'}}}",
              "{scrape = {{url = 'http://127.0.0.1/m', name = 'Bad Name'}}}",
              "{scrape = {{url = 'http://127.0.0.1/m', include = {'a b'}}}}",
              "{scrape = {{url = 'http://127.0.0.1/m'}, {url = 'http://127.0.0.1/m'}, {url = 'http://127.0.0.1/m'}, {url = 'http://127.0.0.1/m'}, {url = 'http://127.0.0.1/m'}}}",
              "{unknown = 1}", "{scrape = {{url = 'http://127.0.0.1/m', typo = 1}}}", "'text'"]:
      check metricsRun("j:sh('x', {metrics = " & m & "})").code != "ok"

suite "step options: mask and timeout (docs/secrets-masking.md)":
  test "mask, metrics and timeout travel as one canonical object, keys sorted, job defaults inherited per key":
    var sb = newSandbox()
    var j = Journal()
    let script = """
      return ci.pipeline({main = function(run)
        ci.job({image = "a", timeout = "10m", mask = {min_length = 8}}, function(j)
          j:sh("one")
          j:sh("two", {timeout = 90, mask = false})
          j:sh("three", {metrics = {runtime = "jvm"}})
        end)
        return "ok"
      end})"""
    check sb.execute(j, script, fakeHost).code == "ok"
    check j.entries[0].payload == "job-1\ta\t\t" & """{"mask":{"min_length":8,"runtime":true,"variants":true},"timeout":600}""" & "\tone"
    check j.entries[1].payload == "job-1\ta\t\t" & """{"mask":{"min_length":4,"runtime":false,"variants":false},"timeout":90}""" & "\ttwo"
    check j.entries[2].payload == "job-1\ta\t\t" & """{"mask":{"min_length":8,"runtime":true,"variants":true},"metrics":{"runtime":"jvm","scrape":[]},"timeout":600}""" & "\tthree"
  test "nothing set -> no options at all (the shim's defaults apply: runtime values and variants on)":
    var sb = newSandbox()
    var j = Journal()
    check sb.execute(j, pipelineOneStep, fakeHost).code == "ok"
    check j.entries[0].payload == "job-1\talpine\t\t\techo hi"
  test "bad mask and timeout fail before anything runs":
    for o in ["{mask = 'yes'}", "{mask = {runtime = 'x'}}", "{mask = {min_length = 2}}", "{mask = {typo = 1}}",
              "{timeout = 0}", "{timeout = '5x'}", "{timeout = 100000}"]:
      check metricsRun("j:sh('x', " & o & ")").code != "ok"
