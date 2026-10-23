## The ids that an author gives and the names of pipelines (D-67, D-68): Crockford base32 in lowercase, `0123456789abcdefghjkmnpqrstvwxyz` (the digits and the letters but `i l o u`),
## of a **fixed width**: a job's id is 2 characters, a step's 4, the `NN` of a pipeline's file `NN.lua` 2. A shorter id is padded with leading zeros (`a` is `0a`, `ab` is `00ab`),
## upper case is read as lower case, `i l o u` and any other character are refused (not silently taken for `1` and `0`), and so `a`, `A` and `0a` are one id. The strings of one
## width sort in the order of their numbers. The Lua side of the same rules is `b32f` and `check_id` in `src/executor/bootstrap.lua`.

import std/[strutils, algorithm, tables]

const
  crockfordDigits* = "0123456789abcdefghjkmnpqrstvwxyz"
  jobIdWidth* = 2
  stepIdWidth* = 4
  pipelineIdWidth* = 2

type
  IdCheck* = object
    ok*: bool
    message*: string                 ## why not, when not ok

  Pipelines* = object
    ok*: bool
    pipelines*: seq[string]          ## the normalized ids, sorted
    message*: string

func digitOf(c: char): int =
  crockfordDigits.find(toLowerAscii(c))

func checkId*(s: string; width: int): IdCheck =
  ## `s` is a valid id of at most `width` characters, or the reason why it is not
  if s.len == 0: return IdCheck(message: "an id is not empty")
  if s.len > width: return IdCheck(message: "an id is at most " & $width & " characters of the alphabet, got " & $s.len & " (" & s & ")")
  for c in s:
    if digitOf(c) < 0:
      let l = toLowerAscii(c)
      if l in {'i', 'l', 'o', 'u'}:
        return IdCheck(message: "the character '" & $l & "' is not in the alphabet of ids (i, l, o and u are left out: write 1 for i and l, 0 for o)")
      return IdCheck(message: "the character '" & $c & "' is not in the alphabet of ids (digits and the letters but i, l, o, u)")
  IdCheck(ok: true)

func normalizeId*(s: string; width: int): string =
  ## lowercase and padded with zeros in front to `width`; ValueError for what `checkId` refuses
  let r = checkId(s, width)
  if not r.ok: raise newException(ValueError, r.message)
  repeat('0', width - s.len) & toLowerAscii(s)

func idOfNumber*(n, width: int): string =
  ## the id of the number `n`, as wide as `width` (0 is `00`, 1023 is `zz` for 2)
  var top = 1
  for _ in 1 .. width: top *= 32
  if n < 0 or n >= top: raise newException(ValueError, "the number " & $n & " does not fit " & $width & " characters")
  result = newString(width)
  var v = n
  for i in countdown(width - 1, 0):
    result[i] = crockfordDigits[v and 31]
    v = v shr 5

func jobIdOfStep*(step: int): string =
  ## the id of the job a step number belongs to (`step` is `job * 2^20 + step id`, D-67); "" for a number that has none
  if step < 0: return ""
  try: idOfNumber(step shr 20, jobIdWidth) except ValueError: ""

func stepIdOfStep*(step: int): string =
  ## the id of the step within its job; "" for a negative number
  if step < 0: return ""
  idOfNumber(step and 0xFFFFF, stepIdWidth)

func stepLabel*(jobId, stepId: string): string =
  ## how a person reads the two together: `0v/0004`; "" when either is missing
  if jobId.len == 0 or stepId.len == 0: "" else: jobId & "/" & stepId

func numberOfId*(s: string): int =
  ## what `idOfNumber` was given; -1 for what is not an id
  for c in s:
    let d = digitOf(c)
    if d < 0: return -1
    result = result * 32 + d

func pipelineOfFile*(name: string): string =
  ## `a.lua` is the pipeline `0a`; "" for a name that is not one (`pipeline.lua`, `000.lua`, `i.lua`, `00.txt`)
  if not name.endsWith(".lua"): return ""
  let stem = name[0 ..< name.len - 4]
  if stem.len == 0 or not checkId(stem, pipelineIdWidth).ok: return ""
  normalizeId(stem, pipelineIdWidth)

func findPipelines*(paths: seq[string]): Pipelines =
  ## the pipelines of a repository from the paths of its files: `.ci/NN.lua`. Two files of one pipeline (`0.lua` and `00.lua`) are an error that names both.
  result.ok = true
  var seen = initTable[string, string]()
  for p in paths:
    if not p.startsWith(".ci/"): continue
    let rest = p[4 .. ^1]
    if '/' in rest: continue
    let id = pipelineOfFile(rest)
    if id.len == 0: continue
    if id in seen:
      return Pipelines(ok: false, message: "the files " & seen[id] & " and " & p & " are one pipeline (" & id & "): keep one of them")
    seen[id] = p
  for id in seen.keys: result.pipelines.add id
  result.pipelines.sort()
