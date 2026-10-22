## PIP-003, PIP-006, PIP-016 / D-67: the pass of a script against a stub host (`executor/pass.nim`): what the script itself proves before a run is led or exists (more than 1000 steps,
## an id used twice, a broken script) and what it does not (a stub's answer is not the real one). It numbers nothing: a step's number is made of its ids (`tsingle`). Pure: no core, no cluster.
import std/[unittest, strutils, sequtils]
import executor/[pass, sandbox, journal, replay]

const sequential = """
return ci.pipeline({ main = function(run)
  ci.single['01']{ image = "alpine", steps = {
    step.sh['1']{ cmd = "one" },
    step.sh['2']{ cmd = "two" },
    step.sh['3']{ cmd = "three" },
  } }
end })
"""

suite "PIP-003 the pass sees the steps of a script":
  test "a sequential script: its three steps, nothing wrong":
    let r = runPass(sequential)
    check r.ok and not r.partial and r.steps == 3
  test "a script that breaks on a stub's answer is partial, not refused: the real run will find its own way":
    let r = runPass("""
      ci.single['01']{ image = 'a', body = function(j)
        local r = j:run(step.sh['1']{ cmd = 'x' })
        if r.outputs.SHA == nil then error('boom') end
        j:run(step.sh['2']{ cmd = 'y' })
      end }""")
    check r.ok and r.partial and r.steps == 1 and "boom" in r.message

suite "PIP-006 the limit of 1000 steps":
  test "1000 steps pass, 1001 are an error returned to the user before the run is led":
    let ok = runPass("ci.single['01']{ image='a', body = function(j) for i = 1, 1000 do j:run(step.sh[b32f('{xxx}', i)]{ cmd = 'x' }) end end }")
    check ok.ok and ok.steps == 1000
    let bad = runPass("ci.single['01']{ image='a', body = function(j) for i = 1, 1001 do j:run(step.sh[b32f('{xxx}', i)]{ cmd = 'x' }) end end }")
    check not bad.ok and bad.code == "step_limit"
    check "1000" in bad.message
  test "the 1000 steps are of a run, not of a job: ten jobs of a hundred pass, and the 1001st in the eleventh does not":
    let script = "for n = 1, 10 do ci.single[b32f('{xx}', n)]{ image='a', body = function(j) for i = 1, 100 do j:run(step.sh[b32f('{xxx}', i)]{ cmd = 'x' }) end end } end"
    check runPass(script).ok
    check not runPass(script & "\nci.single['zz']{ image='a', steps = { step.sh['1']{ cmd = 'x' } } }").ok

suite "PIP-018 the ids of jobs and steps found by the pass":
  test "a repeated job id fails the run with duplicate_id and names both lines":
    let r = runPass("ci.single['a']{ image='a', steps = { step.sh['1']{ cmd = 'x' } } }\nci.single['0a']{ image='a', steps = { step.sh['1']{ cmd = 'y' } } }")
    check not r.ok and r.code == "duplicate_id"
    check "line 1" in r.message and "line 2" in r.message
  test "a repeated step id in one job fails the run, in a list before a step runs and in a body at the second":
    let list = runPass("ci.single['01']{ image='a', steps = {\n step.sh['a']{ cmd = 'x' },\n step.sh['000a']{ cmd = 'y' },\n} }")
    check not list.ok and list.code == "duplicate_id" and list.steps == 0
    check "line 2" in list.message and "line 3" in list.message
    let body = runPass("ci.single['01']{ image='a', body = function(j)\n j:run(step.sh['a']{ cmd = 'x' })\n j:run(step.sh['0a']{ cmd = 'y' })\nend }")
    check not body.ok and body.code == "duplicate_id" and body.steps == 1
  test "the same step id in two jobs is not a repeat: a step is named by its job and its id":
    let r = runPass("ci.single['01']{ image='a', steps = { step.sh['1']{ cmd = 'x' } } }\nci.single['02']{ image='a', steps = { step.sh['1']{ cmd = 'y' } } }")
    check r.ok and r.steps == 2
  test "ids built in loops with b32f do not clash":
    let r = runPass("""
      for i = 1, 3 do
        ci.single[b32f("{x}", i)]{ image = 'a', body = function(j)
          for k = 1, 3 do j:run(step.sh[b32f("{x}{x}", i, k)]{ cmd = 'x' }) end
        end }
      end""")
    check r.ok and r.steps == 9
  test "an id built by hand that repeats is the author's error":
    let r = runPass("""
      ci.single['01']{ image = 'a', body = function(j)
        for i = 1, 12 do for k = 1, 12 do j:run(step.sh['a' .. ((i * k) % 5)]{ cmd = 'x' }) end end
      end }""")
    check not r.ok and r.code == "duplicate_id"

suite "PIP-005 what the pass needs of the host does not reach the script":
  test "the function that gives the line of a step is not a global of the script":
    var sb = newSandbox()
    check sb.run("return type(__ci_line)").value == "nil"
    check sb.run("return type(debug)").value == "nil"

suite "PIP-018 the example of ids built in a loop":
  test "deploy/examples/ids/ids.lua is a valid script: ten steps, none of the ids repeated":
    let r = runPass(readFile("deploy/examples/ids/ids.lua"))
    check r.ok and not r.partial and r.steps == 10

suite "PIP-016 the check of a script before a run exists (preflight)":
  const withParams = """
return ci.pipeline({
  params = { JOBS = ci.number{ default = 4, min = 1, max = 64, integer = true }, TARGET = ci.choice({ "staging", "production" }, { default = "staging" }), TICKET = ci.string{ required = true } },
  main = function(run) ci.single['01']{ image = "a", steps = { step.sh['1']{ cmd = "one" }, step.sh['2']{ cmd = "two" } } } end })
"""
  test "a good script and good parameters: nothing found, the steps seen, the parameters a run would have (defaults completed)":
    let r = preflight(withParams, @[("TICKET", "CI-7")])
    check r.code == "" and not r.certain and r.steps == 2
    check "\"JOBS\"" in r.paramsJson and "\"TARGET\":\"staging\"" in r.paramsJson and "CI-7" in r.paramsJson
  test "a parameter the declarations refuse is a certain finding with the parameter's name and the rule, and no step was seen":
    for (given, word) in [(@[("TICKET", "x"), ("JOBS", "0")], "JOBS"), (@[("TICKET", "x"), ("TARGET", "moon")], "TARGET"), (@[("JOBS", "3")], "TICKET"), (@[("TICKET", "x"), ("NOPE", "1")], "NOPE")]:
      let r = preflight(withParams, given)
      check r.code == "script_error" and r.certain and word in r.message and r.steps == 0
  test "a syntax error, a forbidden global and an error before the first step are certain":
    for script in ["return (", "os.execute('x')", "error('boom')", "return ci.pipeline({ main = function(run) local x = nil; x() end })"]:
      let r = preflight(script)
      check r.code == "script_error" and r.certain
  test "a script that breaks after a step has answered is a finding that is not certain: the stub's answer may be the cause":
    let r = preflight("return ci.pipeline({ main = function(run) local r = ci.single['01']{ image='a', steps = { step.sh['1']{ cmd = 'x' } } }; error('after ' .. tostring(r)) end })")
    check r.code == "script_error" and not r.certain and r.steps == 1
  test "more than 1000 steps and an id used twice are certain, whatever the steps answered":
    let many = preflight("return ci.pipeline({ main = function(run) ci.single['01']{ image='a', body = function(j) for i = 1, 1001 do j:run(step.sh[b32f('{xxx}', i)]{ cmd = 'x' }) end end } end })")
    check many.code == "step_limit" and many.certain
    let dup = preflight("return ci.pipeline({ main = function(run) ci.single['01']{ image='a', steps = {\n step.sh['a']{ cmd = 'x' },\n step.sh['a']{ cmd = 'y' },\n} } end })")
    check dup.code == "duplicate_id" and dup.certain
  test "a loop that never ends is stopped by the instruction budget, and is certain":
    let r = preflight("while true do end")
    check r.code == "instruction_limit" and r.certain
