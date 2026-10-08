## Launch parameters (PIP-012, VAR-002, VAR-003): the declarations in the script, the values given at the start, the complete set that the executor
## reports to core as the journaled host call `params`, and the rules core applies to what the API and the executor hand it.
import std/[unittest, options, strutils, json]
import executor/[sandbox, journal, replay]
import core/runparams

type Seen = ref object
  params: seq[string]       ## the payloads of the `params` calls

proc runScript(script: string; given: seq[(string, string)]; seen: Seen; jr: var Journal): ExecResult =
  var sb = newSandbox()
  let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
    case kind
    of "params":
      seen.params.add payload
      some("")
    of "job_sh": some("0\n")
    else: some("")
  replay.execute(sb, jr, script, host, runId = "r1", params = given)

proc run1(script: string; given: seq[(string, string)] = @[]): tuple[r: ExecResult, seen: Seen] =
  var j: Journal
  result.seen = Seen()
  result.r = runScript(script, given, result.seen, j)

const declaredScript = """
return ci.pipeline({
  params = {
    BRANCH = ci.string{ default = "main", max_length = 20 },
    JOBS = ci.number{ default = 4, min = 1, max = 64, integer = true },
    RELEASE = ci.bool{ default = false },
    FLAVOUR = ci.choice({ "debug", "release" }, { default = "debug" }),
    CODE = ci.string{ pattern = "%u%u%d+", default = "AB1" },
    TICKET = ci.string{ required = true },
  },
  main = function(run)
    local p = run.params
    return table.concat({ p.BRANCH, tostring(p.JOBS), tostring(p.RELEASE), p.FLAVOUR, p.TICKET, type(p.JOBS), type(p.RELEASE) }, "|")
  end,
})
"""

suite "PIP-012 launch parameters in the script":
  test "PIP-012 defaults complete what was given, values are typed, and the complete set is reported once":
    let x = run1(declaredScript, @[("TICKET", "CI-7"), ("JOBS", "8")])
    check x.r.status == esDone
    check x.r.value == "main|8|false|debug|CI-7|number|boolean"
    check x.seen.params == @["""{"BRANCH":"main","CODE":"AB1","FLAVOUR":"debug","JOBS":"8","RELEASE":"false","TICKET":"CI-7"}"""]

  test "PIP-012 given values replace the defaults":
    let x = run1(declaredScript, @[("TICKET", "x"), ("BRANCH", "feature"), ("RELEASE", "true"), ("FLAVOUR", "release")])
    check x.r.value == "feature|4|true|release|x|number|boolean"

  test "VAR-003 a required parameter that is missing fails the run before any step":
    let x = run1(declaredScript)
    check x.r.status == esFailed
    check "TICKET is required" in x.r.message
    check x.seen.params.len == 0

  test "VAR-003 a wrong value is refused with the name and the rule":
    for (bad, why) in [(("JOBS", "0"), "at least 1"), (("JOBS", "100"), "at most 64"), (("JOBS", "2.5"), "integer"), (("JOBS", "many"), "must be a number"),
                       (("RELEASE", "yes"), "true or false"), (("FLAVOUR", "fast"), "one of: debug, release"),
                       (("BRANCH", "a-branch-name-that-is-too-long"), "longer than 20"),
                       (("CODE", "ab1"), "does not match")]:
      let x = run1(declaredScript, @[("TICKET", "t"), bad])
      check x.r.status == esFailed
      check why in x.r.message
      check bad[0] in x.r.message

  test "VAR-003 a parameter the script does not declare is refused, and the declared names are listed":
    let x = run1(declaredScript, @[("TICKET", "t"), ("SURPRISE", "1")])
    check x.r.status == esFailed
    check "unknown parameter SURPRISE" in x.r.message and "BRANCH" in x.r.message

  test "PIP-012 a script without declarations and a start without values make no params call":
    let x = run1("return ci.pipeline({ main = function(run) return type(run.params) end })")
    check x.r.status == esDone and x.r.value == "table"
    check x.seen.params.len == 0

  test "VAR-003 values to a script that declares nothing are refused":
    let x = run1("return ci.pipeline({ main = function(run) return 1 end })", @[("A", "1")])
    check x.r.status == esFailed and "unknown parameter A" in x.r.message and "none" in x.r.message

  test "PIP-012 a parameter without a default that is not required is simply absent":
    let x = run1("""return ci.pipeline({ params = { NOTE = ci.string{} }, main = function(run) return tostring(run.params.NOTE) end })""")
    check x.r.value == "nil"
    check x.seen.params.len == 0

  test "VAR-003 bad declarations are errors of the script":
    for src in ["""params = { lower = ci.string{} }""", """params = { A = "x" }""", """params = { A = ci.string{ colour = 1 } }""",
                """params = { A = ci.choice({}) }""", """params = { A = ci.string{ pattern = "[" } }""", """params = { A = ci.number{ default = "x" } }"""]:
      let x = run1("return ci.pipeline({ " & src & ", main = function(run) return 1 end })")
      check x.r.status == esFailed

  test "PIP-004 a replay with the journal gives the same values and does not ask the host again":
    var j: Journal
    let seen = Seen()
    let first = runScript(declaredScript, @[("TICKET", "CI-7")], seen, j)
    check first.status == esDone and seen.params.len == 1
    let seen2 = Seen()
    let again = runScript(declaredScript, @[("TICKET", "CI-7")], seen2, j)
    check again.status == esDone and again.value == first.value
    check seen2.params.len == 0
    # the stored set (all values filled in) given back as the values is a fixed point: a restart of the executor meets the same call
    let seen3 = Seen()
    var j3: Journal
    let fromStored = runScript(declaredScript, fromJson(seen.params[0]), seen3, j3)
    check fromStored.value == first.value and seen3.params == seen.params

suite "VAR-003 what core accepts as launch parameters":
  test "VAR-003 strings, numbers and booleans are kept as text, sorted by name":
    let c = checkParams(%*{"B": 1, "A": "x", "C": true, "D": 2.5})
    check c.error == ""
    check c.pairs == @[("A", "x"), ("B", "1"), ("C", "true"), ("D", "2.5")]
    check toJson(c.pairs) == """{"A":"x","B":"1","C":"true","D":"2.5"}"""

  test "VAR-003 names are those of environment variables and not on the deny-list":
    for name in ["lower", "1A", "A-B", "PATH", "LD_PRELOAD", "CICD_X", "HOME", ""]:
      check checkParams(%*{name: "v"}).error.len > 0

  test "VAR-003 nested values, long values, control characters and too many are refused":
    check checkParams(%*{"A": [1]}).error.len > 0
    check checkParams(%*{"A": {"b": 1}}).error.len > 0
    check checkParams(%*{"A": "x".repeat(1025)}).error.len > 0
    check checkParams(%*{"A": "a\nb"}).error.len > 0
    var many = newJObject()
    for i in 0 .. 64: many["P" & $i] = %"v"
    check checkParams(many).error.len > 0
    var big = newJObject()
    for i in 0 ..< 5: big["P" & $i] = %("x".repeat(1000))
    check checkParams(big).error.contains("in all")
    check checkParams(%*[1]).error.len > 0

  test "VAR-003 no parameters is fine":
    check checkParams(nil).error == "" and checkParams(newJNull()).error == "" and checkParams(newJObject()).pairs.len == 0

  test "VAR-002 the set that the executor reports is checked again by core":
    check checkEffective("""{"A":"1"}""") == ""
    check checkEffective("""{"PATH":"/x"}""").len > 0
    check checkEffective("""["A"]""").len > 0
    check checkEffective("not json").len > 0
    check checkEffective("""{"A":"x"}""".replace("x", "y".repeat(9000))).len > 0

  test "VAR-002 a damaged stored value gives no parameters, and denied names are dropped":
    check fromJson("").len == 0
    check fromJson("{{").len == 0
    check fromJson("""{"A":"1","PATH":"x","b":"y"}""") == @[("A", "1")]
