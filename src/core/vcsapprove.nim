## D-100: a run that waits for approval (D-93) is approved or rejected from the pull request that made it, by the people who review there: a comment `/approve` or `/reject`, a review that
## approves or asks for changes (GitHub), a comment or the approval of the merge request (GitLab). The host calls `POST /api/v1/vcs/{organization}/{project}` with a secret of its own
## (the project\'s `status.webhook_secret`: an HMAC-SHA256 of the body for GitHub, the token itself for GitLab); the login of the host is turned into an account by the table of identities that
## an administrator of the organisation keeps, and then it is the same as pressing the button: the account must hold `run.approve` for the run, must not be the one who started it, and answers once.
import std/[json, strutils, httpclient, uri]
import crunchy
import ../common/[rqlite, ctrlauth]
import apiauth, audit, prstatus, scheduler

type VcsEvent* = object
  relevant*: bool                     ## the event says approve or reject
  repository*, login*, sha*, command*, comment*: string          ## command: approve | reject
  prNumber*: int64                    ## GitHub comments carry no commit: it is asked of the host by the number

func hexOf(a: openArray[byte]): string =
  const d = "0123456789abcdef"
  for b in a:
    result.add d[int(b shr 4)]
    result.add d[int(b and 15)]

proc verifyGithub*(secret, body, header: string): bool =
  ## `X-Hub-Signature-256: sha256=<hex of HMAC-SHA256(secret, body)>`
  if secret.len == 0 or not header.startsWith("sha256="): return false
  constantTimeEqual(header[7 .. ^1].toLowerAscii, hexOf(hmacSha256(secret, body)))

func verifyGitlab*(secret, header: string): bool = secret.len > 0 and constantTimeEqual(header, secret)

func commandOf*(comment: string): string =
  ## the first line of a comment, `/approve` or `/reject` (any case), alone or with words after it
  let first = comment.strip.splitLines()[0].strip.toLowerAscii
  let word = first.split({' ', '\t'})[0]
  if word == "/approve": "approve" elif word == "/reject": "reject" else: ""

proc parseGithub*(event: string; j: JsonNode): VcsEvent =
  if j == nil or j.kind != JObject: return
  result.repository = j{"repository"}{"full_name"}.getStr
  case event
  of "issue_comment":
    if j{"action"}.getStr != "created" or j{"issue"}{"pull_request"}.isNil: return
    result.command = commandOf(j{"comment"}{"body"}.getStr)
    result.comment = j{"comment"}{"body"}.getStr
    result.login = j{"comment"}{"user"}{"login"}.getStr
    result.prNumber = j{"issue"}{"number"}.getBiggestInt
  of "pull_request_review":
    if j{"action"}.getStr != "submitted": return
    result.command = case j{"review"}{"state"}.getStr.toLowerAscii
      of "approved": "approve"
      of "changes_requested": "reject"
      else: ""
    result.comment = j{"review"}{"body"}.getStr
    result.login = j{"review"}{"user"}{"login"}.getStr
    result.sha = j{"pull_request"}{"head"}{"sha"}.getStr
  else: return
  result.relevant = result.command.len > 0 and result.login.len > 0

proc parseGitlab*(event: string; j: JsonNode): VcsEvent =
  if j == nil or j.kind != JObject: return
  result.repository = j{"project"}{"path_with_namespace"}.getStr
  result.login = j{"user"}{"username"}.getStr
  case event
  of "Note Hook":
    if j{"object_attributes"}{"noteable_type"}.getStr != "MergeRequest": return
    result.command = commandOf(j{"object_attributes"}{"note"}.getStr)
    result.comment = j{"object_attributes"}{"note"}.getStr
    result.sha = j{"merge_request"}{"last_commit"}{"id"}.getStr
  of "Merge Request Hook":
    result.command = case j{"object_attributes"}{"action"}.getStr
      of "approved": "approve"
      of "unapproved": "reject"
      else: ""
    result.sha = j{"object_attributes"}{"last_commit"}{"id"}.getStr
  else: return
  result.relevant = result.command.len > 0 and result.login.len > 0

proc identityOf*(c: var RqClient; tenantId, provider, login: string): string =
  let v = c.query(%*[["SELECT user_name FROM vcs_identities WHERE tenant_id = ? AND provider = ? AND lower(login) = ?", tenantId, provider, login.toLowerAscii]])["results"][0]{"values"}
  if v != nil and v.len > 0: v[0][0].getStr else: ""

proc setIdentity*(c: var RqClient; tenantId, provider, login, user: string): string =
  if provider notin ["github", "gitlab"]: return "the provider is github or gitlab"
  if login.len < 1 or login.len > 100 or login.contains({' ', '/', '\n', '\''}): return "a login of the host is 1 to 100 characters with no space or slash"
  if not c.userRoles(user).found: return "no such user: " & user
  discard c.execute(%*[["INSERT INTO vcs_identities (tenant_id, provider, login, user_name) VALUES (?, ?, ?, ?) ON CONFLICT(tenant_id, provider, login) DO UPDATE SET user_name = excluded.user_name",
                        tenantId, provider, login.toLowerAscii, user]])

proc deleteIdentity*(c: var RqClient; tenantId, provider, login: string): bool =
  c.execute(%*[["DELETE FROM vcs_identities WHERE tenant_id = ? AND provider = ? AND lower(login) = ?", tenantId, provider, login.toLowerAscii]])["results"][0]{"rows_affected"}.getInt > 0

proc listIdentities*(c: var RqClient; tenantId: string): JsonNode =
  result = newJArray()
  let v = c.query(%*[["SELECT provider, login, user_name FROM vcs_identities WHERE tenant_id = ? ORDER BY provider, login", tenantId]])["results"][0]{"values"}
  if v != nil:
    for r in v: result.add %*{"provider": r[0].getStr, "login": r[1].getStr, "user": r[2].getStr}

proc prHead*(t: StatusTarget; token: string; number: int64): string =
  ## GitHub: the commit a pull request is at now (the comment of an event does not say it)
  try:
    let client = newHttpClient(timeout = 10000, headers = newHttpHeaders({"User-Agent": "cinim-core", "Accept": "application/vnd.github+json", "Authorization": "Bearer " & token}))
    defer: client.close()
    let r = client.get(t.apiUrl & "/repos/" & t.repository & "/pulls/" & $number)
    if r.code.int != 200: return
    parseJson(r.body){"head"}{"sha"}.getStr
  except CatchableError:
    ""

proc answerFromHost*(c: var RqClient; tenantId, slug, groupId, projectPath, provider: string; ev: VcsEvent; now: int64): tuple[status: int, body: JsonNode] =
  let user = c.identityOf(tenantId, provider, ev.login)
  if user.len == 0:
    c.record(now, "vcs:" & provider & ":" & ev.login, "run." & ev.command, projectPath, "denied", "no account is linked to this login")
    return (202, %*{"ignored": "no account of this organisation is linked to " & ev.login})
  let waiting = c.query(%*[["SELECT id, source_ref FROM runs WHERE group_id = ? AND state = 'WAITING' AND approval_required > 0 AND source_commit = ?", groupId, ev.sha]])["results"][0]{"values"}
  if waiting == nil or waiting.len == 0: return (202, %*{"ignored": "no run of this project waits for approval at " & ev.sha})
  let u = c.userRoles(user, now)
  var answers = newJArray()
  for w in waiting:
    let runId = w[0].getStr
    if not u.found or u.disabled or not u.grants.holdsRun("run.approve", slug, projectPath, RunFacts(own: false, ref0: w[1].getStr)):
      c.record(now, "user:" & user, "run." & ev.command, runId, "denied", "via " & provider & ": needs run.approve")
      answers.add %*{"run": runId, "outcome": "refused", "why": "the account " & user & " does not hold run.approve here"}
      continue
    let ans = c.answerApproval(runId, user, ev.command, ev.comment[0 ..< min(ev.comment.len, 500)], now)
    c.record(now, "user:" & user, "run." & ev.command, runId, (if ans.outcome in {aoGiven, aoApproved, aoRejected}: "ok" else: "denied"), "via " & provider & " as " & ev.login)
    answers.add %*{"run": runId, "outcome": $ans.outcome, "state": ans.state, "approvals": ans.have, "required": ans.required}
  (200, %*{"answers": answers})
