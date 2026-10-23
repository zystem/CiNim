## The window of a step's log as the API returns it (DAT-007): lines in the order of the build's output, from a line number, with a mark that
## says whether everything the shim reported is readable yet. Pure, so `tests/unit/tlogwindow.nim` runs without VictoriaLogs.
##
## Two facts about VictoriaLogs shape this. It returns records in no particular order (the newest first, in practice), so the window is asked
## for sorted by `ln`, the line number that the shim gives every line, and sorted again here. And a record whose `_msg` is empty is stored with
## the text below instead of an empty message. The shim no longer sends empty lines (shim/logspool.nim), but records stored before that, and any
## other writer, can hold one: it is turned back into a blank line.
## A third is not a bug but the measured delay of A.7: a record is readable about one to two seconds after the collector's acknowledgement
## (which already waits for vlagent), so a reader that comes the moment a step has ended can find its last lines missing. `complete` is how
## it knows: the shim states how many lines the step wrote, and the window is complete when that many are stored.
import std/[json, strutils, algorithm]

const
  vlEmptyMessage* = "missing _msg field; see https://docs.victoriametrics.com/"   ## what VictoriaLogs stores for a record with an empty `_msg`
  maxWindow* = 500                                                              ## the most lines one answer holds (the API table of 9.1)

type
  LogLine* = tuple[ln: int, text: string]

proc parseLogRecords*(body: string): seq[LogLine] =
  ## the records of a `/select/logsql/query` answer (one JSON object per line), sorted by line number; a blank line is ""
  for raw in body.splitLines:
    if raw.len == 0: continue
    try:
      let j = parseJson(raw)
      let msg = j{"_msg"}.getStr
      var ln = -1
      try: ln = parseInt(j{"ln"}.getStr)
      except ValueError: discard
      result.add (ln: ln, text: (if msg.startsWith(vlEmptyMessage): "" else: msg))
    except CatchableError:
      discard                       # a line that is not a record (an error text of the store): not a line of the log
  result.sort(proc (a, b: LogLine): int = cmp(a.ln, b.ln))

func contiguousFrom*(records: seq[LogLine]; first: int): seq[string] =
  ## the lines from `first` on, up to the first one that is missing: a gap means a record that is not readable yet, and a window that skipped it
  ## would hide it from a reader that continues from the end of the window
  var want = first
  for r in records:
    if r.ln < want: continue        # a duplicate (a block delivered twice) or a line before the window
    if r.ln != want: break
    result.add r.text
    inc want

func stepTerminal*(state: string): bool =
  state notin ["PENDING", "STARTING", "RUNNING", ""]

func logComplete*(state: string; linesTotal, linesStored: int): bool =
  ## the step has ended, the shim said how many lines it wrote, and that many are stored
  stepTerminal(state) and linesTotal >= 0 and linesStored >= linesTotal

proc linesReported*(shimJson: string): int =
  ## how many lines the shim says the step has written (its state JSON, D-30); -1 when it has said nothing
  if shimJson.len == 0: return -1
  try: parseJson(shimJson){"lines"}.getInt(-1)
  except CatchableError: -1

# ------------------------------------------------------------------ the log of a whole run (D-77)
# The records carry `step` (the step's number), `job_id` and `step_id` (its two ids, joined as `0v/0004` for a person), and `attempt`, so one query reads the lines of every step of a run in the
# order of step, attempt and line. A page of it is the lines between two cursors; the cursor is the step, the attempt and the line.

type
  RunCursor* = object
    step*, attempt*, ln*: int

  RunLine* = object
    step*, attempt*, ln*: int
    jobId*, stepId*, text*: string

func cursorText*(c: RunCursor): string = $c.step & "." & $c.attempt & "." & $c.ln

func parseCursor*(s: string): tuple[ok: bool, c: RunCursor] =
  ## "<step>.<attempt>.<line>": three numbers and nothing else (it goes into a query)
  let p = s.split('.')
  if p.len != 3: return
  var v: array[3, int]
  for i in 0 .. 2:
    if p[i].len == 0 or p[i].len > 12 or not p[i].allCharsInSet({'0' .. '9'}): return
    try: v[i] = parseInt(p[i])
    except ValueError: return
  (true, RunCursor(step: v[0], attempt: v[1], ln: v[2]))

func runIdOk(id: string): bool =
  id.len in 1 .. 64 and id.allCharsInSet({'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-'})

func runLogQuery*(runId: string; wantCursor: bool; c: RunCursor; backwards: bool; limit: int): string =
  ## The LogsQL for `limit` lines of a run: after the cursor (forwards, the cursor's line included) or before it (backwards, the cursor's line left out, the nearest first), the whole run
  ## when there is no cursor (forwards: from its first line; backwards: from its last). "" for a run id that is not one. A record with no `step` (written before D-77) is not in it.
  if not runIdOk(runId): return ""
  var cond = "run:" & runId & " AND step:>=0"
  if wantCursor:
    let st = $c.step
    let at = $c.attempt
    if backwards:
      cond.add " AND (step:<" & st & " OR (step:=" & st & " AND attempt:<" & at & ") OR (step:=" & st & " AND attempt:=" & at & " AND ln:<" & $c.ln & "))"
    else:
      cond.add " AND (step:>" & st & " OR (step:=" & st & " AND attempt:>" & at & ") OR (step:=" & st & " AND attempt:=" & at & " AND ln:>=" & $c.ln & "))"
  cond & " | sort by " & (if backwards: "(step desc, attempt desc, ln desc)" else: "(step, attempt, ln)") & " | limit " & $limit

proc parseRunRecords*(body: string): seq[RunLine] =
  ## the records of a `/select/logsql/query` answer as lines of a run, in the order of step, attempt and line; a record without a step is not one, and a line that is no record is nothing
  for raw in body.splitLines:
    if raw.len == 0: continue
    try:
      let j = parseJson(raw)
      var l = RunLine(step: -1, ln: -1)
      try:
        l.step = parseInt(j{"step"}.getStr)
        l.attempt = parseInt(j{"attempt"}.getStr)
        l.ln = parseInt(j{"ln"}.getStr)
      except ValueError:
        continue
      let msg = j{"_msg"}.getStr
      l.text = if msg.startsWith(vlEmptyMessage): "" else: msg
      l.jobId = j{"job_id"}.getStr
      l.stepId = j{"step_id"}.getStr
      result.add l
    except CatchableError:
      discard
  result.sort(proc (a, b: RunLine): int =
    result = cmp(a.step, b.step)
    if result == 0: result = cmp(a.attempt, b.attempt)
    if result == 0: result = cmp(a.ln, b.ln))
