## DAT-007, A.7: the window of a step's log: the order of the build's output, blank lines, a window without gaps, and the mark that says the
## step's log is all there (the shim's count of lines against the lines stored).
import std/[unittest, json, strutils, sequtils]
import ../../src/core/logwindow

proc rec(ln: int; msg: string): string = $(%*{"_msg": msg, "ln": $ln, "job": "j", "run": "r"})

suite "DAT-007 the window of a step's log":
  test "the lines come in the order of the build's output whatever order the store answers in (it answers the newest first)":
    let body = [rec(2, "c"), rec(0, "a"), rec(1, "b"), rec(10, "k"), rec(3, "d")].join("\n")
    check parseLogRecords(body).mapIt(it.text) == @["a", "b", "c", "d", "k"]
    check parseLogRecords(body).mapIt(it.ln) == @[0, 1, 2, 3, 10]
    check contiguousFrom(parseLogRecords(body), 0) == @["a", "b", "c", "d"]      # line 4 is not readable yet: the window stops there

  test "a blank line of the output is stored by VictoriaLogs with its own text and comes back blank":
    let body = [rec(0, "first"), rec(1, vlEmptyMessage & "#message-field"), rec(2, "third")].join("\n")
    check contiguousFrom(parseLogRecords(body), 0) == @["first", "", "third"]
    check parseLogRecords(rec(0, "a line that says missing _msg field")).mapIt(it.text) == @["a line that says missing _msg field"]

  test "a window starts at the line asked for, a duplicate is one line, a line before the window is left out":
    let body = [rec(5, "e"), rec(6, "f"), rec(6, "f"), rec(7, "g"), rec(4, "d")].join("\n")
    check contiguousFrom(parseLogRecords(body), 5) == @["e", "f", "g"]
    check contiguousFrom(parseLogRecords(body), 6) == @["f", "g"]
    check contiguousFrom(parseLogRecords(body), 9).len == 0
    check contiguousFrom(parseLogRecords(body), 0).len == 0                       # nothing at line 0: nothing is skipped over

  test "a line that is not a record (an error text of the store) is not a line of the log":
    check parseLogRecords("not json\n" & rec(0, "a") & "\n\n").mapIt(it.text) == @["a"]

  test "the log is complete when the step has ended and the shim's count of lines is stored":
    check not logComplete("RUNNING", 10, 10)
    check not logComplete("FAILED", 1201, 1200)          # the step is over and the last line is not readable yet: ask again
    check logComplete("FAILED", 1201, 1201)
    check logComplete("OK", 0, 0)                 # a step that wrote nothing
    check not logComplete("FAILED", -1, 5)               # the shim has said nothing: unknown, not complete
    check logComplete("TIMED_OUT", 3, 3)

  test "the shim's count of lines is read from its state JSON":
    check linesReported("""{"v":1,"n":6,"ev":"done","lines":1201,"blocks":4}""") == 1201
    check linesReported("") == -1 and linesReported("{}") == -1 and linesReported("not json") == -1

suite "D-77 the window of the log of a whole run":
  test "a cursor is the step, the attempt and the line; what is not three numbers is no cursor":
    check parseCursor("37748739.1.12") == (true, RunCursor(step: 37748739, attempt: 1, ln: 12))
    check cursorText(RunCursor(step: 3, attempt: 2, ln: 0)) == "3.2.0"
    for bad in ["", "1.2", "1.2.3.4", "a.b.c", "1.2.-3", "1..3", "1.2.3 or 1", "99999999999999999999.1.1"]:
      check not parseCursor(bad).ok
  test "the query asks for the records of one run that have a step, after a cursor, in the order of step, attempt and line":
    let first = runLogQuery("s1_abc", wantCursor = false, c = RunCursor(), backwards = false, limit = 201)
    check "run:s1_abc" in first and "step:>=0" in first and "sort by (step, attempt, ln)" in first and first.endsWith("limit 201")
    let after = runLogQuery("s1_abc", true, RunCursor(step: 5, attempt: 2, ln: 7), false, 201)
    check "step:>5" in after and "step:=5 AND attempt:>2" in after and "step:=5 AND attempt:=2 AND ln:>=7" in after
    let before = runLogQuery("s1_abc", true, RunCursor(step: 5, attempt: 2, ln: 7), true, 201)
    check "step:<5" in before and "step:=5 AND attempt:<2" in before and "step:=5 AND attempt:=2 AND ln:<7" in before
    check "sort by (step desc, attempt desc, ln desc)" in before
    let tail = runLogQuery("s1_abc", false, RunCursor(), true, 201)
    check "sort by (step desc, attempt desc, ln desc)" in tail and "ln:<" notin tail
  test "a run id that is not made of the characters of run ids is refused: it goes into the query":
    check runLogQuery("s1_abc OR run:x", false, RunCursor(), false, 10) == ""
    check runLogQuery("", false, RunCursor(), false, 10) == ""
  test "the records come back as lines with the step, its ids and the attempt, in the order of the log, whatever order the store answered in":
    let body = "{\"_msg\":\"b\",\"step\":\"37748739\",\"job_id\":\"14\",\"step_id\":\"0003\",\"attempt\":\"1\",\"ln\":\"1\"}\n" &
               "{\"_msg\":\"c\",\"step\":\"38797313\",\"job_id\":\"15\",\"step_id\":\"0001\",\"attempt\":\"1\",\"ln\":\"0\"}\n" &
               "{\"_msg\":\"a\",\"step\":\"37748739\",\"job_id\":\"14\",\"step_id\":\"0003\",\"attempt\":\"1\",\"ln\":\"0\"}\n" &
               "not a record\n" &
               "{\"_msg\":\"no step\",\"ln\":\"4\"}\n"
    let r = parseRunRecords(body)
    check r.mapIt(it.text) == @["a", "b", "c"]                       # sorted; a record with no step is not in the log of a run; a line that is no record is nothing
    check r[0].step == 37748739 and r[0].jobId == "14" and r[0].stepId == "0003" and r[2].jobId == "15" and r[0].attempt == 1 and r[0].ln == 0
    check parseRunRecords("{\"_msg\":\"missing _msg field; see https://docs.victoriametrics.com/\",\"step\":\"1\",\"attempt\":\"1\",\"ln\":\"0\"}")[0].text == ""
