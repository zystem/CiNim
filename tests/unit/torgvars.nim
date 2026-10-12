## VAR-003: what may be a variable of an organisation. Pure.
import std/[unittest, strutils]
import ../../src/core/orgvars

suite "VAR-003 the name and the value of a variable":
  test "a name is capital letters, digits and _, not starting with a digit":
    for ok in ["URL", "_X", "A1_B2", "REGISTRY_HOST"]: check checkVariable(ok, "v") == ""
    for bad in ["", "url", "1A", "A-B", "A B", "a", "N".repeat(65)]: check checkVariable(bad, "v") != ""
  test "the names a step's environment may not set (STO-004) are refused":
    for bad in ["PATH", "LD_PRELOAD", "CICD_ENV", "BASH_ENV", "HOME", "NODE_OPTIONS"]: check checkVariable(bad, "v") != ""
  test "a value is at most 8 KiB and has no control character but a newline and a tab":
    check checkVariable("X", "a".repeat(8192)) == ""
    check checkVariable("X", "a".repeat(8193)) != ""
    check checkVariable("X", "line one\nline two\tcolumn") == ""
    check checkVariable("X", "bell\a") != "" and checkVariable("X", "nul\0nul") != "" and checkVariable("X", "del\x7f") != ""
    check checkVariable("X", "") == ""                        # an empty value is a value
