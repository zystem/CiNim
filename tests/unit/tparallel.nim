## PIP-003 / PIP-004 / docs/parallel.md sections 3, 5 and 8: `ci.parallel`, the branch scheduler in the sandbox, first slice (no `fail_fast`, no `ci.matrix`).
## Pure: a fake host stands for the core; "a step is done" is a set of commands. The script is run again, in a fresh sandbox with the journal so far, after every
## completion, as a run is led again by a conductor each time a step has ended.
import std/[unittest, strutils, sequtils, sets, options, algorithm, tables, json]
import executor/[steptable, sandbox, journal, replay]

type
  Round = object
    result: ExecResult
    asked: seq[string]           ## the commands the host was asked about, in order (only calls without a journal record reach it)
    numbers: Table[string, int]  ## command -> the number of its step

proc cmdOf(payload: string): string = payload.split('\t', 4)[^1]

proc runRound(script: string; table: StepTable; j: var Journal; done: HashSet[string]): Round =
  ## one execution of the script: what is in the journal is replayed, a call without a record goes to the host, which has an answer for the commands in `done` only
  var sb = newSandbox()
  var n = newNumbering(table)
  var r: Round
  let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
    if kind == "job_sh":
      r.asked.add cmdOf(payload)
      r.numbers[cmdOf(payload)] = n.lastNo
      if cmdOf(payload) in done: return some("0\n")
      return none(string)
    some("")
  r.result = replay.execute(sb, j, script, host,
    onPlace = proc (seq: int; kind: string; line: int; ctx: string; nth: int) = n.onPlace(kind, line, ctx, nth),
    stepKey = proc (): string = "s" & $max(n.lastNo, 0))
  r

proc drive(script: string; order: seq[char]; limit = 60): tuple[last: Round, j: Journal, history: seq[Round], numbers: Table[string, int]] =
  ## lead the script to its end: whenever it suspends, the step that finishes next is, of those asked and not done, the one whose branch letter comes first in `order`
  let table = buildTable(script).table
  var done = initHashSet[string]()
  for i in 0 ..< limit:
    let r = runRound(script, table, result.j, done)
    result.history.add r
    result.last = r
    for k, v in r.numbers: result.numbers[k] = v
    if r.result.status != esSuspended: return
    var pending = r.asked.filterIt(it notin done)
    doAssert pending.len > 0, "suspended with nothing asked: " & r.result.message
    pending.sort(proc (a, b: string): int =
      let ra = order.find(a[0])
      let rb = order.find(b[0])
      cmp(ra, rb))
    done.incl pending[0]
  doAssert false, "the script did not end"

const threeBranches = """
return ci.pipeline({ main = function(run)
  local r = ci.parallel({
    a = function() ci.job({image = "x"}, function(j) j:sh("a1"); j:sh("a2") end); return "A" end,
    b = function() ci.job({image = "x"}, function(j) j:sh("b1") end); return "B" end,
    c = function() ci.job({image = "x"}, function(j) j:sh("c1"); j:sh("c2") end); return "C" end,
  })
  ci.job({image = "x"}, function(j) j:sh("tail") end)
  return r.a.value .. r.b.value .. r.c.value
end })
"""

## the branches are made by one function: the steps of all of them are on the same lines
const loopBranches = """
local function build(name)
  return function()
    ci.job({image = "x"}, function(j)
      for i = 1, 2 do j:sh(name .. i) end
    end)
    return name
  end
end
return ci.pipeline({ main = function(run)
  local r = ci.parallel({ a = build("a"), b = build("b"), c = build("c") })
  return r.a.value .. r.b.value .. r.c.value
end })
"""

proc keys(j: Journal): HashSet[string] =
  for e in j.entries: result.incl e.key

proc permutations(s: seq[char]): seq[seq[char]] =
  if s.len <= 1: return @[s]
  for i in 0 ..< s.len:
    var rest = s
    rest.delete i
    for p in permutations(rest): result.add (@[s[i]] & p)

suite "PIP-003 ci.parallel: the branches go on together":
  test "every branch asks its first step before any step is answered, in the order of the names":
    let table = buildTable(threeBranches).table
    var j: Journal
    let r = runRound(threeBranches, table, j, initHashSet[string]())
    check r.result.status == esSuspended
    check r.asked == @["a1", "b1", "c1"]
  test "a branch goes on when its step is answered, while the others still wait":
    let table = buildTable(threeBranches).table
    var j: Journal
    let r = runRound(threeBranches, table, j, ["b1"].toHashSet)
    check r.asked == @["a1", "b1", "c1"]
    check j.entries.len == 1                         # b1 only; the replay finds it, so b1 is not asked a second time
    let r2 = runRound(threeBranches, table, j, ["b1"].toHashSet)
    check r2.asked == @["a1", "c1"]
  test "a script without ci.parallel is led as before: one step, suspended, the next after it is answered":
    let seqScript = """
      return ci.pipeline({ main = function(run)
        ci.job({image = "x"}, function(j) j:sh("one"); j:sh("two") end)
        return "done"
      end })"""
    let table = buildTable(seqScript).table
    var j: Journal
    var r = runRound(seqScript, table, j, initHashSet[string]())
    check r.result.status == esSuspended and r.asked == @["one"]
    r = runRound(seqScript, table, j, ["one"].toHashSet)             # `one` ended: the replay asks it, the core has it in the journal by now
    check r.asked == @["one", "two"] and r.result.status == esSuspended
    r = runRound(seqScript, table, j, ["one", "two"].toHashSet)
    check r.asked == @["two"] and r.result.status == esDone and r.result.value == "done"

suite "PIP-004 ci.parallel: the order of completion does not matter":
  test "all orders in which three branches can finish give the same keys, the same numbers and the same result":
    var firstKeys: HashSet[string]
    var firstNumbers: Table[string, int]
    var first = true
    for order in permutations(@['a', 'b', 'c']):
      let d = drive(threeBranches, order)
      check d.last.result.status == esDone
      check d.last.result.value == "ABC"
      if first:
        firstKeys = d.j.keys
        firstNumbers = d.numbers
        first = false
      else:
        check d.j.keys == firstKeys
        check d.numbers == firstNumbers
      check d.j.verify()
  test "steps made on one line by different branches keep their numbers whatever the order (the instance is counted in the branch)":
    var firstNumbers: Table[string, int]
    var first = true
    for order in permutations(@['a', 'b', 'c']):
      let d = drive(loopBranches, order)
      check d.last.result.status == esDone and d.last.result.value == "abc"
      if first:
        firstNumbers = d.numbers
        first = false
      else:
        check d.numbers == firstNumbers
    check firstNumbers.len == 6
    var seen: HashSet[int]
    for _, n in firstNumbers: seen.incl n
    check seen.len == 6                               # no two steps share a number
  test "the numbers of the steps are those the table gave in the pass, not the overflow":
    let d = drive(loopBranches, @['a', 'b', 'c'])
    for cmd, n in d.numbers: check n < 100_000
  test "a finished run replays from its journal without asking the host":
    let d = drive(threeBranches, @['c', 'b', 'a'])
    var j = d.j
    let r = runRound(threeBranches, buildTable(threeBranches).table, j, initHashSet[string]())
    check r.result.status == esDone and r.asked.len == 0
    check j.entries.len == d.j.entries.len
  test "a branch whose command changed since the journal was written is script_nondeterminism, naming its key":
    let d = drive(threeBranches, @['a', 'b', 'c'])
    var j = d.j
    let changed = threeBranches.replace("j:sh(\"b1\")", "j:sh(\"b1 changed\")")
    let r = runRound(changed, buildTable(changed).table, j, initHashSet[string]())
    check r.result.status == esFailed and r.result.code == "script_nondeterminism"
    check "key s" in r.result.message

suite "PIP-003 ci.parallel: results, failures, pcall":
  const failing = """
    return ci.pipeline({ main = function(run)
      local r = ci.parallel({
        ok = function() ci.job({image = "x"}, function(j) j:sh("fine") end); return 7 end,
        bad = function() ci.job({image = "x"}, function(j) j:sh("broken") end) end,
      }, { keep_going = true })
      return tostring(r.ok.ok) .. tostring(r.ok.value) .. tostring(r.bad.ok) .. tostring(r.bad.error)
    end })"""
  proc failingHost(done: HashSet[string]): HostCallProc =
    result = proc (seq: int; kind, payload: string): Option[string] =
      if kind != "job_sh": return some("")
      let c = cmdOf(payload)
      if c == "broken": return some("3\n")
      if c in done: return some("0\n")
      none(string)
  test "a failed branch is a result, not an error, with keep_going; the others run to the end":
    var sb = newSandbox()
    var j: Journal
    let r = replay.execute(sb, j, failing, failingHost(["fine"].toHashSet))
    check r.status == esDone
    check r.value.startsWith("true7false")
    check "step failed with code 3" in r.value
  test "without keep_going ci.parallel raises after all branches have ended, naming the failed ones":
    let script = failing.replace(", { keep_going = true }", "")
    var sb = newSandbox()
    var j: Journal
    let r = replay.execute(sb, j, script, failingHost(["fine"].toHashSet))
    check r.status == esFailed and r.code == "script_error"
    check "parallel: branches failed: bad" in r.message
    check j.entries.anyIt(it.kind == "job_sh" and it.payload.endsWith("fine"))       # the good branch ran to its end first
  test "pcall catches the failure of ci.parallel and the script goes on":
    let script = failing.replace(", { keep_going = true }", "").replace("local r = ci.parallel(", "local ok, why = pcall(ci.parallel, ").replace("return tostring(r.ok.ok)", "return tostring(ok) .. tostring(why)\n      --")
    var sb = newSandbox()
    var j: Journal
    let r = replay.execute(sb, j, script, failingHost(["fine"].toHashSet))
    check r.status == esDone
    check r.value.startsWith("false") and "parallel: branches failed: bad" in r.value
  test "a branch that raises an error of its own is a failed branch with the message":
    let script = """
      return ci.pipeline({ main = function(run)
        local r = ci.parallel({ x = function() error("boom", 0) end, y = function() return "fine" end }, { keep_going = true })
        return tostring(r.x.ok) .. r.x.error .. tostring(r.y.ok) .. r.y.value
      end })"""
    var sb = newSandbox()
    var j: Journal
    let r = replay.execute(sb, j, script, failingHost(initHashSet[string]()))
    check r.status == esDone and r.value == "falseboomtruefine"
  test "branches can be a list; their names are 1, 2, ...":
    let script = """
      return ci.pipeline({ main = function(run)
        local r = ci.parallel({ function() return "p" end, function() return "q" end })
        return r[1].value .. r[2].value
      end })"""
    var sb = newSandbox()
    var j: Journal
    let r = replay.execute(sb, j, script, failingHost(initHashSet[string]()))
    check r.status == esDone and r.value == "pq"
  test "a value that is not plain data fails the branch":
    let script = """
      return ci.pipeline({ main = function(run)
        local r = ci.parallel({ x = function() return function() end end }, { keep_going = true })
        return tostring(r.x.ok) .. tostring(r.x.error)
      end })"""
    var sb = newSandbox()
    var j: Journal
    let r = replay.execute(sb, j, script, failingHost(initHashSet[string]()))
    check r.status == esDone and r.value.startsWith("false") and "plain data" in r.value
  test "an empty set of branches gives an empty table":
    var sb = newSandbox()
    var j: Journal
    let r = replay.execute(sb, j, "return ci.pipeline({ main = function(run) local r = ci.parallel({}); local c = 0; for _ in pairs(r) do c = c + 1 end; return tostring(c) end })", failingHost(initHashSet[string]()))
    check r.status == esDone and r.value == "0"
  test "a repeated id inside a branch ends the run with duplicate_id, not as a failed branch":
    let script = """
      return ci.pipeline({ main = function(run)
        ci.parallel({
          a = function() ci.job({image = "x"}, function(j) j:sh("one", {id = "same"}) end) end,
          b = function() ci.job({image = "x"}, function(j) j:sh("two", {id = "same"}) end) end,
        }, { keep_going = true })
      end })"""
    var sb = newSandbox()
    var j: Journal
    let r = replay.execute(sb, j, script, failingHost(initHashSet[string]()))
    check r.status == esFailed and r.code == "duplicate_id"

suite "PIP-003 ci.parallel: max_parallel, width and depth":
  const limited = """
    return ci.pipeline({ main = function(run)
      local r = ci.parallel({
        a = function() ci.job({image = "x"}, function(j) j:sh("a1") end) end,
        b = function() ci.job({image = "x"}, function(j) j:sh("b1") end) end,
        c = function() ci.job({image = "x"}, function(j) j:sh("c1") end) end,
      }, { max_parallel = 2 })
      return "ok"
    end })"""
  test "max_parallel starts the branches in the order of the names; the next starts when one has ended":
    let table = buildTable(limited).table
    var j: Journal
    var r = runRound(limited, table, j, initHashSet[string]())
    check r.asked == @["a1", "b1"]                                # c waits
    r = runRound(limited, table, j, ["b1"].toHashSet)             # b ends first: c takes its place
    check r.asked == @["a1", "b1", "c1"]
    r = runRound(limited, table, j, ["a1", "b1", "c1"].toHashSet)
    check r.result.status == esDone
  test "max_parallel is a whole number of at least 1":
    for bad in ["0", "-1", "1.5", "'2'"]:
      var sb = newSandbox()
      var j: Journal
      let r = replay.execute(sb, j, "return ci.pipeline({ main = function(run) ci.parallel({ a = function() end }, { max_parallel = " & bad & " }) end })",
                             proc (seq: int; kind, payload: string): Option[string] = some(""))
      check r.status == esFailed and "max_parallel" in r.message
  test "an unknown option, and a fail_fast that is not a boolean, are refused":
    for opt in ["bogus = true", "fail_fast = 'yes'"]:
      var sb = newSandbox()
      var j: Journal
      let r = replay.execute(sb, j, "return ci.pipeline({ main = function(run) ci.parallel({ a = function() end }, { " & opt & " }) end })",
                             proc (seq: int; kind, payload: string): Option[string] = some(""))
      check r.status == esFailed and "ci.parallel" in r.message
  test "at most 200 branches":
    let script = """
      return ci.pipeline({ main = function(run)
        local b = {}
        for i = 1, N do b[b58f("x{xx}", i)] = function() return i end end
        local r = ci.parallel(b)
        return "ok"
      end })"""
    var sb = newSandbox()
    var j: Journal
    let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] = some("")
    check replay.execute(sb, j, script.replace("N", "200"), host).status == esDone
    var sb2 = newSandbox()
    var j2: Journal
    let r = replay.execute(sb2, j2, script.replace("N", "201"), host)
    check r.status == esFailed and "200 branches" in r.message
  test "ci.parallel inside a branch: the steps of the inner branches are keyed by the whole path":
    let nested = """
      return ci.pipeline({ main = function(run)
        local r = ci.parallel({
          o = function()
            local inner = ci.parallel({
              p = function() ci.job({image = "x"}, function(j) j:sh("op") end); return "P" end,
              q = function() ci.job({image = "x"}, function(j) j:sh("oq") end); return "Q" end,
            })
            return inner.p.value .. inner.q.value
          end,
          w = function() ci.job({image = "x"}, function(j) j:sh("w1") end); return "W" end,
        })
        return r.o.value .. r.w.value
      end })"""
    let table = buildTable(nested).table
    var j: Journal
    let first = runRound(nested, table, j, initHashSet[string]())
    check first.asked == @["op", "oq", "w1"]
    var results: seq[string]
    for order in [@['o', 'w'], @['w', 'o']]:
      var jj: Journal
      var done = initHashSet[string]()
      var r: Round
      for i in 0 ..< 20:
        r = runRound(nested, table, jj, done)
        if r.result.status != esSuspended: break
        var pending = r.asked.filterIt(it notin done)
        pending.sort(proc (a, b: string): int = cmp(order.find(a[0]), order.find(b[0])))
        done.incl pending[0]
      check r.result.status == esDone
      results.add r.result.value
    check results == @["PQW", "PQW"]
  test "the nesting is limited to 200 levels":
    let script = """
      local function down(n)
        if n == 0 then
          local ok, e = pcall(ci.parallel, { x = function() return 1 end })
          return ok and "bottom" or tostring(e)
        end
        local r = ci.parallel({ x = function() return down(n - 1) end })
        return r.x.value
      end
      return ci.pipeline({ main = function(run) return down(DEPTH) end })"""
    let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] = some("")
    var sb = newSandbox()
    var j: Journal
    let r = replay.execute(sb, j, script.replace("DEPTH", "199"), host)
    check r.status == esDone and r.value == "bottom"
    var sb2 = newSandbox()
    var j2: Journal
    let r2 = replay.execute(sb2, j2, script.replace("DEPTH", "200"), host)
    check r2.status == esDone and "200 levels" in r2.value
  test "host calls other than steps are keyed by branch too: ci.now() in two branches keeps its value for each":
    let script = """
      return ci.pipeline({ main = function(run)
        local r = ci.parallel({
          a = function() return ci.now() end,
          b = function() return ci.now() end,
        })
        return r.a.value .. "," .. r.b.value
      end })"""
    var sb = newSandbox()
    var j: Journal
    var next = 0
    let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
      inc next
      some($(next * 10))
    let r = replay.execute(sb, j, script, host)
    check r.status == esDone and r.value == "10,20"
    check j.entries.len == 2                                          # the two `now` calls
    var sb2 = newSandbox()
    let again = replay.execute(sb2, j, script, proc (seq: int; kind, payload: string): Option[string] = (doAssert false; none(string)))
    check again.status == esDone and again.value == "10,20"
  test "a lock inside a branch is refused for now":
    let script = """
      return ci.pipeline({ main = function(run)
        ci.parallel({ a = function() ci.job({image = "x", lock = "L"}, function(j) j:sh("x") end) end })
      end })"""
    var sb = newSandbox()
    var j: Journal
    let r = replay.execute(sb, j, script, proc (seq: int; kind, payload: string): Option[string] = some("0\n"))
    check r.status == esFailed and "lock" in r.message and "ci.parallel" in r.message
  test "host calls in a coroutine of the script are still refused":
    let script = """
      return ci.pipeline({ main = function(run)
        local co = coroutine.wrap(function() ci.job({image = "x"}, function(j) j:sh("x") end) end)
        co()
      end })"""
    var sb = newSandbox()
    var j: Journal
    let r = replay.execute(sb, j, script, proc (seq: int; kind, payload: string): Option[string] = some("0\n"))
    check r.status == esFailed and "nested coroutines" in r.message

suite "PIP-003 ci.parallel: the table":
  test "the pass numbers the steps of a script with branches, and the steps made on one line by different branches get different numbers":
    let r = buildTable(loopBranches)
    check r.ok and r.steps == 6
    check r.table.blocks.len == 1                                      # all on one line
    check r.table.blocks[0].size == 6
  test "the table of a script with branches is stored and read back with the same numbers":
    let r = buildTable(loopBranches)
    var t = r.table
    let back = decodeTable(encodeTable(t))
    check back.isSome
    var b = back.get
    for (ctx, nth) in [("m.p1[a]", 0), ("m.p1[a]", 1), ("m.p1[b]", 0), ("m.p1[c]", 1)]:
      let line = r.table.blocks[0].line
      check b.numberOfAt(line, ctx, nth) == t.numberOfAt(line, ctx, nth)
  test "a place the pass did not see gets a number that depends on the place alone, whichever is asked first":
    let r = buildTable(loopBranches)
    let line = r.table.blocks[0].line
    var t1 = r.table
    var t2 = r.table
    let a1 = t1.numberOfAt(line, "m.p1[a]", 7)
    let b1 = t1.numberOfAt(line, "m.p1[b]", 7)
    let b2 = t2.numberOfAt(line, "m.p1[b]", 7)
    let a2 = t2.numberOfAt(line, "m.p1[a]", 7)
    check a1 == a2 and b1 == b2 and a1 != b1
    check a1 >= 1_000_000_000 and a1 < 2_000_000_000
  test "a script with 201 steps in its branches is step_limit":
    let script = """
      return ci.pipeline({ main = function(run)
        ci.parallel({
          a = function() ci.job({image = "x"}, function(j) for i = 1, 100 do j:sh("a" .. i) end end) end,
          b = function() ci.job({image = "x"}, function(j) for i = 1, 101 do j:sh("b" .. i) end end) end,
        })
      end })"""
    let r = buildTable(script)
    check not r.ok and r.code == "step_limit"


type FastRound = object
  result: ExecResult
  asked: seq[string]            ## the commands the host was asked about
  cancels: seq[JsonNode]        ## the decisions the host was asked to take (kind par_cancel), as the core would get them

proc fastRound(script: string; table: StepTable; j: var Journal; failed, done: HashSet[string]): FastRound =
  ## like runRound, and a host that takes the decision of fail_fast the way the core does: the steps named are cancelled, which is written to the journal as the answer of each
  ## of them (`~canceled:<path>`), and the decision itself is answered with the branches that were not started
  var sb = newSandbox()
  var n = newNumbering(table)
  var r: FastRound
  var byKey: Table[string, string]          # step key -> the payload of its call
  var sentinels: seq[(string, string, string)]
  let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
    case kind
    of "job_sh":
      let cmd = cmdOf(payload)
      r.asked.add cmd
      byKey["s" & $n.lastNo] = payload
      if cmd in failed: return some("3\n")
      if cmd in done: return some("0\n")
      return none(string)
    of "par_cancel":
      let d = parseJson(payload)
      r.cancels.add d
      for k in d["steps"]: sentinels.add (k.getStr, byKey[k.getStr], "~canceled:" & d["by"].getStr)
      return some("u:" & d["unstarted"].mapIt(it.getStr).join("\t"))
    else: return some("")
  r.result = replay.execute(sb, j, script, host,
    onPlace = proc (seq: int; kind: string; line: int; ctx: string; nth: int) = n.onPlace(kind, line, ctx, nth),
    stepKey = proc (): string = "s" & $max(n.lastNo, 0))
  for (k, p, res) in sentinels: discard j.append(k, "job_sh", p, res)
  r

const fastScript = """
return ci.pipeline({ main = function(run)
  local r = ci.parallel({
    a = function() ci.job({image = "x"}, function(j) j:sh("a1"); j:sh("a2") end); return "A" end,
    b = function() ci.job({image = "x"}, function(j) j:sh("b1") end); return "B" end,
    c = function() ci.job({image = "x"}, function(j) j:sh("c1") end); return "C" end,
  }, { fail_fast = true KEEP })
  return "survived"
end })
"""

suite "RUN-006 fail_fast: the first failure cancels the branches that still run":
  test "a failed branch cancels the steps of the others, which are told so in the journal; ci.parallel raises, naming the failed branch":
    let script = fastScript.replace(" KEEP", "")
    let table = buildTable(script).table
    var j: Journal
    var r = fastRound(script, table, j, initHashSet[string](), initHashSet[string]())
    check r.result.status == esSuspended and r.asked == @["a1", "b1", "c1"] and r.cancels.len == 0
    r = fastRound(script, table, j, ["b1"].toHashSet, initHashSet[string]())
    check r.result.status == esFailed and r.result.code == "script_error"
    check "parallel: branches failed: b" in r.result.message and "canceled: a, c" in r.result.message
    check r.cancels.len == 1
    check r.cancels[0]["by"].getStr == "m.p1" and r.cancels[0]["failed"].getStr == "b"
    check r.cancels[0]["steps"].len == 2 and r.cancels[0]["unstarted"].len == 0
    check j.entries.anyIt(it.kind == "par_cancel" and it.key == "m.p1/par_cancel#0")
    check j.entries.countIt(it.result == "~canceled:m.p1") == 2
    check j.verify()
  test "the run is replayed from its journal with no new step and no new decision, and ends the same way":
    let script = fastScript.replace(" KEEP", "")
    let table = buildTable(script).table
    var j: Journal
    discard fastRound(script, table, j, initHashSet[string](), initHashSet[string]())
    let first = fastRound(script, table, j, ["b1"].toHashSet, initHashSet[string]())
    for round in 1 .. 2:
      let again = fastRound(script, table, j, initHashSet[string](), initHashSet[string]())
      check again.asked.len == 0 and again.cancels.len == 0
      check again.result.status == esFailed and again.result.message == first.result.message
  test "keep_going returns the table: the failed branch failed, the cancelled ones are marked so":
    let script = fastScript.replace(" KEEP", ", keep_going = true").replace("return \"survived\"",
      "return tostring(r.a.canceled) .. tostring(r.a.error) .. tostring(r.b.ok) .. tostring(r.b.canceled) .. tostring(r.c.canceled)")
    let table = buildTable(script).table
    var j: Journal
    discard fastRound(script, table, j, initHashSet[string](), initHashSet[string]())
    let r = fastRound(script, table, j, ["b1"].toHashSet, initHashSet[string]())
    check r.result.status == esDone and r.result.value == "truecanceledfalseniltrue"
  test "a branch that finished before the failure keeps its result; only the branches still running are cancelled":
    let script = fastScript.replace(" KEEP", ", keep_going = true").replace("return \"survived\"", "return tostring(r.a.ok) .. tostring(r.c.ok) .. tostring(r.c.value) .. tostring(r.b.ok)")
    let table = buildTable(script).table
    var j: Journal
    discard fastRound(script, table, j, initHashSet[string](), initHashSet[string]())
    let r = fastRound(script, table, j, ["b1"].toHashSet, ["c1"].toHashSet)
    check r.result.status == esDone and r.result.value == "falsetrueCfalse"
    check r.cancels[0]["steps"].len == 1                      # a1 only: c1 had ended
  test "no failure, no decision":
    let script = fastScript.replace(" KEEP", "")
    let table = buildTable(script).table
    var j: Journal
    discard fastRound(script, table, j, initHashSet[string](), initHashSet[string]())
    var r = fastRound(script, table, j, initHashSet[string](), ["a1", "b1", "c1"].toHashSet)
    r = fastRound(script, table, j, initHashSet[string](), ["a1", "b1", "c1", "a2"].toHashSet)
    check r.result.status == esDone and r.result.value == "survived" and r.cancels.len == 0
  test "with max_parallel a branch not started is cancelled without a step, and a replay does not start it even when slots are free":
    let script = """
      return ci.pipeline({ main = function(run)
        local r = ci.parallel({
          a = function() ci.job({image = "x"}, function(j) j:sh("a1") end) end,
          b = function() ci.job({image = "x"}, function(j) j:sh("b1") end) end,
          c = function() ci.job({image = "x"}, function(j) j:sh("c1") end) end,
          d = function() ci.job({image = "x"}, function(j) j:sh("d1") end) end,
        }, { fail_fast = true, max_parallel = 2 })
      end })"""
    let table = buildTable(script).table
    var j: Journal
    var r = fastRound(script, table, j, initHashSet[string](), initHashSet[string]())
    check r.asked == @["a1", "b1"]
    r = fastRound(script, table, j, ["b1"].toHashSet, initHashSet[string]())
    check r.asked == @["a1", "b1", "c1"]                       # b's slot goes to c, d has none
    check r.result.status == esFailed
    check r.cancels[0]["unstarted"].mapIt(it.getStr) == @["d"] and r.cancels[0]["steps"].len == 2
    let again = fastRound(script, table, j, initHashSet[string](), initHashSet[string]())
    check again.asked.len == 0 and again.cancels.len == 0       # a and c are cancelled in the journal, so their slots are free: d is still not started
    check again.result.status == esFailed
  test "a failure in a nested ci.parallel cancels the steps of that one only; a failure above cancels everything below":
    let script = """
      return ci.pipeline({ main = function(run)
        local r = ci.parallel({
          o = function()
            ci.parallel({
              p = function() ci.job({image = "x"}, function(j) j:sh("op") end) end,
              q = function() ci.job({image = "x"}, function(j) j:sh("oq") end) end,
            })
            ci.job({image = "x"}, function(j) j:sh("after") end)
          end,
          w = function() ci.job({image = "x"}, function(j) j:sh("w1") end) end,
        }, { fail_fast = true })
      end })"""
    let table = buildTable(script).table
    var j: Journal
    discard fastRound(script, table, j, initHashSet[string](), initHashSet[string]())
    let r = fastRound(script, table, j, ["w1"].toHashSet, initHashSet[string]())
    check r.asked == @["op", "oq", "w1"]
    check r.result.status == esFailed and r.cancels.len == 1
    check r.cancels[0]["steps"].len == 2                         # the two steps of the nested branches
    let again = fastRound(script, table, j, initHashSet[string](), initHashSet[string]())
    check again.asked.len == 0 and again.cancels.len == 0       # nothing is asked: `after` is not reached, the nested branches are cancelled from above
    check again.result.status == esFailed
  test "the decision of a nested ci.parallel does not touch the branches above it":
    let script = """
      return ci.pipeline({ main = function(run)
        local r = ci.parallel({
          o = function()
            local inner = ci.parallel({
              p = function() ci.job({image = "x"}, function(j) j:sh("op") end) end,
              q = function() ci.job({image = "x"}, function(j) j:sh("oq") end) end,
            }, { fail_fast = true, keep_going = true })
            return tostring(inner.p.ok) .. tostring(inner.q.canceled)
          end,
          w = function() ci.job({image = "x"}, function(j) j:sh("w1") end); return "W" end,
        })
        return r.o.value .. r.w.value
      end })"""
    let table = buildTable(script).table
    var j: Journal
    discard fastRound(script, table, j, initHashSet[string](), initHashSet[string]())
    var r = fastRound(script, table, j, ["op"].toHashSet, ["w1"].toHashSet)
    check r.cancels.len == 1 and r.cancels[0]["by"].getStr == "m.p1[o].p1" and r.cancels[0]["steps"].len == 1
    check r.result.status == esDone and r.result.value == "falsetrueW"
    r = fastRound(script, table, j, initHashSet[string](), initHashSet[string]())
    check r.asked.len == 0 and r.result.status == esDone and r.result.value == "falsetrueW"
