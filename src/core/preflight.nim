## The check of a script before a run exists (PIP-016): the API hands the script and the launch parameters to a conductor of the organisation, which runs it once against a stub host, in a
## process of its own (user Lua never runs in the core, SEC-007), and says what it found: a syntax error, a forbidden global, a parameter the script's declarations refuse, a limit the pass
## proves (more than 200 steps, an id used twice), and the parameters a run would have. A finding is *certain* when no answer of a step can be its cause: it came before the first step, or
## it is one of those limits. The core refuses a run on a certain finding and lets it through on anything else, because the run's own pass is the authority: the check is a courtesy to
## the author, not a gate. It is skipped when there is nobody to ask (the organisation has no conductor connected: the first run starts one), when the conductor is busy or slow, or when the hub is down.
import std/[json, strutils, times]
import ../common/rqlite
import scheduler, checkmail, streamhub, schema

const checkWaitSeconds = 8.0

type Answer* = object
  ran*: bool                       ## a conductor ran the script
  skipped*: string                 ## when not: no_conductor, busy, timeout or unavailable
  code*, message*, paramsJson*: string
  certain*: bool
  steps*: int

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
