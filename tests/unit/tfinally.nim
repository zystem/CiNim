## RUN-006: `ci.finally(fn)` registers a cleanup that runs when `main` ends, by success or by error, last registered first (the cancellation of a run is not built yet). Pure: a fake host.
import std/[unittest, strutils, sequtils, sets, options, tables]
import executor/[steptable, sandbox, journal, replay]

proc cmdOf(payload: string): string = payload.split('\t', 4)[^1]

type Led = object
  result: ExecResult
  asked: seq[string]

proc lead(script: string; j: var Journal; codes: Table[string, int]; waiting = initHashSet[string]()): Led =
  ## a step answers with its code from `codes` (0 when absent); one in `waiting` has no answer yet
  var sb = newSandbox()
  var n = newNumbering(buildTable(script).table)
  var r: Led
  let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
    if kind != "job_sh": return some("")
    let c = cmdOf(payload)
    r.asked.add c
    if c in waiting: return none(string)
    some($codes.getOrDefault(c, 0) & "\n")
  r.result = replay.execute(sb, j, script, host,
    onPlace = proc (seq: int; kind: string; line: int; ctx: string; nth: int) = n.onPlace(kind, line, ctx, nth),
    stepKey = proc (): string = "s" & $max(n.lastNo, 0))
  r

proc script(body: string): string =
  "return ci.pipeline({ main = function(run)\n" & body & "\nend })"

suite "RUN-006 ci.finally":
  test "the cleanup runs after main succeeds, last registered first, and main's value is kept":
    let s = script("""
      ci.finally(function() ci.job({image = "x"}, function(j) j:sh("clean first") end) end)
      ci.finally(function() ci.job({image = "x"}, function(j) j:sh("clean second") end) end)
      ci.job({image = "x"}, function(j) j:sh("work") end)
      return "value" """)
    var j: Journal
    let r = lead(s, j, initTable[string, int]())
    check r.result.status == esDone and r.result.value == "value"
    check r.asked == @["work", "clean second", "clean first"]
  test "the cleanup runs after main fails, and the run still ends with main's error":
    let s = script("""
      ci.finally(function() ci.job({image = "x"}, function(j) j:sh("clean") end) end)
      ci.job({image = "x"}, function(j) j:sh("work") end)
      ci.job({image = "x"}, function(j) j:sh("never") end)""")
    var j: Journal
    let r = lead(s, j, {"work": 3}.toTable)
    check r.asked == @["work", "clean"]
    check r.result.status == esFailed and "step failed with code 3" in r.result.message
  test "a cleanup registered after the failure was never registered":
    let s = script("""
      ci.job({image = "x"}, function(j) j:sh("work") end)
      ci.finally(function() ci.job({image = "x"}, function(j) j:sh("late") end) end)""")
    var j: Journal
    let r = lead(s, j, {"work": 1}.toTable)
    check r.asked == @["work"] and r.result.status == esFailed
  test "a failing cleanup does not stop the others; after a success the run fails with the first cleanup error, after an error with main's":
    let body = """
      ci.finally(function() ci.job({image = "x"}, function(j) j:sh("clean a") end) end)
      ci.finally(function() ci.job({image = "x"}, function(j) j:sh("clean b") end) end)
      ci.job({image = "x"}, function(j) j:sh("work") end)"""
    var j: Journal
    var r = lead(script(body), j, {"clean b": 5}.toTable)
    check r.asked == @["work", "clean b", "clean a"]
    check r.result.status == esFailed and "step failed with code 5" in r.result.message
    var j2: Journal
    r = lead(script(body), j2, {"work": 2, "clean b": 5}.toTable)
    check r.result.status == esFailed and "step failed with code 2" in r.result.message
  test "an error raised by the script itself runs the cleanup as well":
    let s = script("""
      ci.finally(function() ci.job({image = "x"}, function(j) j:sh("clean") end) end)
      error("boom", 0)""")
    var j: Journal
    let r = lead(s, j, initTable[string, int]())
    check r.asked == @["clean"] and r.result.status == esFailed and r.result.message.endsWith("boom")
  test "the cleanup is led like any steps: it waits for its step, and a replay goes on from the journal to the same end":
    let s = script("""
      ci.finally(function() ci.job({image = "x"}, function(j) j:sh("clean") end) end)
      ci.job({image = "x"}, function(j) j:sh("work") end)""")
    var j: Journal
    var r = lead(s, j, {"work": 4}.toTable, ["clean"].toHashSet)
    check r.result.status == esSuspended and r.asked == @["work", "clean"]
    r = lead(s, j, {"work": 4}.toTable)
    check r.result.status == esFailed and "step failed with code 4" in r.result.message
    check r.asked == @["work", "clean"][1 .. 1]          # `work` is in the journal; `clean` was never answered
    var again: Led
    again = lead(s, j, {"work": 4}.toTable)
    check again.asked.len == 0 and again.result.status == esFailed and again.result.message == r.result.message
  test "the cleanup of a run whose ci.parallel failed runs after the branches were cancelled":
    let s = script("""
      ci.finally(function() ci.job({image = "x"}, function(j) j:sh("clean") end) end)
      ci.parallel({
        a = function() ci.job({image = "x"}, function(j) j:sh("a1") end) end,
        b = function() ci.job({image = "x"}, function(j) j:sh("b1") end) end,
      }, { fail_fast = false })""")
    var j: Journal
    let r = lead(s, j, {"b1": 1}.toTable)
    check r.asked == @["a1", "b1", "clean"] and r.result.status == esFailed and "parallel: branches failed: b" in r.result.message
  test "a limit of the run (a repeated id) is the run's end: no cleanup":
    let s = script("""
      ci.finally(function() ci.job({image = "x"}, function(j) j:sh("clean") end) end)
      ci.job({image = "x", id = "same"}, function(j) j:sh("one") end)
      ci.job({image = "x", id = "same"}, function(j) j:sh("two") end)""")
    var j: Journal
    let r = lead(s, j, initTable[string, int]())
    check r.result.status == esFailed and r.result.code == "duplicate_id" and "clean" notin r.asked
  test "ci.finally is for main: not in a branch, not a non-function, at most 16":
    for (body, why) in [("ci.finally(1)", "function expected"), ("for i = 1, 17 do ci.finally(function() end) end", "at most 16")]:
      var j: Journal
      let r = lead(script(body), j, initTable[string, int]())
      check r.result.status == esFailed and why in r.result.message
    var j: Journal
    let inBranch = lead(script("local r = ci.parallel({ a = function() ci.finally(function() end) end }, { keep_going = true }); return tostring(r.a.ok) .. r.a.error"), j, initTable[string, int]())
    check inBranch.result.status == esDone and "only in main" in inBranch.result.value
