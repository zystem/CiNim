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
  test "a run found by a poll at a ref is on that ref, though it is asked for by the hash; a hash from elsewhere is on none":
    let sha = "0123456789abcdef0123456789abcdef01234567"
    check runRefOf("main", sha) == "main" and runRefOf("", sha) == "" and runRefOf("", "feature/x") == "feature/x" and runRefOf("", "") == ""
    check runRefOf("release/1", "main") == "release/1"                       # the ref the poll looked at, not what the commit is asked for by
  test "a ref is protected if any pattern holds it":
    check protectedBy(@["main", "release/*"], "release/2") and protectedBy(@["main", "release/*"], "main")
    check not protectedBy(@["main", "release/*"], "feature/x") and not protectedBy(@[], "main") and not protectedBy(@["main"], "")
  test "the profiles that need a grant are build and deploy":
    check privilegedProfiles == ["build", "deploy"]

suite "the longest step of a project (max_step_timeout)":
  test "the timeout of a step is read from its options; none, or a bad text, is 0":
    check stepTimeoutOf("""{"mask":{"min_length":4},"timeout":259200}""") == 259200
    check stepTimeoutOf("") == 0 and stepTimeoutOf("{}") == 0 and stepTimeoutOf("not json") == 0 and stepTimeoutOf("""{"timeout":"3h"}""") == 0
  test "the limits: a week is the most, a minute the least, 24 hours the default of the shard":
    check maxStepTimeoutLimit == 7 * 24 * 3600 and minStepTimeoutLimit == 60 and defaultStepTimeoutLimit == 24 * 3600
    check stepTimeoutDefault() == defaultStepTimeoutLimit            # no CINIM_MAX_STEP_TIMEOUT in the environment of the tests
