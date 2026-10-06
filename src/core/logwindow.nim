## The window of a step's log as the API returns it (DAT-007): lines in the order of the build's output, from a line number, with a mark that
## says whether everything the shim reported is readable yet. Pure, so `tests/unit/tlogwindow.nim` runs without VictoriaLogs.
##
## Two facts about VictoriaLogs shape this. It returns records in no particular order (the newest first, in practice), so the window is asked
## for sorted by `ln`, the line number that the shim gives every line, and sorted again here. And a record whose `_msg` is empty, which is a
## blank line of the build's output, is stored with the text below instead of an empty message; it is turned back into a blank line.
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
