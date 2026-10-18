## The environment a script gives to its steps (VAR-004): `env` of the pipeline and of the job (together `env` in the step's options, above the launch parameters) and the
## `env` of one step (`step_env`, above what the steps write to $CICD_ENV). The script says it in the options of the step (bootstrap.lua: `norm_env`); the core checks the
## names against the deny-list of STO-004 when it takes the step, puts the job's into the environment of the Pod, and the shim applies the step's after the env file.
## Pure, shared by the core and the shim.
import std/[json, strutils, algorithm, sets]
import envname

const
  maxEnvCount* = 100
  maxEnvValue* = 8192
  maxEnvTotal* = 65536

proc envOf*(optsJson, key: string): seq[(string, string)] =
  ## the pairs under `key` ("env" or "step_env") of a step's options, sorted by name; a damaged or missing one is none. A name that is not valid or is denied is left out
  ## (the core refused such a step already; this keeps a hand-made one from setting what a step may not).
  if optsJson.len == 0: return
  try:
    let o = parseJson(optsJson){key}
    if o == nil or o.kind != JObject: return
    for k, v in o.pairs:
      if v.kind == JString and validEnvName(k, 64) and not deniedEnvName(k): result.add (k, v.getStr)
    result.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  except CatchableError: discard

proc isolatedWorkspace*(optsJson: string): bool =
  ## the job of the step asked for a volume of its own (`workspace = "isolated"`, STO-002)
  if optsJson.len == 0: return
  try:
    let j = parseJson(optsJson)
    j.kind == JObject and j{"workspace"} != nil and j{"workspace"}.kind == JString and j{"workspace"}.getStr == "isolated"
  except CatchableError: false

proc shmSize*(optsJson: string): string =
  ## the size of the /dev/shm the job asked for (`shm = "2Gi"`), or "" (the 64Mi of a Pod); the Lua sandbox has checked it, and it is looked at again before it goes into a Pod
  if optsJson.len == 0: return
  try:
    let j = parseJson(optsJson)
    if j.kind != JObject or j{"shm"} == nil or j{"shm"}.kind != JString: return
    let v = j{"shm"}.getStr
    if v.len >= 3 and v.len <= 6 and v[^2 .. ^1] in ["Mi", "Gi"] and v[0 ..< v.len - 2].allCharsInSet({'0' .. '9'}): v else: ""
  except CatchableError: ""

proc checkEnv*(optsJson: string): string =
  ## "" if the options' environments may be given to a step, else why not (the core's answer to the script)
  if optsJson.len == 0: return
  var j: JsonNode
  try: j = parseJson(optsJson)
  except CatchableError: return ""
  for key in ["env", "step_env"]:
    let o = j{key}
    if o == nil: continue
    if o.kind != JObject: return key & " is a table of names and values"
    if o.len > maxEnvCount: return key & " has more than " & $maxEnvCount & " variables"
    var total = 0
    for k, v in o.pairs:
      if not validEnvName(k, 64): return key & ": " & k & " is not a name of a variable"
      if deniedEnvName(k): return key & ": " & k & " cannot be set in a step's environment (STO-004)"
      if v.kind != JString: return key & ": the value of " & k & " is a text"
      if v.getStr.len > maxEnvValue: return key & ": the value of " & k & " is longer than " & $maxEnvValue & " bytes"
      total += v.getStr.len
    if total > maxEnvTotal: return key & ": the values are more than " & $maxEnvTotal & " bytes in all"
