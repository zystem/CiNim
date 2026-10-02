import std/[unittest, strutils, random]
import shim/dotenv

proc get(env: seq[EnvVar]; name: string): string =
  for e in env:
    if e.name == name: return e.value
  "<missing>"

proc rejects(text: string; code = "env_rejected"; secrets: seq[string] = @[]): bool =
  try:
    discard parseEnvFile(text, secrets)
    false
  except EnvError as e:
    e.code == code

suite "STO-003 dotenv subset":
  test "STO-003 NAME=VALUE lines, blank lines, later duplicate wins":
    let env = parseEnvFile("A=1\n\nB=two words\nA=3\n")
    check env.len == 2
    check env.get("A") == "3" and env.get("B") == "two words"

  test "STO-003 quoted values support escape sequences":
    let env = parseEnvFile("A=\"line1\\nline2\\t\\\"q\\\" \\\\\"\n")
    check env.get("A") == "line1\nline2\t\"q\" \\"

  test "STO-003 invalid escape, unterminated quote and stray quote are rejected":
    check rejects("A=\"bad\\x\"\n")
    check rejects("A=\"open\n")
    check rejects("A=\"in\"side\"\n")

  test "STO-003 multi-line NAME<<DELIM blocks":
    let env = parseEnvFile("A<<EOT\nfirst\n  second EOT\nEOT\nB=1\n")
    check env.get("A") == "first\n  second EOT"
    check env.get("B") == "1"
    check rejects("A<<EOT\nno end\n")
    check rejects("A<<bad delim\nx\nbad delim\n")

  test "STO-003 names are [A-Z_][A-Z0-9_]*":
    for bad in ["a=1", "1A=1", "A-B=1", "A B=1", "=1", "export A=1"]:
      check rejects(bad & "\n")
    check parseEnvFile("_X9=1\n").get("_X9") == "1"

  test "SEC-011 values are literal data, never interpreted by a shell":
    let env = parseEnvFile("A=$(rm -rf /)\nB=`id`\nC=$HOME;x\nD=a b  c\n")
    check env.get("A") == "$(rm -rf /)" and env.get("B") == "`id`"
    check env.get("C") == "$HOME;x" and env.get("D") == "a b  c"

suite "STO-004 deny-list":
  test "STO-004 loader, shell and interpreter hooks are rejected":
    for n in ["LD_PRELOAD", "LD_LIBRARY_PATH", "PATH", "IFS", "BASH_ENV", "ENV", "SHELL", "HOME", "NODE_OPTIONS",
              "PYTHONPATH", "CICD_ENV", "CICD_WORKSPACE", "BASH_FUNC_x%%", "DYLD_INSERT_LIBRARIES", "GLIBC_TUNABLES"]:
      check rejects(n & "=x\n")
    check rejects("LD_PRELOAD<<X\nv\nX\n")

  test "STO-004 ordinary names that merely contain a denied word are allowed":
    let env = parseEnvFile("MY_LD_FLAGS=1\nPATHOLOGY=2\nVERSION=1.2\nHOMEPAGE=x\n")
    check env.len == 4

suite "SEC-011 sizes and control sequences":
  test "SEC-011 control characters and escape sequences in values are rejected":
    check rejects("A=x\x1b[31mred\n")
    check rejects("A=x\x00y\n")
    check rejects("A=x\ry\n")
    check parseEnvFile("A=x\ty\n").get("A") == "x\ty"

  test "STO-003 limits: value 8 KiB, 256 keys, 64 KiB per step":
    check parseEnvFile("A=" & 'x'.repeat(8192) & "\n").get("A").len == 8192
    check rejects("A=" & 'x'.repeat(8193) & "\n")
    var many = ""
    for i in 0 ..< 256: many.add "K" & $i & "=1\n"
    check parseEnvFile(many).len == 256
    check rejects(many & "EXTRA=1\n")
    var big = ""
    for i in 0 ..< 9: big.add "V" & $i & "=" & 'y'.repeat(8000) & "\n"
    check rejects(big)

  test "STO-004 a known secret in a value gives secret_in_output":
    check rejects("TOKEN=abc-s3cr3t-def\n", "secret_in_output", @["s3cr3t"])
    check rejects("A=\"pre\\nfix-s3cr3t\"\n", "secret_in_output", @["s3cr3t"])
    check parseEnvFile("A=fine\n", @["s3cr3t"]).len == 1

  test "SEC-011 random input either parses or raises EnvError, never crashes":
    var r = initRand(7)
    let alphabet = "AB_=\"\\<\n\t x1$`'#\x1b\r"
    for _ in 0 ..< 20000:
      var s = ""
      for _ in 0 ..< r.rand(40): s.add alphabet[r.rand(alphabet.high)]
      try: discard parseEnvFile(s, @["x1"])
      except EnvError: discard
