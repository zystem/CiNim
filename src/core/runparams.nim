## Launch parameters (PIP-012, VAR-002, VAR-003): the values given when a run is created, stored with it as one JSON object of text values.
##
## What the API accepts is checked here (the names, the sizes, plain values only); what the values must be (a number, one of the choices, required or
## not) is declared by the script and checked by the executor, in the sandbox, from the script's own `params = {...}` (src/executor/bootstrap.lua).
## The executor then reports the complete set, defaults included, as the host call `params`; core keeps that as the run's parameters, and gives it
## to every step of the run as ordinary environment variables (the job controller puts them into the Pod's `env`). Secrets are not parameters:
## a step asks for those by name (`secrets = {...}`, 6.7).
import std/[json, strutils, algorithm]
import ../common/[rqlite, envname]

const
  maxParams* = 64
  maxValueLen* = 1024
  maxTotal* = 4096          ## VAR-002: `runs.params`, at most 4 KiB

func asText*(v: JsonNode): tuple[ok: bool, text: string] =
  ## a launch parameter arrives as a JSON string, number or boolean; it is kept as text, the script's declaration types it
  case v.kind
  of JString: (true, v.getStr)
  of JInt: (true, $v.getBiggestInt)
  of JFloat: (true, $v.getFloat)
  of JBool: (true, if v.getBool: "true" else: "false")
  else: (false, "")

func checkParams*(j: JsonNode): tuple[error: string, pairs: seq[(string, string)]] =
  ## "" and the sorted pairs if the object may be a run's parameters, else the reason (for the 400 answer); nil is "no parameters"
  if j == nil or j.kind == JNull: return
  if j.kind != JObject: return ("params must be an object of NAME: value", @[])
  if j.len > maxParams: return ("at most " & $maxParams & " parameters", @[])
  var total = 0
  for k, v in j:
    if not validEnvName(k, 64): return ("the parameter name '" & k & "' is not a name of an environment variable (capital letters, digits and _, not starting with a digit, at most 64 characters)", @[])
    if deniedEnvName(k): return ("the parameter name " & k & " cannot be set in a step's environment (STO-004)", @[])
    let t = asText(v)
    if not t.ok: return ("the parameter " & k & " must be a string, a number or a boolean", @[])
    if t.text.len > maxValueLen: return ("the parameter " & k & " is longer than " & $maxValueLen & " bytes", @[])
    for ch in t.text:
      if ch < ' ' or ch == '\x7f': return ("the parameter " & k & " has a control character", @[])
    total += k.len + t.text.len
    result.pairs.add (k, t.text)
  if total > maxTotal: return ("the parameters are longer than " & $maxTotal & " bytes in all", @[])
  result.pairs.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))

func toJson*(pairs: seq[(string, string)]): string =
  ## the stored form: an object of text values, keys sorted
  var o = newJObject()
  for (k, v) in pairs: o[k] = %v
  $o

proc fromJson*(s: string): seq[(string, string)] =
  ## the pairs of a stored value; damaged or empty gives none
  if s.len == 0: return
  try:
    let j = parseJson(s)
    if j.kind == JObject:
      for k, v in j:
        if v.kind == JString and validEnvName(k, 64) and not deniedEnvName(k): result.add (k, v.getStr)
  except JsonParsingError: discard

proc runParams*(c: var RqClient; runId: string): seq[(string, string)] =
  let r = c.query(%*[["SELECT params FROM runs WHERE id = ?", runId]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: fromJson(vals[0][0].getStr) else: @[]

proc storeEffectiveParams*(c: var RqClient; runId, json: string) =
  ## the executor's complete set replaces the values given at creation
  discard c.execute(%*[["UPDATE runs SET params = ? WHERE id = ?", json, runId]])

proc checkEffective*(json: string): string =
  ## what the executor reported, which core does not take on trust: "" if it is a set of parameters, else the reason
  if json.len > maxTotal * 2: return "the parameters are too long"
  try:
    let j = parseJson(json)
    if j.kind != JObject: return "the parameters must be an object"
    let ch = checkParams(j)
    return ch.error
  except JsonParsingError:
    return "the parameters are not JSON"
