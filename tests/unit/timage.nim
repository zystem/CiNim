## D-110: `j:image(opts)` builds an image of the source in `src`, pushes it to a registry (with a login or without, over TLS or plain HTTP), skips the build when the image is there already, tags the image of an earlier
## commit when nothing changed, and copies the result to other registries. The steps it makes (crane: is it there, tag it, copy it; Kaniko: build and push) are checked against a host that answers them by what they
## are. Pure: nothing is made anywhere. The digest of the image (what a signature is made over, and the only name of an image that cannot move) is told by the step that pushed or found it.
import std/[unittest, options, strutils, sequtils, os, osproc]
import executor/[sandbox, journal, replay]

type Call = object
  job, image, profile, opts, cmd: string

type Out = object
  status, message, value: string
  calls: seq[Call]

const digestA = "sha256:" & "a1b2c3d4e5f60718293a4b5c6d7e8f900a1b2c3d4e5f60718293a4b5c6d7e8f9"
const digestB = "sha256:" & "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
static: doAssert digestA.len == 71 and digestB.len == 71

proc runScript(body: string; action = "build"; buildExit = 0; buildDigest = digestA; foundDigest = digestB): Out =
  ## `action` is what the check step says (present, retagged or build); `buildExit` the code of the build; `buildDigest` what the build step says of the digest of what it pushed ("" says
  ## nothing), `foundDigest` what the check step says of the image it found or tagged
  var res = Out()
  proc host(seq: int; kind, payload: string): Option[string] =
    if kind == "now": return some("1793921212")
    if kind == "registry":            # D-114: the registry objects of the organisation: the address, plain HTTP, a login
      case payload
      of "gh": return some("ghcr.io/acme\n0\n1")
      of "hub": return some("docker.io/acme\n0\n1")
      of "lan": return some("10.0.0.5:5000\n1\n0")
      else: raise newException(HostRefusal, "this organisation has no registry " & payload)
    if kind != "job_sh": return some("")
    let parts = payload.split('\t')
    let cmd = parts[4 .. ^1].join("\t")
    res.calls.add Call(job: parts[0], image: parts[1], profile: parts[2], opts: parts[3], cmd: cmd)
    if "ACTION=" in cmd and "$CICD_OUTPUT" in cmd:        # the check step
      return some("0\nACTION=" & action & "\n" & (if action != "build" and foundDigest.len > 0: "DIGEST=" & foundDigest & "\n" else: ""))
    if "/kaniko/executor" in cmd: return some($buildExit & "\n" & (if buildDigest.len > 0 and buildExit == 0: "DIGEST=" & buildDigest & "\n" else: ""))
    some("0\n")
  var sb = newSandbox()
  var j: Journal
  let script = "return ci.pipeline({ name = 'x', main = function(run)\n" & body & "\nend })"
  let r = execute(sb, j, script, host, runId = "im")
  res.status = $r.status
  res.message = r.message
  res.value = r.value
  res

proc imageJob(opts: string; extra = ""): string =
  """
  local out
  ci.single['a']{ image = 'alpine', profile = 'build', workspace = 'isolated', body = function(j)
    out = j:image(""" & opts & """)
    """ & extra & """
  end }
  return out.action .. '|' .. out.ref .. '|' .. out.tag
"""

const base = "name = 'cinim', tag = 'T1', registry = 'reg.example.org/cinim', dockerfile = 'tools/image/Dockerfile.core'"

suite "D-110 j:image(): build and push":
  test "a plain build is one Kaniko step: the Dockerfile and the context in the source of the job, the image pushed to registry/name:tag, the cache beside it":
    let o = runScript(imageJob("{ " & base & " }"))
    check o.status == "esDone" and o.message == ""
    check o.calls.len == 1 and "ghcr.io/osscontainertools/kaniko" in o.calls[0].image and "@sha256:" in o.calls[0].image
    let k = o.calls[0].cmd
    check "--dockerfile=/cicd/workspace/src/tools/image/Dockerfile.core" in k and "--context=dir:///cicd/workspace/src" in k
    check "--destination=reg.example.org/cinim/cinim:T1" in k and "--cache=true" in k and "--cache-repo=reg.example.org/cinim/cinim-cache" in k
    check o.calls[0].profile == "build"
    check o.value == "build|reg.example.org/cinim/cinim:T1|T1"
  test "TLS is the default; a registry that speaks plain HTTP is said so, and Kaniko is told":
    check "--insecure" notin runScript(imageJob("{ " & base & " }")).calls[0].cmd
    let o = runScript(imageJob("{ " & base & ", insecure = true }"))
    check "--insecure" in o.calls[0].cmd and "--skip-tls-verify" in o.calls[0].cmd and "--insecure-pull" in o.calls[0].cmd
  test "more tags are more destinations, and the cache can be left out":
    let o = runScript(imageJob("{ " & base & ", tags = { 'latest', 'stable' }, cache = false }"))
    let k = o.calls[0].cmd
    check "--destination=reg.example.org/cinim/cinim:T1" in k and "--destination=reg.example.org/cinim/cinim:latest" in k and "--destination=reg.example.org/cinim/cinim:stable" in k
    check "--cache=false" in k and "cache-repo" notin k
  test "the target and the build arguments: the names are checked, and a value is quoted for the shell":
    let o = runScript(imageJob("{ " & base & ", target = 'build', build_args = { DEPS_IMAGE = 'reg.example.org/cinim/cinim-deps:abc', NOTE = [[it's here; rm -rf /]] } }"))
    let k = o.calls[0].cmd
    check "--target=build" in k and "--build-arg 'DEPS_IMAGE=reg.example.org/cinim/cinim-deps:abc'" in k
    check "--build-arg 'NOTE=it'\\''s here; rm -rf /'" in k
    check runScript(imageJob("{ " & base & ", build_args = { ['bad name'] = 'x' } }")).status == "esFailed"
    check runScript(imageJob("{ " & base & ", build_args = { lower = 'x' } }")).status == "esFailed"
  test "a build that fails fails the job, with the step":
    let o = runScript(imageJob("{ " & base & " }"), buildExit = 1)
    check o.status == "esFailed" and "step failed with code 1" in o.message

suite "D-110 j:image(): the digest of the image":
  const digestJob = """
  local out
  ci.single['a']{ image = 'alpine', profile = 'build', workspace = 'isolated', body = function(j)
    out = j:image({ """ & base & """, skip_if_present = true, also = { 'ghcr.io/acme' } })
  end }
  return out.action .. '|' .. tostring(out.digest) .. '|' .. tostring(out.ref_digest)
"""
  test "a build is told to write the digest of what it pushed where the next step finds it, and the step ends with the code of the build and not of what follows it":
    let o = runScript(imageJob("{ " & base & " }"))
    let k = o.calls[0].cmd
    check "--digest-file=" in k and "DIGEST=" in k and "$CICD_OUTPUT" in k
    check k.startsWith("set -e\n")                                   # a failed build is not hidden by the line that reads the digest
    check k.find("/kaniko/executor") < k.find("DIGEST=")
    check "$(cat" notin k and " cat " notin k                         # the files of the build image are gone after the build: only what the shell has in itself is used
  test "the result has the digest, and the name of the image by it":
    let o = runScript(digestJob, action = "build")
    check o.status == "esDone" and o.message == ""
    check o.value == "build|" & digestA & "|reg.example.org/cinim/cinim@" & digestA
  test "an image that is there, and one that is tagged from an earlier commit, has the digest that crane says":
    for action in ["present", "retagged"]:
      let o = runScript(digestJob, action = action)
      check o.status == "esDone"
      check o.value == action & "|" & digestB & "|reg.example.org/cinim/cinim@" & digestB
      check "crane digest" in o.calls[0].cmd
  test "the digest of an image is never guessed: a build or a check that says none, or something that is not a sha256 digest, fails the job":
    check runScript(digestJob, action = "build", buildDigest = "").status == "esFailed"
    check runScript(digestJob, action = "present", foundDigest = "").status == "esFailed"
    for bad in ["sha256:abc", "md5:" & "a".repeat(64), "sha256:" & "G".repeat(64), "sha256:" & "a".repeat(64) & "x", "latest"]:
      let o = runScript(digestJob, action = "build", buildDigest = bad)
      check o.status == "esFailed" and "digest" in o.message
  test "the copies to other registries do not change the digest (crane copy keeps the manifest)":
    let o = runScript(digestJob, action = "build")
    check "crane copy" in o.calls[^1].cmd and o.value.contains(digestA)

suite "D-110 j:image(): the digest, in a real shell":
  # The steps are shell: what the fake host cannot show is run here, with a stand-in for the executor of Kaniko (which writes the file `--digest-file` names, or does not, or fails) and one for crane.
  proc inShell(script, stubBody: string; stubName = "executor"; env = ""): tuple[code: int, outputs: string] =
    let dir = getTempDir() / ("timage-" & $getCurrentProcessId() & "-" & stubName)
    removeDir dir
    createDir dir
    defer: removeDir dir
    writeFile(dir / "stub", "#!/bin/sh\n" & stubBody)
    setFilePermissions(dir / "stub", {fpUserRead, fpUserWrite, fpUserExec})
    let patched = script.replace("/kaniko/executor", dir / "stub").replace("crane digest", dir / "stub digest").replace("crane manifest", "true").replace("crane tag", "true")
    writeFile(dir / "step.sh", patched)
    let (o, c) = execCmdEx("CICD_RUN_DIR=" & quoteShell(dir) & " CICD_OUTPUT=" & quoteShell(dir / "out") & " TAG=T1 NAME=cinim REG=reg.example.org/cinim " & env & " sh " & quoteShell(dir / "step.sh") & " 2>&1")
    (c, (try: readFile(dir / "out") except IOError: "") & o)
  let buildCmd = runScript(imageJob("{ " & base & " }")).calls[0].cmd
  let checkCmd = runScript(imageJob("{ " & base & ", skip_if_present = true }"), action = "present").calls[0].cmd

  test "the executor writes the digest where it was told: the step says it, and ends with 0":
    let writes = "for a in \"$@\"; do case $a in --digest-file=*) printf '%s' '" & "sha256:" & "b".repeat(64) & "' > \"${a#--digest-file=}\";; esac; done"
    let r = inShell(buildCmd, writes)
    check r.code == 0
    check r.outputs.contains("DIGEST=sha256:" & "b".repeat(64))
  test "an executor that fails ends the step with its own code, and no digest is said":
    let r = inShell(buildCmd, "exit 3", "failing")
    check r.code == 3
    check "DIGEST=" notin r.outputs
  test "an executor that writes the digest and then fails still fails the step":
    let r = inShell(buildCmd, """for a in "$@"; do case $a in --digest-file=*) printf 'sha256:%s' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "${a#--digest-file=}";; esac; done; exit 1""", "late")
    check r.code == 1
  test "an executor that writes no digest fails the step, and does not leave an empty one for the next":
    let r = inShell(buildCmd, "exit 0", "silent")
    check r.code != 0
    check "DIGEST=sha256" notin r.outputs
  test "the check step says the digest that crane says of the image under the tag":
    let r = inShell(checkCmd, "echo sha256:" & "c".repeat(64), "crane", "SKIP_IF_PRESENT=yes")
    check r.code == 0
    check r.outputs.contains("ACTION=present") and r.outputs.contains("DIGEST=sha256:" & "c".repeat(64))
  test "a crane that cannot say the digest fails the check step: an image is not named without it":
    let r = inShell(checkCmd, "exit 1", "nocrane", "SKIP_IF_PRESENT=yes")
    check r.code != 0

suite "D-110 j:image(): the login of the registry":
  test "without a login no step is given a secret and no Docker config is written":
    let o = runScript(imageJob("{ " & base & " }"))
    check "REGISTRY_DOCKER_CONFIG" notin o.calls[0].opts and "config.json" notin o.calls[0].cmd
  test "with login = true every step that talks to the registry gets the secret REGISTRY_DOCKER_CONFIG, and writes it where Kaniko and crane look for it":
    let o = runScript(imageJob("{ " & base & ", login = true, skip_if_present = true, also = { 'ghcr.io/acme' } }"), action = "build")
    check o.calls.len == 3
    for c in o.calls:
      check "REGISTRY_DOCKER_CONFIG" in c.opts and "config.json" in c.cmd
    check "DOCKER_CONFIG=/kaniko/.docker" in o.calls[1].cmd and "DOCKER_CONFIG=$CICD_RUN_DIR/docker" in o.calls[0].cmd
  test "the secret can have another name; a name that is not one is refused":
    let o = runScript(imageJob("{ " & base & ", login = 'GHCR_CONFIG' }"))
    check "GHCR_CONFIG" in o.calls[0].opts and "${GHCR_CONFIG:-}" in o.calls[0].cmd and "REGISTRY_DOCKER_CONFIG" notin o.calls[0].opts
    check runScript(imageJob("{ " & base & ", login = 'bad name; x' }")).status == "esFailed"
    check runScript(imageJob("{ " & base & ", login = 5 }")).status == "esFailed"

suite "D-110 j:image(): the image is there already, or the image of the base will do":
  test "skip_if_present asks crane first, and an image that is there is not built":
    let o = runScript(imageJob("{ " & base & ", skip_if_present = true }"), action = "present")
    check o.status == "esDone" and o.calls.len == 1 and "go-containerregistry/crane" in o.calls[0].image and "@sha256:" in o.calls[0].image
    check "crane manifest" in o.calls[0].cmd and "\"SKIP_IF_PRESENT\":\"yes\"" in o.calls[0].opts
    check o.value == "present|reg.example.org/cinim/cinim:T1|T1"
  test "an image that is not there is built after the check":
    let o = runScript(imageJob("{ " & base & ", skip_if_present = true }"), action = "build")
    check o.calls.len == 2 and "/kaniko/executor" in o.calls[1].cmd and o.value.startsWith("build|")
  test "reuse: the image of an earlier commit (a tag with that ending) is tagged with the new tag, and nothing is built; with none the image is built":
    let opts = "{ " & base & ", reuse = { suffix = '-bbbbbbb' } }"
    let o = runScript(imageJob(opts), action = "retagged")
    check o.calls.len == 1 and "crane tag" in o.calls[0].cmd and "crane ls" in o.calls[0].cmd and "\"REUSE_SUFFIX\":\"-bbbbbbb\"" in o.calls[0].opts
    check o.value.startsWith("retagged|")
    let b = runScript(imageJob(opts), action = "build")
    check b.calls.len == 2 and b.value.startsWith("build|")
  test "the suffix is a plain ending, not a pattern":
    check runScript(imageJob("{ " & base & ", reuse = { suffix = '.*' } }")).status == "esFailed"
    check runScript(imageJob("{ " & base & ", reuse = { } }")).status == "esFailed"

suite "D-110 j:image(): other registries of the project":
  test "after the image is there (built, tagged or found) one step copies every tag to every other registry":
    for action in ["build", "retagged", "present"]:
      let o = runScript(imageJob("{ " & base & ", tags = { 'latest' }, skip_if_present = true, also = { 'ghcr.io/acme', 'quay.io/acme' } }"), action = action)
      let copy = o.calls[^1]
      check "crane copy" in copy.cmd and "go-containerregistry/crane" in copy.image
      check "\"ALSO\":\"ghcr.io/acme quay.io/acme\"" in copy.opts and "\"TAGS\":\"T1 latest\"" in copy.opts
  test "a registry that is not an address is refused":
    check runScript(imageJob("{ " & base & ", also = { 'ghcr.io/acme; rm -rf /' } }")).status == "esFailed"
    check runScript(imageJob("{ " & base & ", also = 'ghcr.io/acme' }")).status == "esFailed"

suite "D-110 j:image(): what is asked is checked before any step is made":
  test "the name, the tag, the registry and the Dockerfile are what they can be":
    for bad in ["name = 'Has Space'", "name = '-x'", "tag = 'a b'", "tag = ''", "tags = { 'a b' }", "registry = 'https://reg.example.org'", "registry = 'reg example'", "dockerfile = '../x'", "dockerfile = '/etc/passwd'"]:
      let o = runScript(imageJob("{ name = 'cinim', tag = 'T1', registry = 'reg.example.org/cinim', dockerfile = 'tools/image/Dockerfile.core', " & bad & " }"))
      check o.status == "esFailed" and o.calls.len == 0
  test "what is required is required, and an option that is not one is refused":
    for missing in ["name", "registry", "dockerfile"]:
      var o = runScript(imageJob("{ name = 'cinim', tag = 'T1', registry = 'r', dockerfile = 'D', " & missing & " = nil }"))
      check o.status == "esFailed" and missing in o.message and o.calls.len == 0
    let u = runScript(imageJob("{ " & base & ", colour = 'red' }"))
    check u.status == "esFailed" and "unknown field" in u.message and u.calls.len == 0
  test "the tag is the run's own (run.tag) when none is given":
    let o = runScript(imageJob("{ name = 'cinim', registry = 'r', dockerfile = 'D' }"))
    check o.status == "esDone" and "--destination=r/cinim:20261105" in o.calls[0].cmd and o.value == "build|r/cinim:20261105|20261105"
  test "two images in one job do not take each other's step ids; a tenth is refused":
    let o = runScript("""
      ci.single['a']{ image = 'alpine', profile = 'build', workspace = 'isolated', body = function(j)
        j:image({ name = 'one', tag = 'T', registry = 'r', dockerfile = 'D1' })
        j:image({ name = 'two', tag = 'T', registry = 'r', dockerfile = 'D2' })
      end }""")
    check o.status == "esDone" and o.calls.len == 2 and "--destination=r/one:T" in o.calls[0].cmd and "--destination=r/two:T" in o.calls[1].cmd
    let many = runScript("""
      ci.single['a']{ image = 'alpine', profile = 'build', workspace = 'isolated', body = function(j)
        for i = 1, 10 do j:image({ name = 'n' .. i, tag = 'T', registry = 'r', dockerfile = 'D' }) end
      end }""")
    check many.status == "esFailed" and "at most" in many.message

suite "D-114 j:image(): a registry given by name":
  test "the address comes from the registry object, and so does the login: the steps that talk to it are given the registry by name, never a secret of the pipeline":
    let o = runScript(imageJob("{ name = 'cinim', tag = 'T1', registry = { name = 'gh' }, dockerfile = 'D', skip_if_present = true }"), action = "build")
    check o.status == "esDone" and o.calls.len == 2
    check o.value == "build|ghcr.io/acme/cinim:T1|T1"
    check "--destination=ghcr.io/acme/cinim:T1" in o.calls[1].cmd and "--cache-repo=ghcr.io/acme/cinim-cache" in o.calls[1].cmd
    for c in o.calls:
      check "\"registries\":[\"gh\"]" in c.opts and "\"secrets\"" notin c.opts and "CINIM_REGISTRY_CONFIG" in c.cmd and "config.json" in c.cmd
    check "\"REG\":\"ghcr.io/acme\"" in o.calls[0].opts
  test "a registry that has no login (the registry of the cluster) gets no login: no step is given a Docker config, and its plain HTTP is used":
    let o = runScript(imageJob("{ name = 'cinim', tag = 'T1', registry = { name = 'lan' }, dockerfile = 'D' }"))
    check o.status == "esDone" and o.calls.len == 1
    check "registries" notin o.calls[0].opts and "config.json" notin o.calls[0].cmd
    check "--destination=10.0.0.5:5000/cinim:T1" in o.calls[0].cmd and "--insecure" in o.calls[0].cmd and "--skip-tls-verify" in o.calls[0].cmd
  test "other registries by name: their logins are in the same config, the names sorted and told once":
    let o = runScript(imageJob("{ name = 'cinim', tag = 'T1', registry = { name = 'gh' }, dockerfile = 'D', also = { { name = 'hub' }, { name = 'gh' }, 'quay.io/acme' } }"))
    check o.status == "esDone" and o.calls.len == 2
    check "\"ALSO\":\"docker.io/acme ghcr.io/acme quay.io/acme\"" in o.calls[1].opts
    for c in o.calls: check "\"registries\":[\"gh\",\"hub\"]" in c.opts
  test "a registry given by name beside `login` is refused, so is a name that is not one, and so is one that the organisation has not":
    check runScript(imageJob("{ name = 'cinim', tag = 'T1', registry = { name = 'gh' }, dockerfile = 'D', login = true }")).status == "esFailed"
    for bad in ["{ name = 'Gh' }", "{ name = 'gh', path = 'x' }", "{ }", "{ name = 5 }", "{ name = 'a b' }", "{ name = 'gh;rm' }"]:
      let o = runScript(imageJob("{ name = 'cinim', tag = 'T1', registry = " & bad & ", dockerfile = 'D' }"))
      check o.status == "esFailed" and o.calls.len == 0
    let n = runScript(imageJob("{ name = 'cinim', tag = 'T1', registry = { name = 'nowhere' }, dockerfile = 'D' }"))
    check n.status == "esFailed" and "no registry nowhere" in n.message and n.calls.len == 0

suite "D-114 step.sh: registries":
  proc shRun(opts: string): Out =
    runScript("""
    ci.single['a']{ image = 'alpine', steps = { step.sh['b']{ cmd = 'echo hi', """ & opts & """ } } }
    """)
  test "a step that names registries asks for them in its options, sorted and without repeats":
    let o = shRun("registries = { 'hub', 'gh', 'hub' }")
    check o.status == "esDone" and o.calls.len == 1 and "\"registries\":[\"gh\",\"hub\"]" in o.calls[0].opts
  test "a name that is not a registry name is refused, so is a list of more than eight, so is the variable that the core makes in `secrets`":
    for bad in ["registries = 'gh'", "registries = { 5 }", "registries = { 'Gh' }", "registries = { 'a b' }", "registries = { 'a','b','c','d','e','f','g','h','i' }",
                "secrets = { 'CINIM_REGISTRY_CONFIG' }", "secrets = { 'CINIM_API_TOKEN' }"]:
      check shRun(bad).status == "esFailed"
  test "an empty list asks for nothing":
    let o = shRun("registries = { }")
    check o.status == "esDone" and "registries" notin o.calls[0].opts
