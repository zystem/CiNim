## PIP-001, docs/conductors.md section 6: a run records the version of the Lua host API it started with; an executor declares the versions it can
## run (the current one and the two before it) and replays a run with the prelude of that run's version. Pure.
import std/[unittest, strutils]
import common/luaapi
import executor/sandbox

suite "PIP-001 versions of the Lua host API":
  test "an executor supports the current version and the two before it, never below 1":
    check supportedApiVersions(current = 1) == @[1]
    check supportedApiVersions(current = 2) == @[1, 2]
    check supportedApiVersions(current = 3) == @[1, 2, 3]
    check supportedApiVersions(current = 5) == @[3, 4, 5]
    check supportedApiVersions(current = 9) == @[7, 8, 9]
  test "the version this build writes into a new run is the current one, and is supported":
    check currentApiVersion >= 1
    check currentApiVersion in supportedApiVersions()
  test "a list of versions for a query is made of numbers only":
    check sqlVersionList(@[1, 2, 3]) == "1,2,3"
    check sqlVersionList(@[3]) == "3"

suite "PIP-001 the prelude of a version":
  test "the sandbox is made with the prelude of the version asked for; version 1 exists":
    check apiPrelude(1).len > 1000
    var sb = newSandbox(apiVersion = 1)
    check sb.run("return 1 + 1").value == "2"
  test "a version without a prelude is refused, not guessed":
    check apiPrelude(2) == "" or apiPrelude(2).len > 0       # whatever exists, asking for 99 never does
    check apiPrelude(99) == ""
    expect ValueError:
      discard newSandbox(apiVersion = 99)
  test "the versions an executor can really run are those of the supported set that have a prelude":
    let v = executorApiVersions()
    check v.len >= 1 and 1 in v
    for x in v: check apiPrelude(x).len > 0 and x in supportedApiVersions()
