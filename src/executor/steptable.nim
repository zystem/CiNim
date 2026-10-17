## The table of step numbers (docs/parallel.md section 3): before a run is led, the script is run once against a stub host and the places where steps are made are
## recorded; the places are numbered in the order in which they were first met, a place that made one step gets one number and a place that made several gets a
## block with room to spare. A step finds its number here when it is made. Pure but for the pass itself, which runs the script in a sandbox like any other.
import std/[options, strutils, json, tables, sequtils]
import sandbox, journal, replay

const
  maxSteps* = 200
  overflowBase* = 100_000            ## numbers of the steps of `main` the pass did not foresee: 100 000, 100 001 ...
  branchOverflowBase* = 1_000_000_000   ## ... and those of a branch, which cannot be counted in the order of asking (that is timing): a number of the place alone, below 2 000 000 000


type
  Block* = object
    ## the numbers of one place in the script (one line): `size` numbers from `start`, of which `observed` were used by the pass
    line*, start*, size*, observed*: int
    slots*: seq[string]       ## a place that branches made steps on: `<ctx>#<nth>` of every step the pass saw there, the slot being the place in this list. Empty: a place of `main` alone, numbered by its instance

  StepTable* = object
    blocks*: seq[Block]
    overflowNext*: int
    overflowGiven: seq[(int, int, int)]       ## (line, instance, number) of what was given from the overflow, so that asking again gives the same
    hashTaken: Table[int, string]             ## the numbers given to places of branches that the pass did not see, and to which place

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

func assignPlaces*(places: seq[(int, string, int)]): StepTable =
  ## `places`: (line, ctx, nth) of every step the pass made. A line on which only `main` made steps is a block as `assignBlocks` makes it; a line on which a branch made a step
  ## has exactly as many numbers as steps were seen there, in the order they were seen: a step of a branch is found by the place (`ctx`, `nth`) and not by the order in which
  ## the branches happened to ask, and the room a loop of unknown length may need is the overflow (`numberOfAt`).
  var order: seq[int]
  var onLine: seq[seq[(string, int)]]
  for (l, ctx, nth) in places:
    var found = order.find(l)
    if found < 0:
      order.add l
      onLine.add @[]
      found = order.high
    onLine[found].add (ctx, nth)
  var next = 0
  for i, l in order:
    let seen = onLine[i]
    let inBranch = seen.anyIt(it[0] != "m")
    if inBranch:
      result.blocks.add Block(line: l, start: next, size: seen.len, observed: seen.len, slots: seen.mapIt(it[0] & "#" & $it[1]))
      next += seen.len
    else:
      let size = blockSize(seen.len)
      result.blocks.add Block(line: l, start: next, size: size, observed: seen.len)
      next += size
  result.overflowNext = overflowBase

func placeHash(line: int; ctx: string; nth: int): int =
  ## FNV-1a over the text of the place: the same place gives the same number in every execution
  var h = 2166136261'u32
  for c in ctx & "|" & $line & "|" & $nth:
    h = (h xor uint32(ord(c))) * 16777619'u32
  int(h mod 1_000_000_000'u32)

proc numberOfAt*(t: var StepTable; line: int; ctx: string; nth: int): int =
  ## The number of the `nth` step (from 0) that the context `ctx` made on `line`. In a block of the pass: its number. Not in one: `main` takes the next number of the overflow (and the
  ## same one again if asked again; `main` is one sequence, so the order of asking is the order of the script); a branch takes a number made of the place alone, in
  ## [`branchOverflowBase`, 2 000 000 000), whichever branch asks first. Two places that fall on one number (chance: a few in a million for 200 steps) are told apart by the order in
  ## which they ask.
  for b in t.blocks:
    if b.line != line: continue
    if b.slots.len > 0:
      let at = b.slots.find(ctx & "#" & $nth)
      if at >= 0: return b.start + at
    elif ctx == "m" and nth >= 0 and nth < b.size:
      return b.start + nth
  if ctx == "m":
    for (l, i, n) in t.overflowGiven:
      if l == line and i == nth: return n
    result = t.overflowNext
    inc t.overflowNext
    t.overflowGiven.add (line, nth, result)
    return
  let place = ctx & "|" & $line & "|" & $nth
  var n = branchOverflowBase + placeHash(line, ctx, nth)
  while t.hashTaken.getOrDefault(n, place) != place:
    n = if n + 1 >= 2_000_000_000: branchOverflowBase else: n + 1
  t.hashTaken[n] = place
  n

proc numberOf*(t: var StepTable; line, instance: int): int =
  ## The number of the `instance`-th step (from 0) made on `line` by `main`: inside the block of that place if it has room, else the next number of the overflow (and the same
  ## one again if asked again).
  t.numberOfAt(line, "m", instance)

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
  var places: seq[(int, string, int)]
  let r = replay.execute(sb, j, script, stubHost, runId = "table", params = params,
                         onPlace = proc (seq: int; kind: string; line: int; ctx: string; nth: int) = (if kind == "job_sh": places.add (line, ctx, nth)))
  result.table = assignPlaces(places)
  result.steps = places.len
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
  for x in t.blocks:
    var row = %[x.line, x.start, x.size, x.observed]
    if x.slots.len > 0: row.add %x.slots
    b.add row
  $(%*{"v": tableRules, "b": b})

proc decodeTable*(s: string): Option[StepTable] =
  if s.len == 0: return none(StepTable)
  try:
    let j = parseJson(s)
    if j.kind != JObject or j{"v"}.getInt != tableRules or j{"b"}.kind != JArray: return none(StepTable)
    var t = StepTable(overflowNext: overflowBase)
    for x in j["b"]:
      if x.kind != JArray or x.len notin 4 .. 5: return none(StepTable)
      var blk = Block(line: x[0].getInt, start: x[1].getInt, size: x[2].getInt, observed: x[3].getInt)
      if x.len == 5:
        if x[4].kind != JArray: return none(StepTable)
        for sl in x[4]: blk.slots.add sl.getStr
      t.blocks.add blk
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

proc onPlace*(n: var Numbering; kind: string; line: int; ctx: string; nth: int) =
  ## the same, told where in the tree of branches the call is made (`replay.execute`'s `onPlace`): the number is that of the place, whatever the order in which the branches ask
  if kind != "job_sh": return
  n.lastNo = n.table.numberOfAt(line, ctx, nth)

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

# ------------------------------------------------------------------ the check before a run exists (PIP-016)

type Preflight* = object
  ## what a pass of the script against the stub host found. `code` "" is nothing found. `certain`: the finding is the script's and the parameters' alone - it came before the first
  ## step, so no answer of a step can be the cause - or it is a limit the pass proves (`step_limit`, `duplicate_id`); an uncertain one (the script broke after a stub answer) is only a hint
  code*, message*, paramsJson*: string
  certain*: bool
  steps*: int

proc preflight*(script: string; params: seq[(string, string)] = @[]; apiVersion = currentApiVersion): Preflight =
  ## Run `script` once against the stub host with the launch parameters `params`: the metadata phase (the declarations of the parameters and their checking, the options of the pipeline)
  ## and `main` as far as the stub takes it. Nothing is made anywhere. The same pass the table of step numbers is made by, so what it proves about steps is what the table refuses.
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
