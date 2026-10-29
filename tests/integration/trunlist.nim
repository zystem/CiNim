## The list of runs (core/runlist.nim, GET /api/v1/runs): newest first, a page at a time with the id of the last one as the cursor, filtered by organisation and by state, and nothing of
## another organisation. The page of runs of the UI (docs/ui.md) is made of it. Needs CINIM_RQLITE_URL (the suite makes its own organisations and runs); otherwise it is skipped.
import std/[unittest, json, os, sets, sequtils, algorithm, strutils]
import common/rqlite, common/scriptsource
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
    test "UI-001 the row of a run made from a repository says which pipeline (the path of the script) and where; a run with no repository has no source":
      let withSource = co.createRun("return 1", orgB, profB, @[], source = Source(repository: "https://example.test/r.git", commit: "a".repeat(40), path: ".ci/03.lua"))
      idsB.add withSource                                      # it is one of the runs of that organisation for the tests that follow
      let row = c.listRuns("", "", 200, "")["runs"].elems.filterIt(it["id"].getStr == withSource)[0]
      check row["source"]["path"].getStr == ".ci/03.lua" and row["source"]["repository"].getStr == "https://example.test/r.git"
      check not c.listRuns("", "", 200, "")["runs"].elems.filterIt(it["id"].getStr == idsA[0])[0].hasKey("source")
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
    test "D-84 `only` keeps the runs of the organisations a caller may see, and none of the others":
      let onlyA = c.listRuns("", "", 200, "", @[slugA])["runs"].mapIt(it["organization"].getStr)
      check onlyA.len == 7 and onlyA.allIt(it == slugA)
      let both = c.listRuns("", "", 200, "", @[slugA, slugB])["runs"]
      check both.len == 7 + idsB.len and both.allIt(it["organization"].getStr in [slugA, slugB])
      check c.listRuns("", "", 200, "", @["no-such-org-" & sfx])["runs"].len == 0
    test "D-84 `groups` keep the runs of a group or project and of what is under it, and not a sibling or a group whose name only starts the same":
      proc groupWith(path: string): string =
        let id = newId()
        discard c.execute(%*[["INSERT INTO groups (id, tenant_id, parent_id, slug, path, depth, created_at) VALUES (?, ?, '', ?, ?, 1, 0)", id, orgA, path.split('/')[^1], path, path.split('/').len]])
        id
      let ci = groupWith("ci"); let cinim = groupWith("ci/cinim"); let cinema = groupWith("cinema")
      discard c.execute(%*[["UPDATE runs SET group_id = ? WHERE id = ?", ci, idsA[0]], ["UPDATE runs SET group_id = ? WHERE id = ?", cinim, idsA[1]],
                           ["UPDATE runs SET group_id = ? WHERE id = ?", cinema, idsA[2]]])
      let seen = c.listRuns("", "", 200, "", @[], @[(slugA, "ci")])["runs"].mapIt(it["id"].getStr)
      check seen.len == 2 and idsA[0] in seen and idsA[1] in seen and idsA[2] notin seen
      check c.listRuns("", "", 200, "", @[], @[(slugA, "ci/cinim")])["runs"].mapIt(it["id"].getStr) == @[idsA[1]]
      check c.listRuns("", "", 200, "", @[], @[(slugB, "ci")])["runs"].len == 0                       # the organisation counts
      let mixed = c.listRuns("", "", 200, "", @[slugB], @[(slugA, "ci/cinim")])["runs"]
      check mixed.len == idsB.len + 1
      check c.listRuns(slugA, "", 200, "", @[], @[(slugA, "ci"), (slugB, "ci")])["runs"].len == 2
    test "the values are parameters, not SQL":
      check c.listRuns("x' OR '1'='1", "", 50, "")["runs"].len == 0
      check c.listRuns(slugA, "FAILED' OR '1'='1", 50, "")["runs"].len == 0
      check c.listRuns(slugA, "", 50, "' OR id != '")["runs"].len == 0

suite "UI who may list which runs":
  proc scopeOf(w: Principal; asked: string): string =
    ## the answer as one line: ok, the organisation asked, the organisations, the groups
    let r = runListScope(w, asked)
    $r.ok & " " & r.organization & " " & r.only.join(",") & " " & r.groups.mapIt(it.org & "/" & it.path).join(",")
  test "D-90 an administrator: any organisation, or all of them":
    let admin = principalOf("admin")
    check scopeOf(admin, "") == "true   "
    check scopeOf(admin, "acme") == "true acme  "
  test "a token of an organisation: its own runs, whether it names the organisation or not; another's is refused":
    let t = principalOf("org:acme")
    check scopeOf(t, "") == "true  acme "
    check scopeOf(t, "acme") == "true acme  "
    check not runListScope(t, "other").ok
  test "D-84 a user with a role in some organisations: those, and another's is refused":
    var g: Grants
    g.addRole("org:acme", builtinPermissions("ro"))
    g.addRole("org:beta", builtinPermissions("dev"))
    g.addRole("org:gamma", ["trigger.read"])                      # a role that cannot read runs there
    let u = Principal(ok: true, user: "x", grants: g)
    let all = runListScope(u, "")
    check all.ok and all.organization == "" and all.only.len == 2 and "acme" in all.only and "beta" in all.only and "gamma" notin all.only and all.groups.len == 0
    check scopeOf(u, "beta") == "true beta  "
    check not runListScope(u, "gamma").ok and not runListScope(u, "other").ok
  test "D-84 a user with a role on groups: those groups, and the organisation asked for only when something is held in it":
    var g: Grants
    g.addRole("org:acme", builtinPermissions("ro"))
    g.addRole("org:beta/ci", builtinPermissions("dev"))
    g.addRole("org:beta/qa/web", builtinPermissions("ro"))
    g.addRole("org:gamma/x", ["trigger.read"])
    let u = Principal(ok: true, user: "x", grants: g)
    check scopeOf(u, "") == "true  acme beta/ci,beta/qa/web"
    check scopeOf(u, "acme") == "true acme  "
    check scopeOf(u, "beta") == "true beta  beta/ci,beta/qa/web"
    check not runListScope(u, "gamma").ok
    var onlyGroup: Grants
    onlyGroup.addRole("org:beta/ci", builtinPermissions("ro"))
    check scopeOf(Principal(ok: true, user: "y", grants: onlyGroup), "") == "true   beta/ci"
  test "no one and a token of no organisation: refused":
    check not runListScope(Principal(), "").ok
    check not runListScope(Principal(ok: true), "").ok
    check not runListScope(Principal(ok: true, user: "x"), "").ok
