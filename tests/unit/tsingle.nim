## PIP-018 / D-67: the job and the step of the Lua API. The id is the index, `ci.single["a"]{ ... }` and `step.sh["ab"]{ ... }`: Crockford base32 of a fixed width (a job's 2 characters, a
## step's 4), a shorter one padded with zeros in front; the steps of a job are a list or run by `j:run(step)`; a step is `s<job * 2^20 + step>` in the journal; the result of a job is
## `{ status, steps = { [id] = { status, code, outputs, stdout } } }`. Pure: a fake host, no core.
import std/[unittest, options, strutils, sequtils, algorithm]
import executor/[sandbox, journal, replay]

proc fakeHost(seq: int; kind, payload: string): Option[string] =
  case kind
  of "job_sh":
    let parts = payload.split('\t', 4)         # key, image, profile, options, command
    if parts[4] == "fail": some("1\n")
    elif parts[4] == "outputs": some("0\nSHA=abc123\nTAG=t1\n")
    else: some("0\nout-" & $seq)
  of "now": some("1000")
  else: some("")

proc run(body: string; host: HostCallProc = fakeHost): tuple[res: ExecResult, j: Journal] =
  var sb = newSandbox()
  var j: Journal
  result.res = sb.execute(j, "return ci.pipeline({ main = function(run)\n" & body & "\nend })", host, runId = "s1_abc")
  result.j = j

suite "D-67 the id of a job is the index, and the job runs its steps":
  test "D-67 a list of steps runs in order, a step is told to the host with the key of its job and one number":
    let (r, j) = run("ci.single['0a']{ image = 'a', steps = { step.sh['1']{ cmd = 'one' }, step.sh['ab']{ cmd = 'two' } } }")
    check r.code == "ok"
    check j.entries.len == 2
    check j.entries[0].payload.startsWith("0a\ta\t\t\tone") and j.entries[1].payload.startsWith("0a\ta\t\t\ttwo")
    check j.entries[0].key == "s" & $(10 * 1048576 + 1)                  # the job 0a is the number 10, the step 0001 the number 1
    check j.entries[1].key == "s" & $(10 * 1048576 + 10 * 32 + 11)         # the step 00ab is a = 10, b = 11
  test "D-67 the job key is the normalized id: a, A, 0a and 0A are one id":
    for id in ["a", "A", "0a", "0A"]:
      let (r, j) = run("ci.single['" & id & "']{ image = 'a', steps = { step.sh['1']{ cmd = 'x' } } }")
      check r.code == "ok"
      check j.entries[0].payload.startsWith("0a\t")
  test "D-67 the number of a step is the same in every execution, whatever the order of the other calls":
    let (_, first) = run("ci.single['2']{ image = 'a', steps = { step.sh['1']{ cmd = 'one' } } }\nci.single['3']{ image = 'a', steps = { step.sh['1']{ cmd = 'two' } } }")
    let (_, second) = run("ci.single['3']{ image = 'a', steps = { step.sh['1']{ cmd = 'two' } } }\nci.single['2']{ image = 'a', steps = { step.sh['1']{ cmd = 'one' } } }")
    check first.entries.mapIt(it.key).sorted == second.entries.mapIt(it.key).sorted
  test "D-67 the result of a job is { status, steps } and the steps are found by the id as the author writes it":
    let (r, _) = run("""
      local r = ci.single['01']{ image = 'a', steps = { step.sh['ab']{ cmd = 'outputs' } } }
      return r.status .. '|' .. r.steps['ab'].outputs.SHA .. '|' .. r.steps['00ab'].outputs.TAG .. '|' .. r.steps['00AB'].status .. '|' .. tostring(r.steps['zz'])""")
    check r.code == "ok" and r.value == "ok|abc123|t1|ok|nil"
  test "D-67 a failed step fails the job and names the job and the step; ignore_failure returns the result instead":
    let (r, _) = run("ci.single['01']{ image = 'a', steps = { step.sh['1']{ cmd = 'fail' } } }")
    check r.code == "script_error" and "step failed with code 1" in r.message and "job 01" in r.message and "step 0001" in r.message
    let (ok, _) = run("local r = ci.single['01']{ image = 'a', steps = { step.sh['1']{ cmd = 'fail', ignore_failure = true }, step.sh['2']{ cmd = 'next' } } }\nreturn r.steps['1'].status .. r.steps['1'].code .. r.steps['2'].status")
    check ok.code == "ok" and ok.value == "failed1ok"
  test "D-67 a body runs the steps one by one with j:run, and what a step answered can decide the next":
    let (r, j) = run("""
      ci.single['01']{ image = 'a', body = function(j)
        local a = j:run(step.sh['1']{ cmd = 'outputs' })
        if a.outputs.SHA == 'abc123' then j:run(step.sh['2']{ cmd = 'then' }) else j:run(step.sh['3']{ cmd = 'else' }) end
      end }""")
    check r.code == "ok"
    check j.entries.mapIt(it.payload.split('\t', 4)[4]) == @["outputs", "then"]
  test "D-67 j:run takes only a step that a constructor of step made, not a table of the script's own":
    let (r, _) = run("ci.single['01']{ image = 'a', body = function(j) j:run({ kind = 'sh', id = '0001', opts = { cmd = 'x' } }) end }")
    check r.code == "script_error" and "made by step.sh" in r.message
  test "D-67 the id of a step is unique in its job, in a list before a step runs and in a body at the second":
    let (r, j) = run("ci.single['01']{ image = 'a', steps = { step.sh['a']{ cmd = 'x' }, step.sh['000A']{ cmd = 'y' } } }")
    check r.code == "duplicate_id" and "'000a'" in r.message and j.entries.len == 0
  test "D-67 steps or a body, one of them: both or neither is refused":
    let both = run("ci.single['01']{ image = 'a', steps = {}, body = function(j) end }")
    check both.res.code == "script_error" and "exactly one of steps" in both.res.message
    let neither = run("ci.single['01']{ image = 'a' }")
    check neither.res.code == "script_error" and "exactly one of steps" in neither.res.message
    check run("ci.single['01']{ image = 'a', steps = { 1 } }").res.message.contains("is not a step")
    check run("ci.single['01']{ image = 'a', steps = 'x' }").res.message.contains("is a list of steps")

suite "D-67 the ids are checked, with the reason, at the call":
  test "D-67 i, l, o and u are refused, in both cases, and the message says what to write":
    for c in ["i", "l", "o", "u", "I", "L", "O", "U"]:
      let r = run("ci.single['" & c & "']{ image = 'a', steps = {} }").res
      check r.code == "script_error" and ("'" & c.toLowerAscii & "'") in r.message and "alphabet" in r.message
      let s = run("ci.single['01']{ image = 'a', steps = { step.sh['a" & c & "']{ cmd = 'x' } } }").res
      check s.code == "script_error" and ("'" & c.toLowerAscii & "'") in s.message
  test "D-67 a job's id of three characters, a step's of five, an empty one, one that is not a string, and other characters are refused":
    check "at most 2 characters" in run("ci.single['abc']{ image = 'a', steps = {} }").res.message
    check "at most 4 characters" in run("ci.single['01']{ image = 'a', steps = { step.sh['abcde']{ cmd = 'x' } } }").res.message
    check "not empty" in run("ci.single['']{ image = 'a', steps = {} }").res.message
    check "a string" in run("ci.single[5]{ image = 'a', steps = {} }").res.message
    for bad in ["a-", "_", "é", " "]:
      check "not in the alphabet" in run("ci.single['" & bad & "']{ image = 'a', steps = {} }").res.message
  test "D-67 the error is at the line of the script that wrote the id":
    let r = run("local x = 1\nci.single['i']{ image = 'a', steps = {} }").res
    check ":3:" in r.message           # the script wraps the body in two lines: this is the second line of the body
  test "D-67 the id of a job is unique in the run, wherever the second is":
    let r = run("ci.single['a']{ image = 'a', steps = {} }\nci.single['0A']{ image = 'a', steps = {} }").res
    check r.code == "duplicate_id" and "'0a'" in r.message

suite "D-67 the old forms are gone, with a message that shows the new one":
  test "D-67 ci.job, Job:sh and a call without the index say what to write":
    let job = run("ci.job({ image = 'a' }, function(j) end)").res
    check job.code == "script_error" and "ci.single[" in job.message
    let sh = run("ci.single['01']{ image = 'a', body = function(j) j:sh('x') end }").res
    check sh.code == "script_error" and "step.sh[" in sh.message
    let bare = run("ci.single{ image = 'a', steps = {} }").res
    check bare.code == "script_error" and "the id is the index" in bare.message
    let bareStep = run("ci.single['01']{ image = 'a', steps = { step.sh{ cmd = 'x' } } }").res
    check bareStep.code == "script_error" and "the id is the index" in bareStep.message
  test "D-67 an unknown field of a job or of a step is refused with its name":
    check "unknown field 'imge'" in run("ci.single['01']{ imge = 'a', steps = {} }").res.message
    check "unknown field 'comand'" in run("ci.single['01']{ image = 'a', steps = { step.sh['1']{ comand = 'x' } } }").res.message
    check "cmd is a command" in run("ci.single['01']{ image = 'a', steps = { step.sh['1']{ name = 'x' } } }").res.message
  test "D-67 the name of a job and of a step is a text of 1 to 200 characters, and nothing else comes of it":
    let (r, j) = run("ci.single['01']{ name = 'build', image = 'a', steps = { step.sh['1']{ name = 'lint', cmd = 'x' } } }")
    check r.code == "ok" and j.entries.len == 1
    check "name is a text" in run("ci.single['01']{ name = 5, image = 'a', steps = {} }").res.message
    check "name is a text" in run("ci.single['01']{ image = 'a', steps = { step.sh['1']{ name = '', cmd = 'x' } } }").res.message

suite "D-67 the cache steps":
  test "D-67 step.cache_restore answers { hit, key } and step.cache_save saves, each a step of its own with an id":
    let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
      if kind == "job_sh" and payload.contains("\"mode\":\"restore\""): some("0\ndeps-1")
      else: some("0\n")
    let (r, j) = run("""
      local r = ci.single['01']{ image = 'a', steps = {
        step.cache_restore['1']{ keys = { 'deps-1', 'deps-' } },
        step.cache_save['2']{ key = 'deps-2', paths = { 'node_modules' } },
      } }
      return tostring(r.steps['1'].hit) .. '|' .. r.steps['1'].key .. '|' .. r.steps['2'].status""", host)
    check r.code == "ok" and r.value == "true|deps-1|ok"
    check j.entries.len == 2 and j.entries[0].key != j.entries[1].key
  test "D-67 a restore that finds nothing is not an error":
    let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] = some("0\n")
    let (r, _) = run("local r = ci.single['01']{ image = 'a', steps = { step.cache_restore['1']{ keys = { 'k' } } } }\nreturn tostring(r.steps['1'].hit)", host)
    check r.code == "ok" and r.value == "false"

suite "D-67 the name step":
  test "D-67 step is a global of the sandbox that cannot be written over, and ci.step is the same table":
    check run("return tostring(step == ci.step and type(step.sh) == 'table')").res.value == "true"
    check run("step = 1").res.code == "script_error"
