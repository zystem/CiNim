## The table of step numbers (docs/parallel.md section 3): before a run is led, the script is run once against a stub host and the places where steps are made are
## recorded; the places are numbered in the order in which they were first met, a place that made one step gets one number and a place that made several gets a
## block with room to spare. A step finds its number here when it is made. Pure but for the pass itself, which runs the script in a sandbox like any other.
import std/[options, strutils, json, tables]
import sandbox, journal, replay

const
  maxSteps* = 200
  overflowBase* = 100_000            ## numbers of the steps the pass did not foresee: 100 000, 100 001 ...

type
  Block* = object
    ## the numbers of one place in the script (one line): `size` numbers from `start`, of which `observed` were used by the pass
    line*, start*, size*, observed*: int

  StepTable* = object
    blocks*: seq[Block]
    overflowNext*: int
    overflowGiven: seq[(int, int, int)]       ## (line, instance, number) of what was given from the overflow, so that asking again gives the same

  TableResult* = object
    ok*: bool                  ## false: the run is refused (`code` says why); true: the table is usable, `partial` when the pass did not reach the end of the script
    partial*: bool
    code*, message*: string
    steps*: int
    table*: StepTable

func blockSize*(n: int): int =
  ## a place that made one step needs one number; one that made several gets ceil((n+1)/10)*10, at most 200, so that a loop that goes on longer than the pass saw has room
  if n <= 1: 1 else: min(maxSteps, ((n + 1 + 9) div 10) * 10)

func assignBlocks*(lines: seq[int]): StepTable =
  ## `lines`: the line of every step the pass made, in the order in which they were made
  var order: seq[int]                      # the lines in the order in which they were first met
  var count: seq[int]
  for l in lines:
    var found = -1
    for i, o in order:
      if o == l:
        found = i
        break
    if found < 0:
      order.add l
      count.add 1
    else:
      inc count[found]
  var next = 0
  for i, l in order:
    let size = blockSize(count[i])
    result.blocks.add Block(line: l, start: next, size: size, observed: count[i])
    next += size
  result.overflowNext = overflowBase

proc numberOf*(t: var StepTable; line, instance: int): int =
  ## The number of the `instance`-th step (from 0) made on `line`: inside the block of that place if it has room, else the next number of the overflow (and the same
  ## one again if asked again).
  for b in t.blocks:
    if b.line == line and instance >= 0 and instance < b.size: return b.start + instance
  for (l, i, n) in t.overflowGiven:
    if l == line and i == instance: return n
  result = t.overflowNext
  inc t.overflowNext
  t.overflowGiven.add (line, instance, result)

proc stubHost(seq: int; kind, payload: string): Option[string] =
  ## the host of the pass: nothing is done, every step succeeds, time stands still
  case kind
  of "job_sh", "sh": some("0\n")
  of "now": some("0")
  of "random": some("0.5")
  else: some("")

proc buildTable*(script: string; params: seq[(string, string)] = @[]; apiVersion = currentApiVersion): TableResult =
  ## Run `script` once, with the launch parameters `params` completed by the script's own defaults, and make the table of what it did. A script that cannot be taken to
  ## its end (it breaks on a stub result, it loops) leaves a partial table and is not refused: the real run will find its own way. Only what the pass proves is refused:
  ## more than 200 steps (`step_limit`) and an id used twice (`duplicate_id`).
  var sb = newSandbox(apiVersion = apiVersion)
  var j: Journal
  var lines: seq[int]
  let r = replay.execute(sb, j, script, stubHost, runId = "table", params = params,
                         onSite = proc (seq: int; kind: string; line: int) = (if kind == "job_sh": lines.add line))
  result.table = assignBlocks(lines)
  result.steps = lines.len
  result.ok = true
  if r.status == esFailed:
    result.message = r.message
    if r.code in ["step_limit", "duplicate_id"]:
      result.ok = false
      result.code = r.code
    else:
      result.partial = true
      result.code = r.code

# ------------------------------------------------------------------ the table as it is stored, and the numbers of a run that goes on

const tableRules = 1                 ## the version of the rules that make a table; a table of other rules is not read

proc encodeTable*(t: StepTable): string =
  ## the text the core keeps with the run (`runs.step_table`): a run that is led again, by whichever executor, uses this table and not a new one
  var b = newJArray()
  for x in t.blocks: b.add %[x.line, x.start, x.size, x.observed]
  $(%*{"v": tableRules, "b": b})

proc decodeTable*(s: string): Option[StepTable] =
  if s.len == 0: return none(StepTable)
  try:
    let j = parseJson(s)
    if j.kind != JObject or j{"v"}.getInt != tableRules or j{"b"}.kind != JArray: return none(StepTable)
    var t = StepTable(overflowNext: overflowBase)
    for x in j["b"]:
      if x.kind != JArray or x.len != 4: return none(StepTable)
      t.blocks.add Block(line: x[0].getInt, start: x[1].getInt, size: x[2].getInt, observed: x[3].getInt)
    some(t)
  except CatchableError:
    none(StepTable)

type Numbering* = object
  ## the numbers of the steps of one execution of a script: told where each host call is made, it says the number of the step
  table*: StepTable
  counts: Table[int, int]
  lastNo*: int                       ## the number of the step made last, -1 before the first

proc newNumbering*(t: StepTable): Numbering = Numbering(table: t, lastNo: -1)

proc onSite*(n: var Numbering; kind: string; line: int) =
  ## to be called for every host call before it is dispatched, in the order of the calls, answered from the journal or not (`replay.execute`'s `onSite`)
  if kind != "job_sh": return
  let k = n.counts.getOrDefault(line, 0)
  n.counts[line] = k + 1
  n.lastNo = n.table.numberOf(line, k)

type Prepared* = object
  numbering*: Numbering
  toSend*: string                    ## the table to send to the core before the first call ("" when the core already has it)
  refused*: bool                     ## the pass proved the script wrong (more than 200 steps, a repeated id): the run ends with `code` and `message`
  code*, message*: string

proc prepare*(script: string; params: seq[(string, string)]; apiVersion: int; stored: string): Prepared =
  ## What an executor does when it has been given a run: use the table the core has kept with it, and when there is none make it by a pass of the script.
  let known = decodeTable(stored)
  if known.isSome:
    return Prepared(numbering: newNumbering(known.get))
  let r = buildTable(script, params, apiVersion)
  if not r.ok:
    return Prepared(refused: true, code: r.code, message: r.message)
  Prepared(numbering: newNumbering(r.table), toSend: encodeTable(r.table))
