## STO-002 / PIP-018: `ci.job{ workspace = "isolated" }` gives the job a volume of its own (the steps of the job share it, no other job sees it), `Job:sh{ image = ... }` runs one step of a job
## in another image, and the cache steps of an isolated job are isolated too. Pure: the options reach the core as the canonical JSON of the step; a fake host reads it.
import std/[unittest, strutils, sequtils, options, json]
import executor/[sandbox, journal, replay]

type Seen = object
  status: ExecStatus
  message: string
  calls: seq[tuple[image, opts, cmd: string]]

proc run(body: string): Seen =
  var sb = newSandbox()
  var j: Journal
  var r: Seen
  let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
    if kind != "job_sh": return some("")
    let f = payload.split('\t', 4)
    r.calls.add (f[1], f[3], f[4])
    some("0\n")
  let e = replay.execute(sb, j, "return ci.pipeline({ main = function(run)\n" & body & "\nend })", host)
  r.status = e.status
  r.message = e.message
  r

suite "D-63 shm: a /dev/shm of the job's own":
  test "shm is in the options of every step of the job, between the secrets and the timeout in the canonical order":
    let r = run("""ci.single['01']{ image = "a", shm = "2Gi", timeout = 90, body = function(j) j:run(step.sh['1']{ cmd = "one" })  end }""")
    check r.calls[0].opts == """{"shm":"2Gi","timeout":90}"""
  test "a size is Mi or Gi, from 64Mi to 8Gi; anything else is refused before any step":
    for bad in ["16Mi", "9Gi", "2G", "lots", "-1Gi", "2.5Gi"]:
      let r = run("ci.single['02']{ image = \"a\", shm = \"" & bad & "\", body = function(j) j:run(step.sh['1']{ cmd = \"x\" })  end }")
      check r.status == esFailed and "shm" in r.message and r.calls.len == 0
    check run("""ci.single['03']{ image = "a", shm = 2048, body = function(j) j:run(step.sh['1']{ cmd = "x" })  end }""").status == esFailed

suite "STO-002 the volume of a job":
  test "a job is shared by default: its steps carry no workspace option":
    let r = run("""ci.single['04']{ image = "a", body = function(j) j:run(step.sh['1']{ cmd = "x" })  end }""")
    check r.calls.len == 1 and "workspace" notin r.calls[0].opts
  test "workspace = 'isolated' is in the options of every step of the job, 'shared' is the default and says nothing":
    let r = run("""
      ci.single['05']{ image = "a", workspace = "isolated", body = function(j) j:run(step.sh['1']{ cmd = "one" }); j:run(step.sh['2']{ cmd = "two" })  end }
      ci.single['06']{ image = "a", workspace = "shared", body = function(j) j:run(step.sh['1']{ cmd = "three" })  end }""")
    check r.calls.len == 3
    check r.calls[0].opts == """{"workspace":"isolated"}""" and r.calls[1].opts == r.calls[0].opts
    check "workspace" notin r.calls[2].opts
  test "it sorts with the other options (the canonical JSON has its keys in order)":
    let r = run("""ci.single['07']{ image = "a", workspace = "isolated", timeout = 90, env = {B = "1"}, body = function(j) j:run(step.sh['1']{ cmd = "x" })  end }""")
    check r.calls[0].opts == """{"env":{"B":"1"},"timeout":90,"workspace":"isolated"}"""
  test "the cache steps of an isolated job are in its volume, which is where the cache is restored to":
    let r = run("""ci.single['08']{ image = "a", workspace = "isolated", body = function(j)
      j:run(step.cache_restore['1']{ keys = {"k-1", "k-"} })
      j:run(step.cache_save['2']{ key = "k-2", paths = {"repo.git"} })
     end }""")
    check r.calls.len == 2
    for c in r.calls: check """"workspace":"isolated"""" in c.opts
  test "anything but 'shared' and 'isolated' is refused":
    for bad in ["'private'", "true", "1"]:
      let r = run("ci.single['01']{ image = 'a', workspace = " & bad & ", body = function(j) end }")
      check r.status == esFailed and "workspace" in r.message
  test "a step may run in another image than its job's":
    let r = run("""ci.single['09']{ image = "git", body = function(j)
      j:run(step.sh['1']{ cmd = "clone" })
      j:run(step.sh['2']{ cmd = "build", image = "kaniko" })
     end }""")
    check r.calls.mapIt(it.image) == @["git", "kaniko"]
  test "the image of a step is a non-empty string":
    for bad in ["1", "''", "{}"]:
      let r = run("ci.single['01']{ image = 'a', body = function(j) j:run(step.sh['1']{ cmd = 'x', image = " & bad & " }) end }")
      check r.status == esFailed and "image" in r.message

suite "STO-003 r.outputs of a step":
  proc outputsOf(answer: string; body: string): string =
    var sb = newSandbox()
    var j: Journal
    let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] = some(if kind == "job_sh": answer else: "")
    let e = replay.execute(sb, j, "return ci.pipeline({ main = function(run)\n" & body & "\nend })", host)
    if e.status == esDone: e.value else: "FAILED: " & e.message
  test "the text after the exit code is the step's outputs: name=value lines, as a table":
    check outputsOf("0\nSHA=ab12\nTAG=x y\n", """local r; ci.single['0a']{ image = "a", body = function(j) r = j:run(step.sh['1']{ cmd = "x" })  end }; return r.outputs.SHA .. "|" .. r.outputs.TAG""") == "ab12|x y"
  test "a line that is not a pair is left out, the value may hold =, an empty value is an empty string":
    check outputsOf("0\nA=b=c\nnot a pair\nE=\n", """local r; ci.single['0b']{ image = "a", body = function(j) r = j:run(step.sh['1']{ cmd = "x" })  end }; return r.outputs.A .. "|" .. r.outputs.E .. "|" .. tostring(r.outputs["not a pair"])""") == "b=c||nil"
  test "none: an empty table":
    check outputsOf("0\n", """local r; ci.single['0c']{ image = "a", body = function(j) r = j:run(step.sh['1']{ cmd = "x" })  end }; local n = 0; for _ in pairs(r.outputs) do n = n + 1 end; return tostring(n)""") == "0"
