## Step secrets (6.7, VAR-002): the rules for names and values, the handles a step is assigned with, the names of the Secrets in the cluster.
import std/[unittest, json, tables, strutils]
import ../../src/core/stepsecrets
import ../../src/common/envname
import ../../src/core/orgprovision

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

suite "handles and the Secrets in the cluster":
  test "a handle is NAME:version and reads back":
    check handleOf("A_B", 3) == "A_B:3"
    let h = parseHandle("A_B:3")
    check h.ok and h.name == "A_B" and h.version == 3
    check not parseHandle("nocolon").ok and not parseHandle("A:x").ok and not parseHandle(":3").ok and not parseHandle("A:-1").ok
  test "the Secret of a version is named from the secret and the version, and is a valid Kubernetes name":
    check stepSecretObjectName("REGISTRY_PASSWORD", 3) == "cinim-s-registry-password-v3"
    check stepSecretObjectName("A", 12) == "cinim-s-a-v12"
    for ch in stepSecretObjectName("_X_1__Y", 1): check ch in {'a'..'z', '0'..'9', '-'}
  test "the object carries the value in the key `value` and says whose it is":
    let cfg = ProvisionConfig(prefix: "cinim", shard: "001", shardNamespace: "cinim-001")
    let o = stepSecretObject(cfg, "acme", "REGISTRY_PASSWORD", 2, "s3cret")
    check o["metadata"]["name"].getStr == "cinim-s-registry-password-v2" and o["metadata"]["namespace"].getStr == "cinim-001-acme"
    check o["stringData"]["value"].getStr == "s3cret" and o["metadata"]["labels"]["cinim.io/organization"].getStr == "acme"

suite "what a step asked for":
  test "the names come from the options JSON of the step; no options, no secrets, damaged options, none":
    check secretNamesOf("""{"mask":{"min_length":4},"secrets":["A","B"],"timeout":60}""") == @["A", "B"]
    check secretNamesOf("").len == 0 and secretNamesOf("""{"timeout":5}""").len == 0 and secretNamesOf("{oops").len == 0
  test "a name that was never defined is missing, the handles carry the version at the moment of the assignment":
    var have = initTable[string, int]()
    have["A"] = 3
    check missingSecrets(have, @["A", "B"]) == @["B"]
    check handlesFor(have, @["A"]) == @["A:3"]
    check handlesFor(have, @["A", "B"]) == @["A:3", "B:0"]       # version 0 is a Secret that does not exist: the Pod says so
