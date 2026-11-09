## D-115: the names of the deploy profiles of an organisation and of their accounts and namespaces, and what the gate takes for a deploy profile.
import std/[unittest, json, strutils]
import core/[deployprofiles, projectpolicy]

suite "D-115 deploy profiles: names":
  test "a profile is named by lowercase letters, digits, - and _, starting with a letter; the built-in words are not names":
    for ok in ["test1", "prod-eu", "self_build", "a"]: check validDeployProfileName(ok)
    for bad in ["", "Test", "1test", "a b", "a.b", "-a", "deploy", "build", "default", "x".repeat(41)]: check not validDeployProfileName(bad)
  test "an account and a namespace are DNS labels":
    for ok in ["deploy-test1", "cinim-deployer", "a", "x".repeat(63)]: check validServiceAccountName(ok)
    for bad in ["", "-a", "a-", "A", "a_b", "a.b", "x".repeat(64)]: check not validServiceAccountName(bad)
  test "a namespace is a name, a prefix with one * at the end, or * alone; a pattern matches the names that begin so":
    for ok in ["test1", "test*", "*", "team-a*", "a"]: check isNamespacePattern(ok)
    for bad in ["", "Test", "te*st", "*test", "t**", "-a", "a-", "a_b", "x".repeat(64), "a b"]: check not isNamespacePattern(bad)
    check namespaceMatches("test1", "test1") and not namespaceMatches("test1", "test10") and not namespaceMatches("test1", "test2")
    check namespaceMatches("test*", "test1") and namespaceMatches("test*", "test") and namespaceMatches("test*", "test-eu") and not namespaceMatches("test*", "prod")
    check namespaceMatches("*", "anything") and not namespaceMatches("*", "") and not namespaceMatches("", "x")
    check isPlainNamespace("test1") and not isPlainNamespace("test*") and not isPlainNamespace("*") and not isPlainNamespace("")
  test "the gate treats `deploy` and an organisation's profile alike, and neither the ordinary profile nor build":
    check isDeployKind("deploy") and isDeployKind("test1") and isDeployKind("self")
    check not isDeployKind("") and not isDeployKind("build") and not isDeployKind("default")
  test "a profile's view tells whether it has a token, and the namespace as it was given":
    let p = DeployProfile(name: "test1", serviceAccount: "deploy-test1", targetNamespace: "test1")
    check p.view["token"].getBool and p.view["namespace"].getStr == "test1"
    check not DeployProfile(name: "local", targetNamespace: "*").view["token"].getBool
