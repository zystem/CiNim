## VAR-005: the header of the first step of a run - the effective values and their digest. Pure.
import std/[unittest, strutils, tables]
import ../../src/shim/varsheader

proc lookup(t: Table[string, string]): proc (name: string): string =
  result = proc (name: string): string = t.getOrDefault(name, "")

suite "VAR-005 the variables header":
  test "the digest is the first 12 hex digits of the SHA-256 of the sorted NAME=value lines joined by a newline (known values)":
    check digestOf(@["A=1", "B=2"]) == "c1f0203c784f"
    check digestOf(@["B=2", "A=1"]) == "c1f0203c784f"              # the order given does not matter
    check digestOf(newSeq[string]()) == "e3b0c44298fc"               # the SHA-256 of nothing
    check digestOf(@["A=1"]) != digestOf(@["A=2"])
  test "the header lists the values sorted by name, with the digest on its first line, every line marked as the shim's":
    let h = buildHeader("TARGET,REGION", lookup({"TARGET": "staging", "REGION": "eu"}.toTable), @[])
    let lines = h.splitLines
    check lines[0] == "cicd-shim: variables (digest " & digestOf(@["REGION=eu", "TARGET=staging"]) & ")"
    check lines[1] == "cicd-shim:   REGION=eu" and lines[2] == "cicd-shim:   TARGET=staging"
    check h.endsWith("\n")
  test "a secret is listed by name with ***, is not read, and is not in the digest":
    let env = {"URL": "https://x", "REGISTRY_PASSWORD": "hunter2hunter2"}.toTable
    let h = buildHeader("URL,REGISTRY_PASSWORD", lookup(env), @["REGISTRY_PASSWORD"])
    check "hunter2" notin h
    check "cicd-shim:   REGISTRY_PASSWORD=***" in h
    check h.splitLines[0] == "cicd-shim: variables (digest " & digestOf(@["URL=https://x"]) & ")"
  test "a step that has only secrets still says so; one with nothing says nothing":
    check "SECRET=***" in buildHeader("", lookup(initTable[string, string]()), @["SECRET"])
    check buildHeader("", lookup(initTable[string, string]()), @[]) == ""
    check buildHeader(",,", lookup(initTable[string, string]()), @[]) == ""
  test "a value that is empty is listed as empty; one with an = in it keeps it":
    let h = buildHeader("EMPTY,EQ", lookup({"EMPTY": "", "EQ": "a=b=c"}.toTable), @[])
    check "cicd-shim:   EMPTY=" & "\n" in h and "cicd-shim:   EQ=a=b=c" in h
