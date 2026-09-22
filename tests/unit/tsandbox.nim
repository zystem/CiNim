import std/[unittest, strutils]
import executor/sandbox

proc ok(sb: var Sandbox, code: string): string =
  let r = sb.run(code)
  doAssert r.code == "ok", code & " -> " & r.code & ": " & r.message
  r.value

suite "PIP-005 sandbox determinism":
  test "PIP-005 plain script runs":
    var sb = newSandbox()
    check sb.ok("local a = 20 return a + 22") == "42"

  test "PIP-005 io, os, debug, package and friends are absent":
    var sb = newSandbox()
    check sb.ok("""
      local names = {"io","os","debug","package","require","dofile","loadfile","print","next"}
      local out = {}
      for i = 1, #names do out[i] = type(_G[names[i]]) end
      return table.concat(out, ",")""") == "nil,nil,nil,nil,nil,nil,nil,nil,nil"

  test "PIP-005 math.random and string.dump are removed":
    var sb = newSandbox()
    check sb.ok("return type(math.random) .. type(math.randomseed) .. type(string.dump)") ==
      "nilnilnil"

  test "PIP-005 load accepts only text chunks":
    var sb = newSandbox()
    check sb.ok("""return tostring(load("\27Lua") == nil)""") == "true"
    check sb.ok("""return tostring((pcall(load, function() end)))""") == "false"

  test "PIP-005 pairs iterates in stable type/value order":
    var sb = newSandbox()
    check sb.ok("""
      local t = {10, 20, 30, b = 1, a = 2, [true] = 3, [2.5] = 4, [100] = 5}
      local out = {}
      for k in pairs(t) do out[#out + 1] = tostring(k) end
      return table.concat(out, ",")""") == "1,2,3,true,2.5,100,a,b"

  test "PIP-005 pairs order is identical across states":
    let code = """
      local t = {}
      for i = 1, 200 do t["k" .. ((i * 7919) % 211)] = i end
      local out = {}
      for k in pairs(t) do out[#out + 1] = k end
      return table.concat(out, ",")"""
    var a = newSandbox()
    var b = newSandbox()
    check a.ok(code) == b.ok(code)

  test "PIP-005 table and function keys are rejected with script_nondeterminism":
    var sb = newSandbox()
    let r = sb.run("for _ in pairs({[{}] = 1}) do end")
    check r.code == "script_error"
    check "script_nondeterminism" in r.message

  test "PIP-005 tostring and %p do not leak addresses":
    var sb = newSandbox()
    check sb.ok("return tostring({}) .. '|' .. tostring(pairs) .. '|' .. string.format('%s', {})") ==
      "table|function|table"
    check sb.run("return string.format('%p', {})").code == "script_error"

  test "PIP-005 global environment is read-only":
    var sb = newSandbox()
    for code in ["x = 1", "_G.x = 1", "rawset(_G, 'x', 1)", "setmetatable(_G, {})",
                 "load('y = 1')()"]:
      let r = sb.run(code)
      check r.code == "script_error"
      check "read-only" in r.message or "protected" in r.message
    check sb.ok("return tostring(getmetatable(_G))") == "false"

  test "PIP-005 collectgarbage is restricted":
    var sb = newSandbox()
    check sb.ok("collectgarbage('collect') return 1") == "1"
    check sb.run("return collectgarbage('count')").code == "script_error"

  test "PIP-005 syntax errors are script errors":
    var sb = newSandbox()
    check sb.run("return +").code == "script_error"

suite "PIP-006 limits and escape corpus (acceptance 18)":
  test "PIP-006 infinite loop hits the instruction budget":
    var sb = newSandbox(instrLimit = 1_000_000)
    check sb.run("while true do end").code == "instruction_limit"

  test "PIP-006 infinite loop inside a coroutine hits the budget":
    var sb = newSandbox(instrLimit = 1_000_000)
    check sb.run("coroutine.wrap(function() while true do end end)()").code ==
      "instruction_limit"

  test "PIP-006 pcall cannot swallow the budget":
    var sb = newSandbox(instrLimit = 1_000_000)
    check sb.run("while true do pcall(function() while true do end end) end").code ==
      "instruction_limit"

  test "PIP-006 memory limit stops table growth":
    var sb = newSandbox(memLimit = 4 * 1024 * 1024)
    check sb.run("local t = {} for i = 1, 1e9 do t[i] = i end").code == "memory_limit"

  test "PIP-006 memory limit stops string.rep":
    var sb = newSandbox(memLimit = 4 * 1024 * 1024)
    check sb.run("return #string.rep('x', 1e9)").code == "memory_limit"

  test "PIP-006 pcall cannot hide a memory limit hit":
    var sb = newSandbox(memLimit = 4 * 1024 * 1024)
    check sb.run("pcall(string.rep, 'x', 1e9) return 1").code == "memory_limit"

  test "PIP-006 runaway recursion ends in a controlled error":
    var sb = newSandbox()
    let r = sb.run("local function f() return 1 + f() end return f()")
    check r.code in ["script_error", "memory_limit"]

  test "PIP-006 memory accounting is live":
    var sb = newSandbox()
    check sb.memUsed > 0
    check sb.memUsed < sb.memLimit
