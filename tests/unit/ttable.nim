## PIP-003 / docs/parallel.md section 3: the table of step numbers made by a pass of the script against a stub host, the `id` option of ci.job and Job:sh, and the limit
## of 200 steps. Pure: no core, no cluster.
import std/[unittest, strutils, sequtils]
import std/options
import executor/[steptable, sandbox, journal, replay]

const sequential = """
return ci.pipeline({ main = function(run)
  ci.job({image = "alpine"}, function(j)
    j:sh("one")
    j:sh("two")
    j:sh("three")
  end)
end })
"""

suite "PIP-003 the blocks of the table (pure)":
  test "places that ran once are numbered one after another from 0, as the steps are numbered now":
    var t = assignBlocks(@[3, 4, 5])
    check t.numberOf(3, 0) == 0 and t.numberOf(4, 0) == 1 and t.numberOf(5, 0) == 2
  test "a place that ran more than once gets a block of ceil((n+1)/10)*10 numbers, in the order in which the places were first met":
    var t = assignBlocks(@[10, 20, 20, 20, 30])        # the line 20 ran three times
    check t.numberOf(10, 0) == 0
    check t.numberOf(20, 0) == 1 and t.numberOf(20, 1) == 2 and t.numberOf(20, 2) == 3
    check t.numberOf(30, 0) == 11                        # the block of line 20 is 10 numbers: 1..10
  test "the size of a block":
    check blockSize(1) == 1
    check blockSize(2) == 10 and blockSize(9) == 10
    check blockSize(10) == 20 and blockSize(19) == 20
    check blockSize(20) == 30
    check blockSize(199) == 200 and blockSize(200) == 200      # capped at 200
  test "an instance beyond what was seen but inside the block takes the reserve; beyond the block takes the overflow":
    var t = assignBlocks(@[7, 7])
    check t.numberOf(7, 5) == 5                           # the reserve of the block 0..9
    check t.numberOf(7, 10) == overflowBase               # outside the block
    check t.numberOf(7, 11) == overflowBase + 1           # the next overflow number, one for each new call
    check t.numberOf(99, 0) == overflowBase + 2           # a place that was never seen
  test "the same lookup gives the same number again":
    var t = assignBlocks(@[1, 2])
    let first = t.numberOf(99, 0)
    check t.numberOf(99, 0) == first
  test "the largest number a table can give is far below 40 000, the overflow starts at 100 000, and both fit uint32":
    var lines: seq[int]
    for i in 1 .. 200: lines.add i
    var t = assignBlocks(lines)
    check t.blocks[^1].start + t.blocks[^1].size < 40_000
    check overflowBase == 100_000

suite "PIP-003 the table made by a pass of the script":
  test "a sequential script is numbered 0, 1, 2 as before":
    let r = buildTable(sequential)
    check r.ok and r.steps == 3
    check r.table.blocks.mapIt(it.start) == @[0, 1, 2]
  test "a loop gets one block, every instance is seen and numbered inside it":
    let r = buildTable("""
      ci.job({image = "a"}, function(j)
        for i = 1, 5 do j:sh("echo " .. i) end
      end)""")
    check r.ok and r.steps == 5
    check r.table.blocks.len == 1 and r.table.blocks[0].observed == 5 and r.table.blocks[0].size == 10
  test "a helper called twice is one place with two instances":
    let r = buildTable("""
      local function build(t) ci.job({image = "a"}, function(j) j:sh("make " .. t) end) end
      build("a"); build("b")""")
    check r.ok and r.steps == 2 and r.table.blocks.len == 1 and r.table.blocks[0].observed == 2
  test "two places in a loop are two blocks":
    let r = buildTable("""
      ci.job({image = "a"}, function(j)
        for i = 1, 3 do
          j:sh("a")
          j:sh("b")
        end
      end)""")
    check r.ok and r.steps == 6 and r.table.blocks.len == 2
    check r.table.blocks[0].start == 0 and r.table.blocks[1].start == 10
  test "the launch parameters are the ones given, completed with the defaults":
    let script = """
      return ci.pipeline({ params = { N = ci.number{ default = 2, integer = true } }, main = function(run)
        ci.job({image = "a"}, function(j) for i = 1, run.params.N do j:sh("x") end end)
      end })"""
    check buildTable(script).steps == 2
    check buildTable(script, @[("N", "4")]).steps == 4
  test "now and random work in the pass, and the result of a step is a success":
    let r = buildTable("""
      local t = ci.now(); local x = ci.random()
      ci.job({image = "a"}, function(j) local s = j:sh("x"); if s.code == 0 then j:sh("y") end end)""")
    check r.ok and r.steps == 2
  test "a script that fails in the pass for another reason leaves a partial table and the run is not refused":
    let r = buildTable("""
      ci.job({image = "a"}, function(j) j:sh("x"); error("boom") end)""")
    check r.ok and r.partial and r.steps == 1 and "boom" in r.message
  test "the same script gives the same table every time":
    check buildTable(sequential).table.blocks == buildTable(sequential).table.blocks

suite "PIP-006 the limit of 200 steps":
  test "200 steps pass, 201 are an error returned to the user before the run is led":
    let ok = buildTable("ci.job({image='a'}, function(j) for i = 1, 200 do j:sh('x') end end)")
    check ok.ok and ok.steps == 200
    let bad = buildTable("ci.job({image='a'}, function(j) for i = 1, 201 do j:sh('x') end end)")
    check not bad.ok and bad.code == "step_limit"
    check "200" in bad.message

suite "PIP-018 the id of a job and of a step":
  test "an id is 1 to 8 letters and digits, starting with a letter":
    for good in ["a", "lint", "A1b2C3d4", "deploy1"]:
      check buildTable("ci.job({image='a', id='" & good & "'}, function(j) j:sh('x') end)").ok
      check buildTable("ci.job({image='a'}, function(j) j:sh('x', {id='" & good & "'}) end)").ok
  test "a longer id, one that starts with a digit, one with other characters, or one that is not a string is refused at the call":
    for bad in ["abcdefghi", "1abc", "a-b", "a_b", "a b", "", "ы1"]:
      let r = buildTable("ci.job({image='a'}, function(j) j:sh('x', {id='" & bad & "'}) end)")
      check r.partial and "id" in r.message
    check buildTable("ci.job({image='a'}, function(j) j:sh('x', {id=5}) end)").partial
    check buildTable("ci.job({image='a', id=5}, function(j) j:sh('x') end)").partial
  test "a repeated id fails the run with duplicate_id and names both lines":
    let r = buildTable("ci.job({image='a'}, function(j)\n  j:sh('x', {id='same'})\n  j:sh('y', {id='same'})\nend)")
    check not r.ok and r.code == "duplicate_id"
    check "same" in r.message and "line 2" in r.message and "line 3" in r.message
  test "a job and a step share the names: the same id on a job and on a step is a conflict":
    let r = buildTable("ci.job({image='a', id='dup'}, function(j) j:sh('x', {id='dup'}) end)")
    check not r.ok and r.code == "duplicate_id"
  test "ids built in a loop with b58f do not clash":
    let r = buildTable("""
      ci.job({image='a'}, function(j)
        for i = 1, 3 do for k = 1, 3 do j:sh('x', {id = b58f("a{xx}{xx}", i, k)}) end end
      end)""")
    check r.ok and r.steps == 9
  test "an id built by hand that repeats is the author's error":
    let r = buildTable("""
      ci.job({image='a'}, function(j)
        for i = 1, 12 do for k = 1, 12 do j:sh('x', {id = "a" .. i .. k}) end end
      end)""")
    check not r.ok and r.code == "duplicate_id"

suite "PIP-005 what the pass needs of the host does not reach the script":
  test "the function that gives the line of a step is not a global of the script":
    var sb = newSandbox()
    check sb.run("return type(__ci_line)").value == "nil"
    check sb.run("return type(debug)").value == "nil"

suite "PIP-003 the table as it is stored and the numbers of a run that goes on":
  test "a table survives encoding and decoding, overflow included":
    var t = assignBlocks(@[4, 4, 4, 9])
    let s = encodeTable(t)
    var back = decodeTable(s)
    check back.isSome
    check back.get.blocks == t.blocks
    check back.get.numberOf(4, 1) == t.numberOf(4, 1) and back.get.numberOf(9, 0) == t.numberOf(9, 0)
  test "garbage or a table of rules this build does not know is not a table":
    check decodeTable("").isNone
    check decodeTable("not json").isNone
    check decodeTable("{\"v\":99,\"b\":[]}").isNone
    check decodeTable("{\"v\":1,\"b\":[[1,2]]}").isNone
  test "the numbering of a run gives each step the number of its place and instance, in the order the steps are made":
    var n = newNumbering(assignBlocks(@[10, 20, 20, 30]))
    n.onSite("job_sh", 10)
    check n.lastNo == 0
    n.onSite("job_sh", 20)
    check n.lastNo == 1
    n.onSite("job_sh", 20)
    check n.lastNo == 2
    n.onSite("job_sh", 30)
    check n.lastNo == 11            # after the block of the line 20 (10 numbers)
  test "only steps are numbered: another host call leaves the number as it was":
    var n = newNumbering(assignBlocks(@[5]))
    n.onSite("now", 3)
    check n.lastNo == -1
    n.onSite("job_sh", 5)
    check n.lastNo == 0
  test "a replay of the same script goes through the same numbers":
    let script = """
      ci.job({image = "a"}, function(j)
        for i = 1, 3 do j:sh("x" .. i) end
        j:sh("tail")
      end)"""
    let table = buildTable(script).table
    var numbers: seq[int]
    for round in 1 .. 2:
      var sb = newSandbox()
      var jr: Journal
      var n = newNumbering(table)
      var got: seq[int]
      let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] = (got.add n.lastNo; some("0\n"))
      let r = replay.execute(sb, jr, script, host, onSite = proc (seq: int; kind: string; line: int) = n.onSite(kind, line))
      check r.status == esDone
      if round == 1: numbers = got
      else: check got == numbers
    check numbers == @[0, 1, 2, 10]
