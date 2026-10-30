## D-100, against a real rqlite: a run that waits for approval is answered from the pull request: the signature of the host, the comment or the review, the login turned into an account by the table
## of identities, the same rules as the button (run.approve, not the author, once). Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, tables, sequtils, asynchttpserver, asyncdispatch, locks]
import crunchy
import common/[rqlite, scriptsource]
import core/[schema, scheduler, apiauth, groups, projectpolicy, approvals, prstatus, vcsapprove, loggate, logcircuit, runlease]

let url = getEnv("CINIM_RQLITE_URL")

proc hex(a: openArray[byte]): string =
  for b in a: result.add toLowerAscii(strutils.toHex(int(b), 2))

suite "D-100 what the host says":
  test "GitHub: the signature is the HMAC of the body, and nothing else is taken":
    let body = """{"a":1}"""
    let sig = "sha256=" & hex(hmacSha256("s3cret", body))
    check verifyGithub("s3cret", body, sig)
    check not verifyGithub("other", body, sig) and not verifyGithub("s3cret", body & " ", sig) and not verifyGithub("s3cret", body, "") and not verifyGithub("", body, sig) and not verifyGithub("s3cret", body, "sha1=abc")
    check verifyGitlab("tok", "tok") and not verifyGitlab("tok", "tok2") and not verifyGitlab("", "")
  test "the command is the first word of the comment":
    check commandOf("/approve") == "approve" and commandOf("  /APPROVE looks good\nmore") == "approve" and commandOf("/reject: no") == "" and commandOf("/reject no") == "reject"
    check commandOf("please /approve") == "" and commandOf("") == "" and commandOf("lgtm") == ""
  test "GitHub: a comment on a pull request, a review that approves, a review that asks for changes; other events and comments on issues are nothing":
    let comment = parseGithub("issue_comment", %*{"action": "created", "issue": {"number": 7, "pull_request": {}}, "comment": {"body": "/approve", "user": {"login": "Ann"}}, "repository": {"full_name": "o/r"}})
    check comment.relevant and comment.command == "approve" and comment.login == "Ann" and comment.prNumber == 7 and comment.sha == "" and comment.repository == "o/r"
    check not parseGithub("issue_comment", %*{"action": "created", "issue": {"number": 7}, "comment": {"body": "/approve", "user": {"login": "a"}}}).relevant
    check not parseGithub("issue_comment", %*{"action": "edited", "issue": {"pull_request": {}}, "comment": {"body": "/approve", "user": {"login": "a"}}}).relevant
    let rev = parseGithub("pull_request_review", %*{"action": "submitted", "review": {"state": "APPROVED", "user": {"login": "bob"}, "body": "ok"}, "pull_request": {"head": {"sha": "abc"}}, "repository": {"full_name": "o/r"}})
    check rev.relevant and rev.command == "approve" and rev.sha == "abc" and rev.comment == "ok"
    check parseGithub("pull_request_review", %*{"action": "submitted", "review": {"state": "changes_requested", "user": {"login": "bob"}}, "pull_request": {"head": {"sha": "abc"}}}).command == "reject"
    check not parseGithub("pull_request_review", %*{"action": "submitted", "review": {"state": "commented", "user": {"login": "bob"}}}).relevant and not parseGithub("push", %*{}).relevant
  test "GitLab: a note on a merge request and the approval of one":
    let note = parseGitlab("Note Hook", %*{"object_attributes": {"noteable_type": "MergeRequest", "note": "/reject why"}, "user": {"username": "ann"}, "merge_request": {"last_commit": {"id": "def"}}, "project": {"path_with_namespace": "g/r"}})
    check note.relevant and note.command == "reject" and note.sha == "def" and note.repository == "g/r"
    check parseGitlab("Merge Request Hook", %*{"object_attributes": {"action": "approved", "last_commit": {"id": "def"}}, "user": {"username": "ann"}}).command == "approve"
    check not parseGitlab("Note Hook", %*{"object_attributes": {"noteable_type": "Issue", "note": "/approve"}, "user": {"username": "ann"}}).relevant

var
  lock: Lock
  pulls: seq[string]
initLock lock

proc handle(req: Request) {.async, gcsafe.} =
  {.cast(gcsafe).}:
    withLock lock: pulls.add req.url.path & " " & req.headers.getOrDefault("Authorization")
    await req.respond(Http200, """{"head": {"sha": "dddddddddddddddddddddddddddddddddddddddd"}}""")

proc standIn() {.thread.} =
  {.cast(gcsafe).}:
    var server = newAsyncHttpServer()
    waitFor server.serve(Port(24884), handle)

suite "D-100 the answer from the pull request":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let slug = "va" & sfx
    let org = c.addOrganization(slug, "A")
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let prof = c.ensureOrganizationProfile(org, "cinim-001-" & slug)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let now = getTime().toUnix()
    check c.createGroup(org, "ci", now).error.len == 0
    check c.createProject(org, "ci/app", "https://example.test/app.git", now).error.len == 0
    let app = c.groupIdOf(org, "ci/app").id
    let sha = "e".repeat(40)
    var th: Thread[void]
    createThread(th, standIn)
    sleep 400
    var n = 0
    proc person(role: string): string =
      inc n
      let name = "v" & sfx & $n
      check c.createUser(name, role, "a-long-password-of-" & name, now, "org:" & slug)
      name
    let author = person("dev")
    let boss = person("rw")
    let reader = person("ro")
    proc waiting(commit = sha): string =
      co.createRun("return 1", org, prof, @[], groupId = app, source = Source(repository: "https://example.test/app.git", commit: commit, path: ".ci/deploy.lua", refName: "main"),
                   actor = "user:" & author, approval = ApprovalSpec(required: 1, timeoutSeconds: 3600))
    proc stateOf(id: string): string = co.getRun(id)["state"].getStr
    let ev = proc (login, command: string; commit = sha): VcsEvent = VcsEvent(relevant: true, login: login, command: command, sha: commit, comment: "from the pull request")

    test "an identity is a login of the host linked to an account that exists; it is kept in lower case; and it can be listed and deleted":
      check c.setIdentity(org, "github", "BossGH", boss) == "" and c.identityOf(org, "github", "bossgh") == boss and c.identityOf(org, "gitlab", "bossgh") == ""
      check c.setIdentity(org, "github", "x", "nobody-" & sfx).contains("no such user") and c.setIdentity(org, "bitbucket", "x", boss).contains("github or gitlab") and c.setIdentity(org, "github", "a b", boss) != ""
      check c.listIdentities(org)[0]["login"].getStr == "bossgh" and c.deleteIdentity(org, "github", "BOSSGH") and not c.deleteIdentity(org, "github", "bossgh")
    test "a reviewer with an account and run.approve approves the run that waits at the commit; the others are told nothing was done":
      check c.setIdentity(org, "github", "bossgh", boss) == "" and c.setIdentity(org, "github", "readergh", reader) == "" and c.setIdentity(org, "github", "authorgh", author) == ""
      let id = waiting()
      let stranger = c.answerFromHost(org, slug, app, "ci/app", "github", ev("someone", "approve"), now)
      check stranger.status == 202 and "no account" in $stranger.body and stateOf(id) == "WAITING"
      let nobody = c.answerFromHost(org, slug, app, "ci/app", "github", ev("bossgh", "approve", "f".repeat(40)), now)
      check nobody.status == 202 and "no run" in $nobody.body
      let ro = c.answerFromHost(org, slug, app, "ci/app", "github", ev("readergh", "approve"), now)
      check ro.status == 200 and ro.body["answers"][0]["outcome"].getStr == "refused" and stateOf(id) == "WAITING"
      let own = c.answerFromHost(org, slug, app, "ci/app", "github", ev("authorgh", "approve"), now)
      check own.body["answers"][0]["outcome"].getStr == "refused" or own.body["answers"][0]["outcome"].getStr == "aoOwnRun"
      check stateOf(id) == "WAITING"
      let ok = c.answerFromHost(org, slug, app, "ci/app", "github", ev("BossGH", "approve"), now)
      check ok.status == 200 and ok.body["answers"][0]["outcome"].getStr == "aoApproved" and stateOf(id) == "QUEUED"
      check c.answerFromHost(org, slug, app, "ci/app", "github", ev("bossgh", "approve"), now).status == 202          # nothing waits any more
    test "a rejection from the pull request aborts the run, with the comment":
      let id = waiting("a".repeat(40))
      let r = c.answerFromHost(org, slug, app, "ci/app", "github", ev("bossgh", "reject", "a".repeat(40)), now)
      check r.body["answers"][0]["outcome"].getStr == "aoRejected" and stateOf(id) == "ABORTED" and "from the pull request" in co.getRun(id)["failure"]["message"].getStr
      check c.query(%*[["SELECT detail FROM audit_log WHERE action = 'run.reject' AND target = ?", id]])["results"][0]["values"][0][0].getStr.contains("via github as bossgh")
    test "GitHub: the commit of a comment is asked of the host with the token of the project":
      putEnv("CINIM_STATUS_API_URLS", "http://127.0.0.1:24884")
      let t = StatusTarget(provider: "github", repository: "o/r", secret: "GH", apiUrl: "http://127.0.0.1:24884")
      check prHead(t, "tok-1", 7) == "dddddddddddddddddddddddddddddddddddddddd"
      withLock lock: check pulls[^1] == "/repos/o/r/pulls/7 Bearer tok-1"
      check prHead(StatusTarget(provider: "github", repository: "o/r", apiUrl: "http://127.0.0.1:1"), "x", 7) == ""
      delEnv("CINIM_STATUS_API_URLS")
    test "the webhook secret is part of the status setting, and a bad one is refused":
      check c.setStatusTarget(app, %*{"provider": "github", "repository": "o/r", "secret": "GH", "webhook_secret": "GH_HOOK", "api_url": "https://api.github.com"}) == ""
      check c.statusTargetOf(app).webhookSecret == "GH_HOOK"
      check c.setStatusTarget(app, %*{"provider": "github", "repository": "o/r", "secret": "GH", "webhook_secret": "a b"}) != ""
      check c.setStatusTarget(app, newJNull()) == ""
