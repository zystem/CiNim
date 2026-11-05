## D-82: the flow of .ci/pipeline.lua, run against a host that answers the steps by what they are (the first one tells what changed since BASE, the retag of an image says whether there was one):
## which images are built and which are tagged from the image of BASE, whether the tests run, whether the deploy is there. Pure: nothing is made anywhere.
import std/[unittest, options, strutils, os, sets, sequtils, algorithm]
import executor/[sandbox, journal, replay]

let script = readFile(if fileExists(".ci/pipeline.lua"): ".ci/pipeline.lua" else: currentSourcePath().parentDir.parentDir.parentDir / ".ci" / "pipeline.lua")

type Flow = object
  builds, retags: seq[string]      ## the components whose image was built (Kaniko) and tagged from BASE's
  tests, deploy, depsImage, testImage: bool
  registrySteps, withLogin, strayLogin: int   ## the steps that talk to the registry (Kaniko, crane), how many of them were given the Docker config, and how many steps that do not talk to it were
  checks: seq[string]              ## the images whose presence in the registry was asked (the libraries, the tests)
  copies: seq[string]              ## the copies of the images to the other registries (`crane copy`): the names of the images the job was given
  testEnv: string                  ## COMPONENTS and CHANGED_TESTS of the job of the tests
  status: string

proc flow(prepOutputs: string; base = ""; retagged: seq[(string, bool)] = @[]; deploy = false; login = false; present: seq[string] = @[]; pushAlso = ""; build = true): Flow =
  ## `prepOutputs`: the lines the first step answers (name=value). `base`: what the platform tells (run.source.base). `retagged`: for which component the retag finds an image (a component not named
  ## is found, when none is named all are)
  var answer = initHashSet[string]()
  for (c, found) in retagged: (if found: answer.incl c)
  let inRegistry = present.toHashSet
  var res = Flow()
  proc host(seq: int; kind, payload: string): Option[string] =
    if kind != "job_sh": return some("")
    let parts = payload.split('\t')
    let cmd = parts[^1]
    let meta = payload[0 ..< payload.len - cmd.len]            # the job and the step with what they were given (the secrets among it)
    let talks = "/kaniko/executor" in cmd or "crane " in cmd
    if talks: inc res.registrySteps
    if "REGISTRY_DOCKER_CONFIG" in meta: (if talks: inc res.withLogin else: inc res.strayLogin)
    if "git init -q --bare mirror.git" in cmd: return some("0\n" & prepOutputs)
    if "crane copy" in cmd:
      let at = meta.find("\"IMAGES\":\"")
      res.copies.add (if at >= 0: meta[at + 10 ..< meta.find('"', at + 10)] else: "?")
    if "crane manifest" in cmd:                                  # is the image of the libraries or of the tests there already?
      for name in ["cinim-deps", "cinim-test"]:
        if "NAME=" & name in cmd:
          res.checks.add name
          return some("0\nPRESENT=" & (if name in inRegistry: "yes" else: "no") & "\n")
      return some("0\nPRESENT=no\n")
    if "RETAGGED" in cmd and "base7" in cmd:
      let opts = parts[3]
      for c in ["cinim-controller", "cinim-conductor", "cinim-storage", "cinim-ui", "cinim"]:
        if "\"NAME\":\"" & c & "\"" in opts:
          let comp = if c == "cinim": "core" else: c.replace("cinim-", "")
          res.retags.add comp
          return some("0\nRETAGGED=" & (if (retagged.len == 0) or comp in answer: "yes" else: "no") & "\n")       # a pair is a line: it ends with a line break
      return some("0\nRETAGGED=no\n")
    if "/kaniko/executor" in cmd:
      for comp in ["core", "controller", "conductor", "storage", "ui"]:
        if "Dockerfile." & comp & " " in cmd: res.builds.add comp
      if "Dockerfile.deps " in cmd: res.depsImage = true
      if "Dockerfile.test " in cmd: res.testImage = true
    if "tools/test/run.sh" in cmd:
      res.tests = true
      let opts = parts[3]
      for k in ["COMPONENTS", "CHANGED_TESTS"]:
        let at = opts.find("\"" & k & "\":\"")
        if at >= 0:
          let from0 = at + k.len + 4
          res.testEnv.add k & "=" & opts[from0 ..< opts.find('"', from0)] & ";"
    if "helm upgrade" in cmd: res.deploy = true
    some("0\n")
  var sb = newSandbox()
  var j: Journal
  var params = @[("REGISTRY", "r:5000")]
  if deploy: params.add ("DEPLOY", "true")
  if login: params.add ("REGISTRY_LOGIN", "true")
  if pushAlso.len > 0: params.add ("PUSH_ALSO", pushAlso)
  if not build: params.add ("BUILD", "false")
  if base.len > 0: params.add [("@source.repository", "https://x/r.git"), ("@source.commit", "c"), ("@source.path", ".ci/pipeline.lua"), ("@source.base", base)]
  let r = execute(sb, j, script, host, runId = "flow", params = params)
  res.status = $r.status & (if r.message.len > 0: ": " & r.message else: "")
  res

func noSelection(env: string): bool =
  ## the job of the tests was given no list: all the tests run (the two names are there, with nothing after them)
  env.replace("COMPONENTS=;", "").replace("CHANGED_TESTS=;", "") == ""

const common = "SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nTAG=20261023-aaaaaaa\nDEPS=d1\nTESTDEPS=t1\nHELMDEPS=h1\n"
const goodBase = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
let allFive = @["conductor", "controller", "core", "storage", "ui"]

proc changed(areas: string; tests = "none"; extra: seq[(string, bool)] = @[]): Flow =
  ## the first job says that `areas` (and the changed test files `tests`) differ between the base and the commit
  flow(common & "BASE=" & goodBase & "\nAREAS=" & areas & "\nCHANGED_TESTS=" & tests & "\n", base = goodBase, retagged = extra)

suite "D-82 what the pipeline builds, tags and runs":
  test "no base (a run by hand, the first run, a script that came in the request): the five images are built, none is tagged, all the tests run":
    let f = flow(common)
    check f.status.startsWith("esDone")
    check f.builds.sorted == allFive and f.retags.len == 0 and f.tests and f.depsImage and f.testImage and f.testEnv.noSelection
  test "a base that the first job could not use (BASE=none, the base commit is not in the repository) is no base":
    let f = flow(common & "BASE=none\nAREAS=none\nCHANGED_TESTS=none\n", base = goodBase)
    check f.builds.sorted == allFive and f.retags.len == 0 and f.tests
  test "a change in the ui only: the ui is built, the other four are tagged from the images of the base, and the tests that import the ui and the router (which imports it) run":
    let f = changed("src/ui")
    check f.status.startsWith("esDone")
    check f.builds == @["ui"] and f.retags.sorted == @["conductor", "controller", "core", "storage"] and f.tests
    check f.testEnv == "COMPONENTS=router,ui;CHANGED_TESTS=;"
  test "a component's own source builds its image and the images made of it, and only those":
    check changed("src/shim").builds == @["controller"]
    check changed("src/jobcontroller").builds == @["controller"]
    check changed("src/core").builds == @["core"]
    check changed("src/conductor").builds == @["conductor"]
    check changed("src/storage").builds == @["storage"]
  test "what a component imports builds it too: the executor is in the core and the conductor; common is in all five":
    check changed("src/executor").builds.sorted == @["conductor", "core"]
    check changed("src/common").builds.sorted == allFive
    check changed("src/executor").testEnv.contains("COMPONENTS=conductor,core,executor")
  test "the proto builds the three that speak it, the Lua stubs the two that run Lua":
    check changed("proto").builds.sorted == @["conductor", "controller", "core"]
    check changed("lua").builds.sorted == @["conductor", "core"]
  test "the build files of everything build and test everything; common, the proto and the Lua stubs test everything":
    for a in ["cinim.nimble", "config.nims", "tools/image/build-static.sh", "tools/image/Dockerfile.deps", "tools/k8s", "tools/proto", "tools/shim"]:
      let f = changed(a)
      check f.builds.sorted == allFive and f.tests and f.testEnv.noSelection
    for a in ["src/common", "proto", "lua"]:
      check changed(a).tests and changed(a).testEnv.noSelection
  test "the Dockerfile of an image builds that image; the Dockerfile of the tests, the test support and the chart build none and run everything":
    check changed("tools/image/Dockerfile.ui").builds == @["ui"]
    check changed("tools/image/Dockerfile.ui").tests == false
    for a in ["tools/image/Dockerfile.test", "tests/support", "tools/test", ".ci", "deploy"]:
      let f = changed(a)
      check f.builds.len == 0 and f.retags.sorted == allFive and f.tests and f.testEnv.noSelection
  test "docs and the like build nothing and run nothing: the five are tagged":
    for a in ["docs", "docs-tr", "README.md", "CLAUDE.md", ".gitignore", "docs,docs-tr,README.md"]:
      let f = changed(a)
      check f.status.startsWith("esDone") and f.builds.len == 0 and f.retags.sorted == allFive and not f.tests and not f.testImage
  test "nothing changed (the base is the commit itself): nothing is built, the five are tagged, no test runs":
    let f = changed("none")
    check f.builds.len == 0 and f.retags.sorted == allFive and not f.tests
  test "several areas make the union":
    let f = changed("docs,src/ui,src/core,src/shim")
    check f.builds.sorted == @["controller", "core", "ui"] and f.retags.sorted == @["conductor", "controller", "core", "storage", "ui"].filterIt(it in ["conductor", "storage"])
  test "a path that is not known builds and tests everything":
    let f = changed("something")
    check f.builds.sorted == allFive and f.tests and f.testEnv.noSelection
  test "a changed test file runs even when nothing it imports changed, and nothing is built for it":
    let f = changed("tests/unit", tests = "tests/unit/tx.nim,tests/integration/ty.nim")
    check f.builds.len == 0 and f.tests and f.testEnv == "COMPONENTS=;CHANGED_TESTS=tests/unit/tx.nim,tests/integration/ty.nim;"
  test "so many changed test files that the list was not kept (all) run all the tests":
    let f = changed("tests/unit", tests = "all")
    check f.tests and f.testEnv.noSelection
  test "an image that the base has none of is built after all":
    let f = changed("src/ui", extra = @[("core", true), ("controller", true), ("conductor", true), ("storage", false)])
    check f.builds.sorted == @["storage", "ui"]
  test "the deploy follows whatever was built or tagged":
    let f = flow(common & "BASE=" & goodBase & "\nAREAS=docs\nCHANGED_TESTS=none\n", base = goodBase, deploy = true)
    check f.status.startsWith("esDone") and f.deploy

suite "the registry: any one, with a login or without (Docker config, crane and Kaniko)":
  test "no login (the plain registry of the cluster): no step is given the credential, and Kaniko and crane are the steps that talk to the registry":
    let f = flow(common)
    check f.registrySteps > 0 and f.withLogin == 0 and f.strayLogin == 0
  test "with REGISTRY_LOGIN every step that talks to the registry gets the Docker config, and no other step does":
    let f = flow(common, login = true)
    check f.registrySteps > 0 and f.withLogin == f.registrySteps and f.strayLogin == 0
    let g = changed("src/ui")                                    # the retags talk to it too
    check g.retags.len > 0
    let h = flow(common & "BASE=" & goodBase & "\nAREAS=src/ui\nCHANGED_TESTS=none\n", base = goodBase, login = true)
    check h.withLogin == h.registrySteps and h.strayLogin == 0
  test "the image of the libraries and the image of the tests are looked for in the registry first, and built when they are not there":
    let f = flow(common)
    check f.checks.sorted == @["cinim-deps", "cinim-test"] and f.depsImage and f.testImage
  test "images that the registry has already are not built again (the libraries and the tests are made once)":
    let f = flow(common, present = @["cinim-deps", "cinim-test"])
    check f.checks.len == 2 and not f.depsImage and not f.testImage and f.builds.sorted == allFive
  test "only one of them is there: the other is built":
    let f = flow(common, present = @["cinim-deps"])
    check not f.depsImage and f.testImage

suite "several registries for one project: the images are copied to the others":
  test "no other registry: nothing is copied":
    check flow(common).copies.len == 0
  test "other registries: one step copies the five images to each of them, and it is given the login (the Docker config holds them all)":
    let f = flow(common, login = true, pushAlso = "ghcr.io/acme, quay.io/acme")
    check f.copies.len == 1 and f.copies[0] == "cinim cinim-controller cinim-conductor cinim-storage cinim-ui"
    check f.withLogin == f.registrySteps and f.strayLogin == 0
  test "when nothing is built (BUILD is off) there is nothing new to copy":
    check flow(common, pushAlso = "ghcr.io/acme", build = false).copies.len == 0
  test "an image tagged from the base is copied as well: the other registries get the five tags of every run":
    let f = flow(common & "BASE=" & goodBase & "\nAREAS=src/ui\nCHANGED_TESTS=none\n", base = goodBase, pushAlso = "ghcr.io/acme")
    check f.retags.len == 4 and f.copies.len == 1
