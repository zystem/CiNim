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
    check logComplete("SUCCEEDED", 0, 0)                 # a step that wrote nothing
    check not logComplete("FAILED", -1, 5)               # the shim has said nothing: unknown, not complete
    check logComplete("TIMED_OUT", 3, 3)

  test "the shim's count of lines is read from its state JSON":
    check linesReported("""{"v":1,"n":6,"ev":"done","lines":1201,"blocks":4}""") == 1201
    check linesReported("") == -1 and linesReported("{}") == -1 and linesReported("not json") == -1
