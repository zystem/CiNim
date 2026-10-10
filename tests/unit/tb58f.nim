## PIP-005 / docs/parallel.md section 3.3: `b58f(format, ...)`, a pure function of the Lua API that builds an id from a format in which every number shows how many
## characters it takes: `{x}` is one character of Base58 (`b58x`), `{xx}` two (`b58xx`), anything else is a letter or digit that stands for itself. The format is
## checked as a whole before any number is looked at: its length (at most 8), its first character (a letter), its placeholders and the number of arguments.
import std/[unittest, strutils]
import executor/sandbox

proc eval(script: string): RunResult =
  var sb = newSandbox()
  sb.run(script)

suite "PIP-005 b58f":
  test "placeholders take the width they show, literals stand for themselves":
    check eval("""return b58f("a{xx}{xx}{xx}", 200, 199, 198)""").value == "a4T4S4R"
    check eval("""return b58f("a{x}{x}", 0, 57)""").value == "a1z"
    check eval("""return b58f("lint{xx}", 5)""").value == "lint16"
    check eval("""return b58f("ab{xx}c", 5)""").value == "ab16c"
    check eval("""return b58f("job7")""").value == "job7"            # no placeholder: a plain id, checked all the same
  test "the result is the same as joining b58x and b58xx by hand":
    check eval("""
      if b58f("a{xx}{x}{xx}", 12, 3, 4) == "a" .. b58xx(12) .. b58x(3) .. b58xx(4) then return "same" end
      return "differ" """).value == "same"
  test "exactly eight characters are allowed, nine are an error that says how many the format makes":
    check eval("""return #b58f("a{xx}{xx}{xx}{x}", 1, 2, 3, 4)""").value == "8"
    let r = eval("""return b58f("abc{xx}{xx}{xx}", 1, 2, 3)""")
    check r.code == "script_error"
    check "b58f" in r.message and "9 characters" in r.message and "8" in r.message
  test "the format is judged before the numbers: a format that is too long fails whatever the arguments":
    check eval("""return b58f("abc{xx}{xx}{xx}")""").code == "script_error"          # also without the arguments
    check "9 characters" in eval("""return b58f("abc{xx}{xx}{xx}")""").message
  test "an id starts with a letter: a placeholder or a digit first is an error":
    check eval("""return b58f("{xx}a", 1)""").code == "script_error"
    check eval("""return b58f("1a{xx}", 1)""").code == "script_error"
    check eval("""return b58f("")""").code == "script_error"
  test "only {x} and {xx} are placeholders, and only letters and digits are literals":
    for f in ["a{y}", "a{xxx}", "a{}", "a{xx", "a}", "a-{xx}", "a_{xx}", "a {xx}", "a%{xx}", "a{X}"]:
      check eval("return b58f(\"" & f & "\", 1)").code == "script_error"
  test "the number of arguments must be the number of placeholders":
    check eval("""return b58f("a{xx}{xx}", 1)""").code == "script_error"
    check eval("""return b58f("a{xx}", 1, 2)""").code == "script_error"
    check eval("""return b58f("a", 1)""").code == "script_error"
    check "2" in eval("""return b58f("a{xx}{xx}", 1)""").message
  test "a number that does not fit its placeholder is an error naming the argument":
    check eval("""return b58f("a{x}", 57)""").value == "az"
    let r = eval("""return b58f("a{x}{xx}", 1, 3364)""")
    check r.code == "script_error"
    check "3364" in r.message and "2" in r.message
    check eval("""return b58f("a{x}", 58)""").code == "script_error"
    check eval("""return b58f("a{xx}", -1)""").code == "script_error"
    check eval("""return b58f("a{xx}", 1.5)""").code == "script_error"
    check eval("""return b58f("a{xx}", "7")""").code == "script_error"
  test "the format must be a string":
    check eval("return b58f(5)").code == "script_error"
    check eval("return b58f()").code == "script_error"
  test "results of one format sort like the numbers, and every result is a valid id":
    check eval("""
      local last
      for i = 0, 200 do
        local s = b58f("a{xx}", i)
        if #s ~= 3 or s:find("[^A-Za-z0-9]") or not s:find("^[A-Za-z]") then return "bad " .. i end
        if last and not (last < s) then return "unordered at " .. i end
        last = s
      end
      return "ok" """).value == "ok"
  test "it is a pure function: no host call":
    check eval("""return b58f("a{x}", 1)""").code == "ok"
