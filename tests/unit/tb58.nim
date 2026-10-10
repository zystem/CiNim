## PIP-005 / docs/parallel.md section 3.3: `b58x(n)` and `b58xx(n)`, pure functions of the Lua API that write a small integer as exactly one or exactly two characters of
## the Base58 alphabet (no 0, O, I, l), so that loop variables fit into an id of at most 8 characters ("a" .. b58xx(i) .. b58xx(j) .. b58xx(k) is 7). Too big a number
## is an error, never a longer or a shorter result.
import std/[unittest, strutils]
import executor/sandbox

proc eval(script: string): RunResult =
  var sb = newSandbox()
  sb.run(script)

const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

suite "PIP-005 b58x and b58xx":
  test "the alphabet is the Base58 of Bitcoin: 58 characters, no 0 O I l, in the order of their codes":
    check alphabet.len == 58
    for ch in "0OIl": check ch notin alphabet
    for i in 1 ..< alphabet.len: check alphabet[i - 1] < alphabet[i]
  test "b58x is always one character, 0 to 57":
    check eval("return b58x(0)").value == "1"
    check eval("return b58x(8)").value == "9"
    check eval("return b58x(9)").value == "A"
    check eval("return b58x(17)").value == "J"          # I is not there
    check eval("return b58x(33)").value == "a"
    check eval("return b58x(44)").value == "m"          # l is not there
    check eval("return b58x(57)").value == "z"
  test "b58x fails when the number does not fit one character":
    check eval("return b58x(58)").code == "script_error"
    check "b58x" in eval("return b58x(58)").message and "58" in eval("return b58x(58)").message
  test "b58xx is always two characters, 0 to 3363, and 200 fits":
    check eval("return b58xx(0)").value == "11"
    check eval("return b58xx(9)").value == "1A"
    check eval("return b58xx(57)").value == "1z"
    check eval("return b58xx(58)").value == "21"
    check eval("return b58xx(200)").value == "4T"
    check eval("return b58xx(3363)").value == "zz"
  test "b58xx fails when the number does not fit two characters":
    check eval("return b58xx(3364)").code == "script_error"
    check "b58xx" in eval("return b58xx(3364)").message and "3364" in eval("return b58xx(3364)").message
  test "the results of one function sort like the numbers, so ids in a loop sort in the order of the loop":
    check eval("""
      local last
      for i = 0, 3363 do
        local s = b58xx(i)
        if last and not (last < s) then return "unordered at " .. i end
        last = s
      end
      last = nil
      for i = 0, 57 do
        local s = b58x(i)
        if last and not (last < s) then return "unordered one at " .. i end
        last = s
      end
      return "ok" """).value == "ok"
  test "every result is made of the alphabet only and has the length of its function, and a prefix letter gives a valid id":
    check eval("""
      local alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
      for i = 0, 3363 do
        local s = b58xx(i)
        if #s ~= 2 or s:find("[^" .. alphabet .. "]") then return "bad two " .. i end
      end
      for i = 0, 57 do
        local s = b58x(i)
        if #s ~= 1 or s:find("[^" .. alphabet .. "]") then return "bad one " .. i end
      end
      return "a" .. b58xx(200) .. b58xx(199) .. b58xx(198)""").value == "a4T4S4R"
  test "an integer-valued float is accepted, anything else is refused with a message":
    for f in ["b58x", "b58xx"]:
      check eval("return " & f & "(7.0)").code == "ok"
      check eval("return " & f & "(2.5)").code == "script_error"
      check eval("return " & f & "(-1)").code == "script_error"
      check eval("return " & f & "('7')").code == "script_error"
      check eval("return " & f & "()").code == "script_error"
      check eval("return " & f & "(0/0)").code == "script_error"
      check eval("return " & f & "(1e300)").code == "script_error"
    check eval("return b58x(7.0)").value == "8"
    check eval("return b58xx(7.0)").value == "18"
  test "they are pure functions: no host call, so they work in a script that has no host":
    check eval("return b58x(1) .. b58xx(1)").code == "ok"
