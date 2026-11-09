## D-110: `j:image(opts)` builds an image of the source in `src`, pushes it to a registry (with a login or without, over TLS or plain HTTP), skips the build when the image is there already, tags the image of an earlier
## commit when nothing changed, and copies the result to other registries. The steps it makes (crane: is it there, tag it, copy it; Kaniko: build and push) are checked against a host that answers them by what they
## are. Pure: nothing is made anywhere.
import std/[unittest, options, strutils, sequtils]
import executor/[sandbox, journal, replay]

type Call = object
  job, image, profile, opts, cmd: string

type Out = object
  status, message, value: string
  calls: seq[Call]

proc runScript(body: string; action = "build"; buildExit = 0): Out =
  ## `action` is what the check step says (present, retagged or build); `buildExit` the code of the build
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
    if "ACTION=" in cmd and "$CICD_OUTPUT" in cmd: return some("0\nACTION=" & action & "\n")        # the check step
    if "/kaniko/executor" in cmd: return some($buildExit & "\n")
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
