## D-86: which refs are protected, and how a run is told to be on one. Pure.
import std/unittest
import std/strutils
import ../../src/core/projectpolicy

suite "D-86 the refs of a project":
  test "a pattern is a name, or a name followed by one star; nothing else matches":
    check refMatches("main", "main") and not refMatches("main", "main2") and not refMatches("main", "xmain") and not refMatches("main", "Main")
    check refMatches("release/*", "release/1.2") and refMatches("release/*", "release/") and not refMatches("release/*", "release") and not refMatches("release/*", "releases/1")
    check refMatches("v*", "v1.0.0") and refMatches("v*", "v") and not refMatches("v*", "x-v1")
    check not refMatches("*", "main") and not refMatches("", "main") and not refMatches("main", "")
    check not refMatches("ma*in", "main")                              # only a star at the end means a prefix; here it is a name with a star in it, which no ref has
  test "what may be a pattern":
    for p in ["main", "release/*", "v*", "feature/x.y_z-1", "a"]: check isRefPattern(p)
    for p in ["", "*", "a*b", "**", "a b", "a;b", "$(x)", "a\nb", "x".repeat(101)]: check not isRefPattern(p)
  test "a hash has no ref, a name is its own":
    check refNameOf("main") == "main" and refNameOf("release/1.0") == "release/1.0" and refNameOf("") == ""
    check refNameOf("0123456789abcdef0123456789abcdef01234567") == "" and refNameOf("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") == ""
    check refNameOf("0123456789abcdef0123456789abcdef0123456") == "0123456789abcdef0123456789abcdef0123456"       # 39 digits: a name, not a hash
    check refNameOf("0123456789abcdef0123456789abcdef0123456g") == "0123456789abcdef0123456789abcdef0123456g"
  test "a ref is protected if any pattern holds it":
    check protectedBy(@["main", "release/*"], "release/2") and protectedBy(@["main", "release/*"], "main")
    check not protectedBy(@["main", "release/*"], "feature/x") and not protectedBy(@[], "main") and not protectedBy(@["main"], "")
  test "the profiles that need a grant are build and deploy":
    check privilegedProfiles == ["build", "deploy"]
