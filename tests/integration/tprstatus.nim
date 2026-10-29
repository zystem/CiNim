## D-96, against a real rqlite and a stand-in host: the state of a run is told to the host of the repository as the status of the commit (GitHub) or of the pipeline (GitLab), once for each state,
## with the token of a secret of the organisation, only where the shard allows the address, and tried again when the host refuses. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, tables, asynchttpserver, asyncdispatch, locks, httpcore]
import common/[rqlite, scriptsource]
import core/[schema, scheduler, groups, projectpolicy, secretvault, kekprovider, prstatus, loggate, logcircuit, runlease]

let url = getEnv("CINIM_RQLITE_URL")

var
  seenLock: Lock
  seen: seq[string]                  ## "<method> <path> <authorization or private-token> <body>" of what the stand-in host got
  answer = 201
initLock seenLock

proc bodyOf(line: string): JsonNode = parseJson(line[line.find('{') .. ^1])

proc handle(req: Request) {.async, gcsafe.} =
  {.cast(gcsafe).}:
    withLock seenLock:
      seen.add $req.reqMethod & " " & req.url.path & (if req.url.query.len > 0: "?" & req.url.query else: "") & " " & req.headers.getOrDefault("Authorization") & req.headers.getOrDefault("PRIVATE-TOKEN") & " " & req.body
    await req.respond(HttpCode(answer), "{}")

proc standIn() {.thread.} =
  {.cast(gcsafe).}:
    var server = newAsyncHttpServer()
    waitFor server.serve(Port(24877), handle)

suite "D-96 the status of a run in the host of its repository":
  test "the target: a provider, a repository, a secret, an address the shard allows":
    putEnv("CINIM_STATUS_API_URLS", "http://127.0.0.1:24877")
    check parseStatusTarget(%*{"provider": "github", "repository": "o/r", "secret": "TOK", "api_url": "http://127.0.0.1:24877/"}).error == ""
    check parseStatusTarget(%*{"provider": "github", "repository": "o/r", "secret": "TOK"}).error.contains("not one the shard allows")          # the default is not on the list now
    delEnv("CINIM_STATUS_API_URLS")
    check parseStatusTarget(%*{"provider": "github", "repository": "o/r", "secret": "TOK"}).target.apiUrl == "https://api.github.com"
    check parseStatusTarget(%*{"provider": "gitlab", "repository": "g/sub/r", "secret": "TOK"}).target.apiUrl == "https://gitlab.com/api/v4"
    check parseStatusTarget(%*{"provider": "github", "repository": "o/r", "secret": "TOK", "api_url": "https://evil.example"}).error.contains("not one the shard allows")
    for bad in [%*{"provider": "bitbucket", "repository": "o/r", "secret": "T"}, %*{"provider": "github", "repository": "r", "secret": "T"}, %*{"provider": "github", "repository": "o/r;x", "secret": "T"},
                %*{"provider": "github", "repository": "o/r"}, %*{"provider": "github", "repository": "o/r", "secret": "a b"}]:
      check parseStatusTarget(bad).error.len > 0
  test "the word for each state, in the words of each host":
    check statusOf("github", "OK", "", 0, 1) == ("success", "passed") and statusOf("gitlab", "OK", "", 0, 1) == ("success", "passed")
    check statusOf("github", "WAITING", "", 1, 2) == ("pending", "waits for approval (1 of 2)")
    check statusOf("github", "RUNNING", "", 0, 0).code == "pending" and statusOf("gitlab", "RUNNING", "", 0, 0).code == "running"
    check statusOf("github", "FAILED", "step 1 exited with 2", 0, 0) == ("failure", "failed: step 1 exited with 2") and statusOf("gitlab", "FAILED", "x", 0, 0).code == "failed"
    check statusOf("github", "ABORTED", "rejected by ann: no", 0, 0).text == "rejected by ann: no" and statusOf("gitlab", "ABORTED", "", 0, 0).code == "canceled"
    check statusOf("github", "TIMED_OUT", "", 0, 0).code == "error" and statusOf("github", "SKIPPED", "", 0, 0).code == ""
    check statusOf("github", "FAILED", 'x'.repeat(500), 0, 0).text.len <= 140

suite "D-96 syncStatuses":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    setDekCacheSeconds(0.0)
    var th: Thread[void]
    createThread(th, standIn)
    sleep 400
    putEnv("CINIM_STATUS_API_URLS", "http://127.0.0.1:24877")
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let slug = "ps" & sfx
    let org = c.addOrganization(slug, "A")
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let prof = c.ensureOrganizationProfile(org, "cinim-001-" & slug)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let now = getTime().toUnix()
    let kek = derivedKek("status-key-" & sfx)
    activateVault(kek)
    check c.createGroup(org, "ci", now).error.len == 0
    check c.createProject(org, "ci/app", "https://example.test/app.git", now).error.len == 0
    let app = c.groupIdOf(org, "ci/app").id
    let sha = "c".repeat(40)
    proc mk(): string =
      co.createRun("return 1", org, prof, @[], groupId = app, source = Source(repository: "https://example.test/app.git", commit: sha, path: ".ci/pipeline.lua", refName: "main"))
    proc sentCount(): int = withLock seenLock: result = seen.len
    proc setState(id, st: string) = discard c.execute(%*[["UPDATE runs SET state = ? WHERE id = ?", st, id]])

    test "a project that tells nobody tells nobody":
      let id = mk()
      check syncStatuses(url, getTime().toUnix()) == 0 and sentCount() == 0
      check c.query(%*[["SELECT status_sent FROM runs WHERE id = ?", id]])["results"][0]["values"][0][0].getStr == ""
    test "GitHub: each new state is told once, with the token of the secret, the context of the pipeline and the commit":
      check c.putSecret(kek, org, "GH_TOKEN", "ghp-secret", now, app).ok
      check c.setStatusTarget(app, %*{"provider": "github", "repository": "o/r", "secret": "GH_TOKEN", "api_url": "http://127.0.0.1:24877"}) == ""
      discard c.execute(%*[["UPDATE runs SET status_sent = state WHERE group_id = ?", app]])           # the runs of the earlier tests are told already
      let id = mk()
      withLock seenLock: seen.setLen 0
      putEnv("CINIM_UI_URL", "https://ci.example/ui/")
      check syncStatuses(url, getTime().toUnix()) == 1
      withLock seenLock:
        check seen.len == 1 and seen[0].startsWith("POST /repos/o/r/statuses/" & sha & " Bearer ghp-secret ")
        let body = bodyOf(seen[0])
        check body["state"].getStr == "pending" and body["context"].getStr == "cinim/.ci/pipeline.lua" and body["target_url"].getStr == "https://ci.example/ui/runs/" & id and body["description"].getStr == "queued"
      check syncStatuses(url, getTime().toUnix()) == 0                                                  # nothing changed: nothing told
      setState(id, "OK")
      check syncStatuses(url, getTime().toUnix()) == 1
      withLock seenLock: check bodyOf(seen[^1])["state"].getStr == "success"
      check syncStatuses(url, getTime().toUnix()) == 0
    test "a run that waits for approval is told with how many have approved":
      let id = mk()
      discard c.execute(%*[["UPDATE runs SET state = 'WAITING', approval_required = 2 WHERE id = ?", id]])
      discard c.execute(%*[["INSERT INTO run_approvals (run_id, user_name, decision, at) VALUES (?, 'bob', 'approve', 1)", id]])
      discard syncStatuses(url, getTime().toUnix())
      withLock seenLock: check bodyOf(seen[^1])["description"].getStr == "waits for approval (1 of 2)"
    test "the host refuses: the state stays untold and is tried again after a minute":
      let id = mk()
      setState(id, "FAILED")
      answer = 500
      let before = sentCount()
      check syncStatuses(url, getTime().toUnix()) == 0 and sentCount() > before
      let tried = sentCount()
      answer = 201
      check syncStatuses(url, getTime().toUnix()) == 0 and sentCount() == tried                       # too soon
      check syncStatuses(url, getTime().toUnix() + 61) >= 1
      check c.query(%*[["SELECT status_sent FROM runs WHERE id = ?", id]])["results"][0]["values"][0][0].getStr == "FAILED"
    test "GitLab: the token goes in PRIVATE-TOKEN and the state in the query":
      check c.putSecret(kek, org, "GL_TOKEN", "glpat-secret", now, app).ok
      check c.setStatusTarget(app, %*{"provider": "gitlab", "repository": "g/sub/r", "secret": "GL_TOKEN", "api_url": "http://127.0.0.1:24877"}) == ""
      discard c.execute(%*[["UPDATE runs SET status_sent = state WHERE group_id = ?", app]])
      let id = mk()
      setState(id, "RUNNING")
      withLock seenLock: seen.setLen 0
      check syncStatuses(url, getTime().toUnix()) == 1
      withLock seenLock: check seen[0].startsWith("POST /projects/g%2Fsub%2Fr/statuses/" & sha & "?state=running&name=cinim%2F.ci%2Fpipeline.lua") and " glpat-secret " in seen[0]
    test "a missing secret tells nothing; a cleared target stops the telling":
      check c.setStatusTarget(app, %*{"provider": "github", "repository": "o/r", "secret": "NOPE", "api_url": "http://127.0.0.1:24877"}) == ""
      discard c.execute(%*[["UPDATE runs SET status_sent = state WHERE group_id = ?", app]])
      let id = mk()
      let before = sentCount()
      check syncStatuses(url, getTime().toUnix()) == 0 and sentCount() == before
      check c.setStatusTarget(app, newJNull()) == "" and c.statusTargetOf(app).provider == ""
      check syncStatuses(url, getTime().toUnix() + 100) == 0 and id.len > 0
