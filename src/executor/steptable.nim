## The table of step numbers (docs/parallel.md section 3): before a run is led, the script is run once against a stub host and the places where steps are made are
## recorded; the places are numbered in the order in which they were first met, a place that made one step gets one number and a place that made several gets a
## block with room to spare. A step finds its number here when it is made. Pure but for the pass itself, which runs the script in a sandbox like any other.
import std/[options, strutils]
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
