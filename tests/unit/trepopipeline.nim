## D-63: the pipeline of the repository (`.ci/pipeline.lua`) is a script that the platform can run: it loads, its parameters are declared, `run.source` is used, and the pass against the stub host
## gets as far as the first step's answer (the stub gives an empty answer to the step that finds the commit, which the script refuses: that is the first thing it needs to know).
import std/[unittest, strutils, json, re, sets]
import executor/pass
import common/crockford

import std/os
let script = readFile(if fileExists(".ci/pipeline.lua"): ".ci/pipeline.lua" else: currentSourcePath().parentDir.parentDir.parentDir / ".ci" / "pipeline.lua")

suite "D-63 .ci/pipeline.lua":
  test "it loads, declares its parameters, and asks the first step for the commit":
    let p = preflight(script, @[("REGISTRY", "registry:5000")], 1)
    check p.code == "script_error" and "no commit found" in p.message and not p.certain
    check "REGISTRY" in p.paramsJson and "TEST_JOBS" in p.paramsJson and "DEPLOY" in p.paramsJson
  test "REGISTRY is required, and a parameter of the wrong kind is refused before any step":
    let none = preflight(script, @[], 1)
    check none.code == "script_error" and "REGISTRY" in none.message and none.certain
    let bad = preflight(script, @[("REGISTRY", "r:5000"), ("TEST_JOBS", "0")], 1)
    check bad.certain and "TEST_JOBS" in bad.message
  test "the source of the run reaches the script (run.source) and is not a parameter":
    let p = preflight(script, @[("REGISTRY", "registry:5000"), ("@source.repository", "https://example.test/r.git"), ("@source.commit", "0123456789abcdef0123456789abcdef01234567"),
                                ("@source.path", ".ci/pipeline.lua")], 1)
    check p.code == "script_error" and "no commit found for 0123456789abcdef0123456789abcdef01234567" in p.message      # it took the commit from run.source, not from REF
    check "@source" notin p.paramsJson

suite "D-67 the ids written in .ci/pipeline.lua (the pass stops at the first step, so it cannot see them)":
  test "every job id and step id of the script is a valid id of its width, and the jobs written out are all different":
    var jobs = initHashSet[string]()
    for m in script.findAll(re"checked_out\('(\w+)'"):
      let id = m.split('\'')[1]
      check checkId(id, jobIdWidth).ok
      check normalizeId(id, jobIdWidth) notin jobs
      jobs.incl normalizeId(id, jobIdWidth)
    for m in script.findAll(re"ci\.single\['(\w+)'\]"):
      let id = m.split('\'')[1]
      check checkId(id, jobIdWidth).ok
      check normalizeId(id, jobIdWidth) notin jobs
      jobs.incl normalizeId(id, jobIdWidth)
    check jobs.len >= 6
    for m in script.findAll(re"step\.(?:sh|cache_restore|cache_save)\['(\w+)'\]"):
      let id = m.split('\'')[1]
      check checkId(id, stepIdWidth).ok
  test "the jobs made from the components (32 + the number of the component, in two characters) are valid and do not meet the others":
    var jobs = initHashSet[string]()
    for m in script.findAll(re"(?:checked_out|ci\.single)[\(\[]'(\w+)'"):
      jobs.incl normalizeId(m.split('\'')[1], jobIdWidth)
    for n in 1 .. 20:
      let id = idOfNumber(32 + n, jobIdWidth)
      check checkId(id, jobIdWidth).ok
      check id notin jobs

  test "D-82 the jobs that tag an image of BASE instead of building it (48 + the number of the component) are valid and meet neither the builds (32 + the number) nor the jobs written out":
    var jobs = initHashSet[string]()
    for m in script.findAll(re"(?:checked_out|ci\.single)[\(\[]'(\w+)'"):
      jobs.incl normalizeId(m.split('\'')[1], jobIdWidth)
    var all = jobs
    for n in 1 .. 5:                                              # the five images of the pipeline
      for base in [32, 48]:
        let id = idOfNumber(base + n, jobIdWidth)
        check checkId(id, jobIdWidth).ok
        check id notin all
        all.incl id
    check script.contains("48 + number[comp.target]") and script.contains("32 + number[comp.target]")
  test "D-82 the pipeline decides by what changed since the base the platform tells (run.source.base), and does not take the base as a parameter":
    check script.contains("run.source.base") and script.contains("local function plan(") and script.contains("RETAGGED")
    check not script.contains("BASE = ci.string")                    # the base is not a parameter: a trigger does not have to be told to give it

suite "D-63 the caches of .ci/pipeline.lua":
  test "a key that ends in '-' is a prefix, and the first key of a restore is exact: a restore that has a prefix only, as its first and only key, can never hit":
    # the cache of the compiled tests was never restored for this reason (the run took 17 minutes in the Pod instead of the few that a changed file costs)
    for m in script.findAll(re"cache_restore\[[^\]]*\]\{ *keys *= *\{[^}]*\}"):
      let keys = m[m.find('{', m.find("keys")) + 1 ..< m.rfind('}')].split(',')
      if keys.len == 1: check not keys[0].strip.endsWith("-\"") and keys[0].strip != "key"      # `key` is the prefix in the script: it needs an exact key before it
