## The pass of a script against a stub host (docs/parallel.md section 3.4, D-67): before a run is led, and before it exists (PIP-016), the script is run once in the sandbox with nothing
## made anywhere, to find what the script itself proves: more than 1000 steps (`step_limit`) and an id used twice (`duplicate_id`). It no longer numbers the steps: a step's number is made of
## the id of its job and its own (`src/executor/bootstrap.lua`, `src/common/crockford.nim`), the same in every execution, so no table of numbers is kept with a run.
import std/[options, strutils, json, tables, sequtils]
import sandbox, journal, replay

const
  maxSteps* = 1000

proc stubHost(seq: int; kind, payload: string): Option[string] =
  ## the host of the pass: nothing is done, every step succeeds, time stands still
  case kind
  of "job_sh": some("0\n")
  of "now": some("0")
  of "random": some("0.5")
  else: some("")

type
  PassResult* = object
    ok*: bool                  ## false: the run is refused (`code` says why); true: nothing is proved against it, `partial` when the pass did not reach the end of the script
    partial*: bool
    code*, message*: string
    steps*: int

proc runPass*(script: string; params: seq[(string, string)] = @[]; apiVersion = currentApiVersion): PassResult =
  ## Run `script` once, with the launch parameters `params` completed by the script's own defaults. A script that cannot be taken to its end (it breaks on a stub result, it loops) is not
  ## refused: the real run will find its own way. Only what the pass proves is refused: more than 1000 steps (`step_limit`) and an id used twice (`duplicate_id`).
  var sb = newSandbox(apiVersion = apiVersion)
  var j: Journal
  var steps = 0
  let r = replay.execute(sb, j, script, stubHost, runId = "table", params = params,
                         onSite = proc (seq: int; kind: string; line: int) = (if kind == "job_sh": inc steps))
  result.steps = steps
  result.ok = true
  if r.status == esFailed:
    result.message = r.message
    if r.code in ["step_limit", "duplicate_id"]:
      result.ok = false
      result.code = r.code
    else:
      result.partial = true
      result.code = r.code

# ------------------------------------------------------------------ the check before a run exists (PIP-016)

type Preflight* = object
  ## what a pass of the script against the stub host found. `code` "" is nothing found. `certain`: the finding is the script's and the parameters' alone - it came before the first
  ## step, so no answer of a step can be the cause - or it is a limit the pass proves (`step_limit`, `duplicate_id`); an uncertain one (the script broke after a stub answer) is only a hint
  code*, message*, paramsJson*: string
  certain*: bool
  steps*: int

proc preflight*(script: string; params: seq[(string, string)] = @[]; apiVersion = currentApiVersion): Preflight =
  ## Run `script` once against the stub host with the launch parameters `params`: the metadata phase (the declarations of the parameters and their checking, the options of the pipeline)
  ## and `main` as far as the stub takes it. Nothing is made anywhere. The same pass `runPass` is.
  var sb = newSandbox(apiVersion = apiVersion)
  var j: Journal
  var calls = 0                                 # host calls other than the one that reports the parameters: while there are none, the script has not yet been told anything by a step
  var paramsJson = ""
  var steps = 0
  proc host(seq: int; kind, payload: string): Option[string] =
    if kind == "params":
      paramsJson = payload
      return some("")
    inc calls
    stubHost(seq, kind, payload)
  let r = replay.execute(sb, j, script, host, runId = "check", params = params,
                         onSite = proc (seq: int; kind: string; line: int) = (if kind == "job_sh": inc steps))
  result.steps = steps
  result.paramsJson = paramsJson
  if r.status == esFailed:
    result.code = r.code
    result.message = r.message
    result.certain = calls == 0 or r.code in ["step_limit", "duplicate_id"]
