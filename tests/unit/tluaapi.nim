## Lua API v1 (spec 6.7, PIP-017): signature file vs the normative function list vs the real sandbox.
import std/[unittest, strutils, sets, os]
import executor/sandbox

# names from the table in 6.7 (plus ci.vault from the text below it)
const specNames = ["ci.pipeline", "ci.string", "ci.number", "ci.bool", "ci.choice", "ci.list", "ci.map", "ci.secret", "ci.vault",
  "ci.stage", "ci.job", "ci.parallel", "ci.spawn", "ci.matrix", "ci.input", "ci.deploy", "ci.run", "ci.sleep", "ci.now",
  "ci.random", "ci.finally", "ci.log", "ci.fail",
  "Job:checkout", "Job:sh", "Job:use", "Job:env", "JobArtifact.upload", "JobArtifact.download", "JobCache.save", "JobCache.restore",
  "Handle:wait", "Handle:cancel"]
# implemented in the M0 sandbox bootstrap
const fixtureOnly = ["sh"]      # ci.sh is the spike-3 test fixture; API v1 has Job:sh

proc declaredFunctions(): HashSet[string] =
  for line in readFile("lua/stdlib/cicd.d.lua").splitLines:
    if line.startsWith("function "):
      let sig = line["function ".len .. ^1].split('(')[0]
      result.incl sig

suite "PIP-017 Lua API v1 signatures":
  test "PIP-017 the signature file declares exactly the functions of spec 6.7":
    let d = declaredFunctions()
    for n in specNames: check n in d
    check d.len == specNames.len       # nothing undocumented, nothing missing

  test "PIP-017 every declared function has a documented signature (annotations directly above)":
    let lines = readFile("lua/stdlib/cicd.d.lua").splitLines
    for i, l in lines:
      if l.startsWith("function ") and "()" notin l:
        check lines[i - 1].startsWith("---@")

  test "PIP-017 the signature file is valid Lua and loads in the sandbox":
    var sb = newSandbox()
    let r = sb.run(readFile("lua/stdlib/cicd.d.lua"))
    check r.code == "ok"

  test "PIP-005 the sandbox ci table exposes only API v1 names (plus the documented fixture)":
    var sb = newSandbox()
    let r = sb.run("local n = {} for k in pairs(ci) do n[#n + 1] = k end return table.concat(n, ',')")
    check r.code == "ok"
    for name in r.value.split(','):
      check ("ci." & name) in specNames or name in fixtureOnly
