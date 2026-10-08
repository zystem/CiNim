## Step secrets (6.7, VAR-002): the rules for names and values, the handles a step is assigned with, the names of the Secrets in the cluster.
import std/[unittest, json, tables, strutils]
import ../../src/core/stepsecrets
import ../../src/common/envname

suite "what may be a step secret":
  test "a name is an environment name that a step may be given":
    check checkName("REGISTRY_PASSWORD") == "" and checkName("_X") == "" and checkName("A1") == ""
    check checkName("lower").len > 0 and checkName("1A").len > 0 and checkName("A-B").len > 0 and checkName("").len > 0
    check checkName("A".repeat(65)).len > 0 and checkName("A".repeat(64)) == ""
  test "the names a file of the step may not set are not secrets either":
    for n in ["PATH", "LD_PRELOAD", "CICD_ENV", "BASH_ENV", "HOME", "NODE_OPTIONS"]: check checkName(n).len > 0
  test "a value is not empty, at most 8 KiB, and a line break or tab is the only control character":
    check checkValue("s3cret") == "" and checkValue("line1\nline2\tx") == ""
    check checkValue("").len > 0 and checkValue("x".repeat(8 * 1024 + 1)).len > 0 and checkValue("x".repeat(8 * 1024)) == ""
    check checkValue("a\x00b").len > 0 and checkValue("a\rb").len > 0 and checkValue("a\x7fb").len > 0

suite "the placeholder in the Pod":
  test "the Pod's environment holds a name-bearing placeholder, never a value":
    check stepSecretPlaceholder("REGISTRY_PASSWORD") == "cinim-secret:REGISTRY_PASSWORD"

suite "what a step asked for":
  test "the names come from the options JSON of the step; no options, no secrets, damaged options, none":
    check secretNamesOf("""{"mask":{"min_length":4},"secrets":["A","B"],"timeout":60}""") == @["A", "B"]
    check secretNamesOf("").len == 0 and secretNamesOf("""{"timeout":5}""").len == 0 and secretNamesOf("{oops").len == 0
  test "a name that was never defined is missing":
    var have = initTable[string, int]()
    have["A"] = 3
    check missingSecrets(have, @["A", "B"]) == @["B"]
    check missingSecrets(have, @["A"]).len == 0
