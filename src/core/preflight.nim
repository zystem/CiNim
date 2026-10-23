## The check of a script before a run exists (PIP-016): the API hands the script and the launch parameters to a conductor of the organisation, which runs it once against a stub host, in a
## process of its own (user Lua never runs in the core, SEC-007), and says what it found: a syntax error, a forbidden global, a parameter the script's declarations refuse, a limit the pass
## proves (more than 200 steps, an id used twice), and the parameters a run would have. A finding is *certain* when no answer of a step can be its cause: it came before the first step, or
## it is one of those limits. The core refuses a run on a certain finding and lets it through on anything else, because the run's own pass is the authority: the check is a courtesy to
## the author, not a gate. It is skipped when there is nobody to ask (the organisation has no conductor connected: the first run starts one), when the conductor is busy or slow, or when the hub is down.
import std/[json, strutils, times, atomics]
import ../common/[rqlite, scriptsource]
import scheduler, checkmail, streamhub, schema

const
  checkWaitSeconds = 8.0
  fetchWaitSeconds = 75.0         ## a script read from a repository: the conductor fetches first (its own limit is 70 s)
  maxFetchWaits = 6               ## API threads that may be waiting for a fetch at once; the rest are told to come back (the same threads answer /healthz)

type Answer* = object
  ran*: bool                       ## a conductor ran the script
  skipped*: string                 ## when not: no_conductor, busy, timeout or unavailable
  code*, message*, paramsJson*: string
  certain*: bool
  steps*: int
  script*, commit*: string         ## the text read from the repository and the SHA of the commit it was read at (only when a repository was asked for)

proc checkScript*(ns, script: string; given: seq[(string, string)]; apiVersion: int; waitSeconds = checkWaitSeconds): Answer =
  var req = CheckScript(check_id: newId(), script: script, api_version: uint32(apiVersion))
  for (k, v) in given: req.given.add GivenEntry(key: k, value: v)
  if not requestCheck(ns, encodeCheckScript(req)):
    return Answer(skipped: "unavailable")
  let got = checkmail.take(req.check_id, waitSeconds)
  if not got.found: return Answer(skipped: "timeout")
  let res = try: decodeCheckResult(got.answer) except CatchableError: return Answer(skipped: "unavailable")
  if res.code in ["no_conductor", "busy", "timeout"]: return Answer(skipped: res.code)
  Answer(ran: true, code: res.code, message: res.message, paramsJson: res.params, certain: res.certain, steps: int(res.steps))

proc sourceIn*(j: JsonNode; repository: string): tuple[ok: bool, source: Source, error: string] =
  ## D-68: the `commit` and `path` of a request (a run, a check) in the repository of its project, as text and in the forms git can be given; `commit` is a SHA, a branch or a tag ("" is the head
  ## of the repository), `path` is where the script is (".ci/pipeline.lua" when empty). The repository is the project's, not the request's.
  for k in ["commit", "path"]:
    if j.hasKey(k) and j[k].kind != JString: return (false, Source(), k & " must be text")
  result.source = Source(repository: repository, commit: j{"commit"}.getStr, path: j{"path"}.getStr)
  if result.source.commit.len > 0 and not validRef(result.source.commit): return (false, Source(), "commit is a SHA, a branch or a tag name")
  if result.source.path.len > 0 and not validPath(result.source.path): return (false, Source(), "path is a relative path inside the repository")
  result.ok = true

var fetchWaiting: Atomic[int]

proc checkSource*(ns: string; source: Source; given: seq[(string, string)]; apiVersion: int): Answer =
  ## D-63: the script is in a repository. A conductor of the organisation reads it, checks it, and answers with its text and the SHA of the commit. `skipped` is `busy` when too many API
  ## threads wait for fetches already, and `no_conductor` / `timeout` / `unavailable` as for a check: with no script the run cannot be made, so the caller refuses it.
  if fetchWaiting.fetchAdd(1) >= maxFetchWaits:
    discard fetchWaiting.fetchSub(1)
    return Answer(skipped: "busy")
  defer: discard fetchWaiting.fetchSub(1)
  var req = CheckScript(check_id: newId(), repository: source.repository, commit: source.commit, path: source.path, api_version: uint32(apiVersion))
  for (k, v) in given: req.given.add GivenEntry(key: k, value: v)
  if not requestCheck(ns, encodeCheckScript(req)):
    return Answer(skipped: "unavailable")
  let got = checkmail.take(req.check_id, fetchWaitSeconds)
  if not got.found: return Answer(skipped: "timeout")
  let res = try: decodeCheckResult(got.answer) except CatchableError: return Answer(skipped: "unavailable")
  if res.code in ["no_conductor", "busy", "timeout"]: return Answer(skipped: res.code)
  Answer(ran: true, code: res.code, message: res.message, paramsJson: res.params, certain: res.certain, steps: int(res.steps), script: res.script, commit: res.resolved_commit)

type ResolvedRef* = object
  ok*: bool
  commit*: string
  code*, message*: string       ## when not ok: `no_conductor`, `busy`, `timeout`, `unavailable`, or what the conductor's git said (`fetch_failed`, `invalid_source`)

proc resolveCommit*(ns, repository, ref0: string): ResolvedRef =
  ## D-76: which commit `ref0` is at, asked of a conductor of the organisation (`git ls-remote`, nothing fetched). Shares the limit of the readings from repositories (`busy`).
  if fetchWaiting.fetchAdd(1) >= maxFetchWaits:
    discard fetchWaiting.fetchSub(1)
    return ResolvedRef(code: "busy", message: "too many repositories are being read at the moment")
  defer: discard fetchWaiting.fetchSub(1)
  let req = CheckScript(check_id: newId(), repository: repository, commit: ref0, resolve_only: true)
  if not requestCheck(ns, encodeCheckScript(req)):
    return ResolvedRef(code: "unavailable", message: "the hub of the conductors does not answer")
  let got = checkmail.take(req.check_id, fetchWaitSeconds)
  if not got.found: return ResolvedRef(code: "timeout", message: "no conductor answered in " & $fetchWaitSeconds & " s")
  let res = try: decodeCheckResult(got.answer) except CatchableError: return ResolvedRef(code: "unavailable", message: "the answer of the conductor cannot be read")
  if res.code.len > 0: return ResolvedRef(code: res.code, message: res.message)
  if res.resolved_commit.len == 0: return ResolvedRef(code: "unavailable", message: "the conductor is of a version that cannot read a ref (it is being replaced)")
  ResolvedRef(ok: true, commit: res.resolved_commit)

func fetchProblem*(a: Answer): tuple[status: int, code, message: string] =
  ## what to tell the caller when the script could not be had: (0, ...) when it was
  if a.ran and a.script.len > 0: return (0, "", "")
  if not a.ran:
    case a.skipped
    of "busy": return (429, "busy", "too many scripts are being read from repositories at the moment; try again in a few seconds")
    of "no_conductor": return (409, "no_conductor", "the organisation has no conductor connected to read the script from the repository; one is started when it has work, try again in a minute")
    else: return (503, "script_unavailable", "the script could not be read from the repository: " & a.skipped)
  case a.code
  of "": (503, "script_unavailable", "the conductor answered without a script: it is of a version that cannot read a repository (it is being replaced); try again in a minute")
  of "invalid_source", "script_missing", "script_too_large": (400, a.code, a.message)
  of "fetch_failed", "git_unavailable": (502, a.code, a.message)
  else: (400, a.code, a.message)          # the script was read and the check found something certain in it

func problemOf*(a: Answer): string =
  ## the 400 answer's words when the check found something certain, else ""
  if a.ran and a.code.len > 0 and a.certain: a.message else: ""

proc view*(a: Answer): JsonNode =
  ## what `POST /api/v1/pipelines:check` answers
  result = newJObject()
  result["checked"] = %a.ran
  if not a.ran:
    result["skipped"] = %a.skipped
    return
  result["ok"] = %(a.code.len == 0)
  result["steps"] = %a.steps
  if a.code.len > 0:
    result["failure"] = %*{"code": a.code, "message": a.message, "certain": a.certain}
  if a.paramsJson.len > 0:
    try: result["params"] = parseJson(a.paramsJson)
    except JsonParsingError: discard
  if a.commit.len > 0: result["commit"] = %a.commit
