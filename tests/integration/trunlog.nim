## D-77: the window of the log of a whole run (core/scheduler.nim getRunLog): what is asked of the store, how a page is cut and how it says that there is more in either direction. The store is a stand-in
## that answers with the records it is given. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, sequtils]
import common/rqlite
import core/[schema, scheduler, logwindow]
import ../support/fakevlogs

let url = getEnv("CINIM_RQLITE_URL")

func rec(step: int; attempt, ln: int; msg: string): string =
  $(%*{"_msg": msg, "step": $step, "job_id": "14", "step_id": "0003", "attempt": $attempt, "ln": $ln}) & "\n"

suite "D-77 the log of a run":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let profile = c.seedDefaultProfile("cinim-default-ns")
    let org = c.addOrganization("rl" & newId()[^6 .. ^1].toLowerAscii, "RL")
    startFakeVlogs(18797)
    sleep 300
    let co = Core(rqliteUrl: url, profileId: profile, namespace: "cinim-default-ns", victoriaLogsUrl: "http://127.0.0.1:18797")
    let runId = co.createRun("return 1", org, c.ensureOrganizationProfile(org, "cinim-001-rl"))
    proc setState(s: string) = discard c.execute(%*[["UPDATE runs SET state = ? WHERE id = ?", s, runId]])
    proc texts(j: JsonNode): seq[string] = j["lines"].elems.mapIt(it["text"].getStr)

    test "the tail of a run that goes on: the last lines, the way to earlier ones when there are more, and the way on (it may get more)":
      setState("RUNNING")
      # three records come back for a window of two: the farthest from the end is the extra one
      setBody(rec(5, 1, 0, "x") & rec(5, 1, 1, "y") & rec(6, 1, 0, "z"))
      let j = co.getRunLog(runId, false, RunCursor(), true, 2)
      check j.texts == @["y", "z"] and j["earlier"].getStr == "5.1.1" and j["later"].getStr == "6.1.1"
      check "sort by (step desc, attempt desc, ln desc)" in askedFor() and "limit 3" in askedFor() and "run:" & runId in askedFor()
      check j["lines"][0]["job_id"].getStr == "14" and j["lines"][0]["step_id"].getStr == "0003" and j["lines"][0]["step"].getInt == 5
    test "the tail of a finished run whose log fits has no way earlier and none on":
      setState("OK")
      setBody(rec(5, 1, 0, "x") & rec(6, 1, 0, "z"))
      let j = co.getRunLog(runId, false, RunCursor(), true, 10)
      check j.texts == @["x", "z"] and not j.hasKey("earlier") and not j.hasKey("later")
    test "the lines after a cursor: its own line first, the way on when there are more, the way back always":
      setBody(rec(5, 1, 3, "a") & rec(5, 1, 4, "b") & rec(5, 1, 5, "c"))
      let j = co.getRunLog(runId, true, RunCursor(step: 5, attempt: 1, ln: 3), false, 2)
      check j.texts == @["a", "b"] and j["earlier"].getStr == "5.1.3" and j["later"].getStr == "5.1.5"
      check "step:=5 AND attempt:=1 AND ln:>=3" in askedFor() and "sort by (step, attempt, ln)" in askedFor()
    test "the lines before a cursor: the nearest ones, in the order of the log, and the way on is the cursor after the last":
      setBody(rec(5, 1, 0, "a") & rec(5, 1, 1, "b") & rec(5, 1, 2, "c"))
      let j = co.getRunLog(runId, true, RunCursor(step: 6, attempt: 1, ln: 0), true, 10)
      check j.texts == @["a", "b", "c"] and j["later"].getStr == "5.1.3" and not j.hasKey("earlier")
    test "a store that has nothing for the run (or does not answer) is an empty window; a run that does not exist is nil":
      setBody("")
      check co.getRunLog(runId, false, RunCursor(), true, 10).texts.len == 0
      check co.getRunLog("s1_nosuchrun", false, RunCursor(), true, 10) == nil
    stopFakeVlogs()
