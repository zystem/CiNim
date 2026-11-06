## STO-002, PRJ-004: `j:checkout()` puts the source of the run's commit in `src` of the job's workspace, and `run.source.short` is the short commit. The steps it makes (the mirror of the repository from
## the cache of the organisation, a clone out of it, the mirror saved when it grew) are checked against a host that answers them by what they are. Pure: nothing is made anywhere.
import std/[unittest, options, strutils, sequtils, json]
import executor/[sandbox, journal, replay]

type Call = object
  job, image, profile, opts, cmd: string

type Out = object
  status, message, value: string
  calls: seq[Call]
  nows: int                                                 ## how many times the host was asked for the time

proc runScript(body: string; params: seq[(string, string)] = @[]; fetched = "yes"; hit = false; exitCode = 0; clock = "1793921212"): Out =
  ## the pipeline `body` is the text of `main`; the host answers a cache restore (a hit or a miss) and the checkout step (the commit it checked out, and whether the mirror grew)
  var res = Out()
  proc host(seq: int; kind, payload: string): Option[string] =
    if kind == "now":
      inc res.nows
      return some(clock)
    if kind != "job_sh": return some("")
    let parts = payload.split('\t')
    let cmd = parts[4 .. ^1].join("\t")
    res.calls.add Call(job: parts[0], image: parts[1], profile: parts[2], opts: parts[3], cmd: cmd)
    if cmd == "true":                                        # a cache step: a restore says the key it restored
      return some("0\n" & (if "\"mode\":\"restore\"" in parts[3] and hit: "git-hit" else: ""))
    if "git clone" in cmd:
      return some($exitCode & "\nSHA=" & "a".repeat(40) & "\nFETCHED=" & fetched & "\n")
    some("0\n")
  var sb = newSandbox()
  var j: Journal
  let script = "return ci.pipeline({ name = 'x', main = function(run)\n" & body & "\nend })"
  let r = execute(sb, j, script, host, runId = "co", params = params)
  res.status = $r.status
  res.message = r.message
  res.value = r.value
  res

let source = @[("@source.repository", "https://github.com/acme/app.git"), ("@source.commit", "b".repeat(40)), ("@source.path", ".ci/pipeline.lua"), ("@source.base", "")]

const checkoutJob = """
  local out
  ci.single['a']{ image = 'alpine', profile = 'build', workspace = 'isolated', body = function(j)
    out = j:checkout(OPTS)
  end }
  return out.commit .. '|' .. out.dir
"""

proc withOpts(opts: string): string = checkoutJob.replace("OPTS", opts)

suite "STO-002 j:checkout(): the source of the run's commit in src":
  test "from run.source: the mirror of the repository is restored (the key of the commit, then the latest of the repository), the commit is cloned out of it, and the mirror is saved when it grew":
    let o = runScript(withOpts(""), source)
    check o.status == "esDone" and o.message == ""
    check o.calls.len == 3
    check "\"mode\":\"restore\"" in o.calls[0].opts and "git-github.com-acme-app-" & "b".repeat(40) in o.calls[0].opts and "git-github.com-acme-app-" in o.calls[0].opts
    check o.calls[1].image == "alpine/git:v2.47.2" and o.calls[1].profile == "build"
    check "\"REPO\":\"https://github.com/acme/app.git\"" in o.calls[1].opts and "\"REF\":\"" & "b".repeat(40) & "\"" in o.calls[1].opts
    check "git clone" in o.calls[1].cmd and "checkout.workers=0" in o.calls[1].cmd and "--shared" in o.calls[1].cmd
    check "gc.auto 0" in o.calls[1].cmd and "maintenance.auto false" in o.calls[1].cmd      # the clone borrows the objects of the mirror: nothing may tidy the mirror under it
    check "\"mode\":\"save\"" in o.calls[2].opts and "git-github.com-acme-app-" & "a".repeat(40) in o.calls[2].opts and "mirror.git" in o.calls[2].opts
    check o.value == "a".repeat(40) & "|src"                # the commit the step says it checked out
  test "a mirror that did not grow (the commit was in it already) is not saved again":
    let o = runScript(withOpts(""), source, fetched = "no", hit = true)
    check o.status == "esDone" and o.calls.len == 2
  test "the url, the ref and the image can be given, and a script that came in the request (no run.source) needs the url":
    let o = runScript(withOpts("{ url = 'https://git.example.org/team/repo.git', ref = 'release/1.2', image = 'alpine/git:2.50' }"))
    check o.status == "esDone" and o.calls[1].image == "alpine/git:2.50"
    check "\"REPO\":\"https://git.example.org/team/repo.git\"" in o.calls[1].opts and "\"REF\":\"release/1.2\"" in o.calls[1].opts
    check "git-git.example.org-team-repo-release-1.2" in o.calls[0].opts            # a ref is a key with no slash
    let none = runScript(withOpts(""))
    check none.status == "esFailed" and "no url" in none.message and none.calls.len == 0
  test "what git would take for an option, or what is not an http(s) address, is refused before any step is made":
    for opts in ["{ url = '-oProxyCommand=x' }", "{ url = 'ssh://git@host/x.git' }", "{ url = 'file:///etc' }", "{ url = 'https://h/x y' }",
                 "{ url = 'https://h/x.git', ref = '--upload-pack=x' }", "{ url = 'https://h/x.git', ref = 'a..b' }", "{ url = 'https://h/x.git', ref = '' }"]:
      let o = runScript(withOpts(opts))
      check o.status == "esFailed" and o.calls.len == 0
    check "url" in runScript(withOpts("{ url = 'ssh://git@host/x.git' }")).message
  test "submodules are updated in the same step when asked for, and not otherwise":
    let yes = runScript(withOpts("{ submodules = true }"), source)
    check yes.status == "esDone" and "\"SUBMODULES\":\"yes\"" in yes.calls[1].opts and "submodule update --init --recursive" in yes.calls[1].cmd
    check "\"SUBMODULES\":\"no\"" in runScript(withOpts(""), source).calls[1].opts
    check runScript(withOpts("{ submodules = 'yes' }"), source).status == "esFailed"
  test "depth and lfs are in the declared signature and not built: they are refused in words, not ignored":
    for opts in ["{ depth = 1 }", "{ lfs = true }"]:
      let o = runScript(withOpts(opts), source)
      check o.status == "esFailed" and "not supported yet" in o.message and o.calls.len == 0
  test "the result is the one of the step that cloned (status, code, outputs) with the commit and the directory":
    let o = runScript("""
      local r
      ci.single['a']{ image = 'alpine', profile = 'build', workspace = 'isolated', body = function(j) r = j:checkout() end }
      return r.status .. '|' .. tostring(r.code) .. '|' .. r.outputs.FETCHED .. '|' .. r.commit .. '|' .. r.dir .. '|' .. r.url""", source)
    check o.value == "ok|0|yes|" & "a".repeat(40) & "|src|https://github.com/acme/app.git"
  test "an option that is not one is refused":
    let o = runScript(withOpts("{ colour = 'red' }"), source)
    check o.status == "esFailed" and "unknown field" in o.message and o.calls.len == 0
  test "a checkout that fails fails the job, with the step that failed":
    let o = runScript(withOpts(""), source, exitCode = 128)
    check o.status == "esFailed" and "step failed with code 128" in o.message
  test "the ids of its steps are its own: a step of the job with one of them is refused with the line":
    let o = runScript("""
      ci.single['a']{ image = 'alpine', profile = 'build', workspace = 'isolated', body = function(j)
        j:run(step.sh['ck02']{ cmd = 'true' })
        j:checkout()
      end }""", source)
    check o.status == "esFailed" and "duplicate_id" in o.message and "ck02" in o.message
  test "two jobs check out on their own: each its own job key and volume":
    let o = runScript("""
      for _, id in ipairs({'a', 'b'}) do
        ci.single[id]{ image = 'alpine', profile = 'build', workspace = 'isolated', body = function(j) j:checkout() end }
      end""", source)
    check o.status == "esDone" and o.calls.len == 6 and o.calls.mapIt(it.job).deduplicate.len == 2

suite "PRJ-004 run.source.short":
  test "the short commit is its first seven characters, and empty when the run has no commit":
    check runScript("return run.source.short", source).value == "bbbbbbb"
    check runScript("return 'short=[' .. run.source.short .. ']'").value == "short=[]"

suite "PRJ-004 run.source.sha and run.tag":
  test "the sha is the full commit of the run, and empty when the run has none; it is the same as commit":
    check runScript("return run.source.sha", source).value == "b".repeat(40)
    check runScript("return run.source.sha == run.source.commit and 'same' or 'differ'", source).value == "same"
    check runScript("return 'sha=[' .. run.source.sha .. ']'").value == "sha=[]"
  test "the tag is the date (UTC) and the short commit, asked of the host once and only when the script reads it":
    let o = runScript("return run.tag .. '/' .. run.tag", source)
    check o.value == "20261105-bbbbbbb/20261105-bbbbbbb" and o.nows == 1
    check runScript("return 'none'", source).nows == 0
  test "without a commit the tag is the date alone, and the date is that of the clock the host tells (the day changes at 00:00 UTC)":
    check runScript("return run.tag").value == "20261105"
    check runScript("return run.tag", clock = "1793923199").value == "20261105"        # 2026-11-05 23:59:59
    check runScript("return run.tag", clock = "1793923200").value == "20261106"        # 2026-11-06 00:00:00
    check runScript("return run.tag", clock = "951782400").value == "20000229"         # a leap day
    check runScript("return run.tag", clock = "0").value == "19700101"
  test "run.tag is the platform's default and not a parameter: a pipeline with a TAG parameter of its own is not touched":
    let o = runScript("return run.tag .. '|' .. tostring(run.params and run.params.TAG)", source)
    check o.value == "20261105-bbbbbbb|nil"

