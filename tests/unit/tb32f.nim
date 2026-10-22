## PIP-018 / D-67: `b32f(format, ...)`, the one pure function of the Lua API that builds an id from loop variables in the alphabet of Crockford (lowercase). `{x}` is one character
## (0 to 31), `{xx}` two (0 to 1023), `{xxx}` three (0 to 32767), `{xxxx}` four (0 to 1048575); a letter or a digit of the alphabet in the format stands for itself. The result
## is exactly the characters of the format: it pads nothing (the padding of a short id is the rule of every id, `tcrockford`). Too big a number, a character outside the
## alphabet or a placeholder without an argument is an error, and the format is checked as a whole before any number is looked at.
import std/[unittest, strutils]
import executor/sandbox

proc eval(script: string): RunResult =
  var sb = newSandbox()
  sb.run(script)

const alphabet = "0123456789abcdefghjkmnpqrstvwxyz"

suite "D-67 b32f":
  test "D-67 the alphabet is Crockford's: 32 characters, the digits and the letters without i l o u, in the order of their codes":
    check alphabet.len == 32
    for ch in "ilou": check ch notin alphabet
    var prev = '\0'
    for ch in alphabet:
      check ch > prev
      prev = ch
  test "D-67 a placeholder is exactly as wide as it says":
    check eval("""return b32f("{x}", 0)""").value == "0"
    check eval("""return b32f("{x}", 31)""").value == "z"
    check eval("""return b32f("{xx}", 0)""").value == "00"
    check eval("""return b32f("{xx}", 1023)""").value == "zz"
    check eval("""return b32f("{xxx}", 0)""").value == "000"
    check eval("""return b32f("{xxx}", 32767)""").value == "zzz"
    check eval("""return b32f("{xxxx}", 0)""").value == "0000"
    check eval("""return b32f("{xxxx}", 1048575)""").value == "zzzz"
    check eval("""return b32f("{xxxx}", 1000)""").value == "00z8"
  test "D-67 the placeholders go in any combination, one argument to each":
    check eval("""return b32f("{x}{x}{x}", 1, 2, 3)""").value == "123"
    check eval("""return b32f("{x}{x}{x}", 10, 17, 31)""").value == "ahz"
    check eval("""return b32f("{xx}{xx}", 1, 33)""").value == "0111"
    check eval("""return b32f("{x}{xxx}", 5, 33)""").value == "5011"
    check eval("""return b32f("{xxx}{x}", 33, 5)""").value == "0115"
    check eval("""return b32f("{x}{xx}{x}", 1, 2, 3)""").value == "1023"
    check eval("""return b32f("{xxxx}", 33)""").value == "0011"
  test "D-67 a result is what the format says, nothing is added: three placeholders of one character are three characters":
    check eval("""return #b32f("{x}{x}{x}", 1, 2, 3)""").value == "3"
    check eval("""return #b32f("{x}", 1)""").value == "1"
    check eval("""return #b32f("a{x}{x}{x}", 1, 2, 3)""").value == "4"     # the author adds the fourth himself
  test "D-67 a letter or a digit of the alphabet in the format stands for itself, and the result is lowercase":
    check eval("""return b32f("b{xxx}", 33)""").value == "b011"
    check eval("""return b32f("{x}z", 3)""").value == "3z"
    check eval("""return b32f("AB{xx}", 3)""").value == "ab03"
  test "D-67 a character that is not in the alphabet is refused with its place: i l o u and the rest":
    for bad in ["i", "l", "o", "u", "I", "L", "O", "U", "-", " ", "_", "é"]:
      let r = eval("return b32f(\"a" & bad & "{x}\", 1)")
      check r.code == "script_error"
      check "b32f" in r.message
  test "D-67 a number that does not fit its placeholder is an error, never a longer or a shorter result":
    for (fmt, n) in [("{x}", "32"), ("{xx}", "1024"), ("{xxx}", "32768"), ("{xxxx}", "1048576"), ("{x}", "-1"), ("{xx}", "-5")]:
      let r = eval("return b32f(\"" & fmt & "\", " & n & ")")
      check r.code == "script_error"
      check "b32f" in r.message and n in r.message
    check eval("""return b32f("{x}", 1.5)""").code == "script_error"
    check eval("""return b32f("{x}", "7")""").code == "script_error"
    check eval("""return b32f("{x}", nil)""").code == "script_error"
  test "D-67 a format wider than the widest id, a step's four, is refused":
    check eval("""return b32f("{xxxx}{x}", 1, 1)""").code == "script_error"
    check eval("""return b32f("{xx}{xx}a", 1, 1)""").code == "script_error"
    check "at most 4" in eval("""return b32f("{xx}{xx}a", 1, 1)""").message
    check eval("""return b32f("{xx}{xx}", 1, 1)""").value == "0101"
  test "D-67 the number of arguments is the number of placeholders":
    check eval("""return b32f("{x}{x}", 1)""").code == "script_error"
    check eval("""return b32f("{x}", 1, 2)""").code == "script_error"
    check eval("""return b32f("ab", 1)""").code == "script_error"
    check eval("""return b32f("ab")""").value == "ab"
  test "D-67 the format is checked as a whole before any number is looked at":
    let r = eval("""return b32f("{x}{q}", 99, 1)""")           # the first number would not fit, but the second placeholder is wrong: that is what is said
    check r.code == "script_error" and "{q}" in r.message or "placeholder" in r.message
    check "does not fit" notin r.message
    check eval("""return b32f("{", 1)""").code == "script_error"
    check eval("""return b32f("{xxxxx}", 1)""").code == "script_error"
    check eval("""return b32f("{}", 1)""").code == "script_error"
    check eval("""return b32f("{X}", 1)""").code == "script_error"
    check eval("""return b32f(5, 1)""").code == "script_error"
    check eval("""return b32f()""").code == "script_error"
    check eval("""return b32f("")""").code == "script_error"
  test "D-67 the results of one placeholder sort like the numbers, so ids in a loop sort in the order of the loop":
    check eval("""
      local last
      for i = 0, 1023 do
        local s = b32f("{xx}", i)
        if last and not (last < s) then return "unordered at " .. i end
        last = s
      end
      last = nil
      for i = 0, 31 do
        local s = b32f("{x}", i)
        if last and not (last < s) then return "unordered one at " .. i end
        last = s
      end
      return "ok" """).value == "ok"
  test "D-67 every result is made of the alphabet only and has the width of its format":
    check eval("""
      local alphabet = "0123456789abcdefghjkmnpqrstvwxyz"
      for i = 0, 1023 do
        local s = b32f("{xx}", i)
        if #s ~= 2 or s:find("[^" .. alphabet .. "]") then return "bad two " .. i end
      end
      for i = 0, 32767, 7 do
        local s = b32f("{xxx}", i)
        if #s ~= 3 or s:find("[^" .. alphabet .. "]") then return "bad three " .. i end
      end
      return "ok" """).value == "ok"
  test "D-67 it is a pure function that the replay does not journal, and a global of the script":
    check eval("""return type(b32f)""").value == "function"
    check eval("""return tostring(b32x == nil and b32xx == nil)""").value == "true"
