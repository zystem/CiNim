## The list of runs (core/runlist.nim, GET /api/v1/runs): newest first, a page at a time with the id of the last one as the cursor, filtered by organisation and by state, and nothing of
## another organisation. The page of runs of the UI (docs/ui.md) is made of it. Needs CINIM_RQLITE_URL (the suite makes its own organisations and runs); otherwise it is skipped.
import std/[unittest, json, os, sets, sequtils, algorithm]
import common/rqlite
import core/[schema, scheduler, loggate, logcircuit, runlease, runlist, apiauth]

let url = getEnv("CINIM_RQLITE_URL")

suite "UI the list of runs":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let slugA = "la-" & sfx
    let slugB = "lb-" & sfx
    let orgA = c.addOrganization(slugA, "A")
    let orgB = c.addOrganization(slugB, "B")
    let profA = c.ensureOrganizationProfile(orgA, "cinim-001-" & slugA)
    let profB = c.ensureOrganizationProfile(orgB, "cinim-001-" & slugB)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    var idsA, idsB: seq[string]
    for i in 1 .. 7: idsA.add co.createRun("return " & $i, orgA, profA)
    for i in 1 .. 2: idsB.add co.createRun("return " & $i, orgB, profB)
    discard c.execute(%*[["UPDATE runs SET state = 'FAILED', fail_code = 'step_failed', fail_message = 'step 1 exited with 2' WHERE id = ?", idsA[2]]])

    test "newest first, the fields of a row, and the organisation's own runs only":
      let p = c.listRuns(slugA, "", 50, "")
      let ids = p["runs"].mapIt(it["id"].getStr)
      check ids == idsA.reversed                                   # the ids are time-ordered: the last made is the first
      check p["next"].kind == JNull
      let row = p["runs"][0]
      check row["organization"].getStr == slugA and row["state"].getStr.len > 0 and row["created_at"].getStr.len > 0
      check not row.hasKey("steps")                                # a list is cheap: the steps are on the page of the run
      check p["runs"].mapIt(it["organization"].getStr).toHashSet == [slugA].toHashSet
    test "a page at a time: the cursor is the last id of the page, and the pages cover the list once":
      var seen: seq[string]
      var cursor = ""
      var pages = 0
      while true:
        let p = c.listRuns(slugA, "", 3, cursor)
        for r in p["runs"]: seen.add r["id"].getStr
        inc pages
        if p["next"].kind == JNull: break
        cursor = p["next"].getStr
        check pages < 10
      check pages == 3 and seen == idsA.reversed                   # 7 runs in pages of 3: 3 + 3 + 1, no one twice, no one missed
    test "a failed run says why in its row":
      let failed = c.listRuns(slugA, "FAILED", 50, "")
      check failed["runs"].len == 1 and failed["runs"][0]["id"].getStr == idsA[2]
      check failed["runs"][0]["failure"]["code"].getStr == "step_failed"
      check failed["runs"][0]["failure"]["message"].getStr == "step 1 exited with 2"
    test "the filter by organisation keeps another's runs out, and without it all are listed":
      check c.listRuns(slugB, "", 50, "")["runs"].mapIt(it["id"].getStr) == idsB.reversed
      check c.listRuns("", "", 500, "")["runs"].len >= 9
      check c.listRuns("no-such-org-" & sfx, "", 50, "")["runs"].len == 0
    test "the size of a page is bounded, and a nonsense one gets the default":
      check c.listRuns(slugA, "", 0, "")["runs"].len == 7          # 0 and below: the default (50)
      check c.listRuns(slugA, "", -5, "")["runs"].len == 7
      check c.listRuns("", "", 100000, "")["runs"].len <= maxRunPage
    test "the values are parameters, not SQL":
      check c.listRuns("x' OR '1'='1", "", 50, "")["runs"].len == 0
      check c.listRuns(slugA, "FAILED' OR '1'='1", 50, "")["runs"].len == 0
      check c.listRuns(slugA, "", 50, "' OR id != '")["runs"].len == 0

suite "UI who may list which runs":
  test "an administrator and a shard-level role: any organisation, or all of them":
    let admin = principalOf("admin")
    check runListScope(admin, "") == (true, "")
    check runListScope(admin, "acme") == (true, "acme")
    check runListScope(Principal(ok: true, shardWide: true), "acme") == (true, "acme")
  test "a token of an organisation: its own runs, whether it names the organisation or not; another's is refused":
    let t = principalOf("org:acme")
    check runListScope(t, "") == (true, "acme")
    check runListScope(t, "acme") == (true, "acme")
    check runListScope(t, "other") == (false, "")
  test "no one and a token of no organisation: refused":
    check runListScope(Principal(), "") == (false, "")
    check runListScope(Principal(ok: true), "") == (false, "")
