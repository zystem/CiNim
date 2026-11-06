## D-111: outbound webhooks against a real rqlite: the rows of a webhook, the events that the runs of an organisation or of a project give (each written down once, however often the beat looks), and the
## delivery (a signature when there is a secret, a refusal tried again later, an address the shard does not allow never called). The sending itself is a stand-in here. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, sequtils, algorithm]
import common/rqlite
import core/[schema, scheduler, groups, webhooks]

let url = getEnv("CINIM_RQLITE_URL")

var posted: seq[tuple[url, body: string; headers: seq[(string, string)]]]
var answer = (ok: true, error: "")

proc fakePost(u, body: string; headers: seq[(string, string)]): tuple[ok: bool, error: string] {.gcsafe.} =
  {.cast(gcsafe).}:
    posted.add (u, body, headers)
    answer

suite "D-111 webhooks":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let profile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: profile, namespace: "cinim-default-ns", orgPrefix: "cinim-001", orgShard: "")
    let sfx = newId()[^6 .. ^1].toLowerAscii
    var slug, org, other = ""
    var seq0 = 0
    proc fresh() =
      ## every test has an organisation of its own (and another to be foreign to it): the runs of one test are not the events of the next
      inc seq0
      slug = "wh" & sfx & $seq0
      org = c.addOrganization(slug, "Webhooks")
      other = c.addOrganization("wo" & sfx & $seq0, "Another organisation")
    let allowed = @["ci.lan", "10.1.2.3:9000"]
    let t0 = getTime().toUnix()
    var n = 0
    proc spec(events: seq[string] = @allEvents; groupPath = ""; secret = ""; enabled = true): WebhookSpec =
      inc n
      WebhookSpec(name: "w" & $n, url: "http://ci.lan:8080/in", secret: secret, groupPath: groupPath, events: events, enabled: enabled)
    proc make(s: WebhookSpec; tenant = org; groupId = ""; at = t0): WebhookRow =
      let id = c.createWebhook(tenant, s, groupId, at)
      c.getWebhook(tenant, id).row
    proc run(group = ""; tenant = org): string = co.createRun("return 1", tenant, profile, groupId = group)
    proc setState(r, state: string) = discard c.execute(%*[["UPDATE runs SET state = ?, fail_code = ?, fail_message = ? WHERE id = ?", state, (if state == "FAILED": "script_error" else: ""), (if state == "FAILED": "tests failed" else: ""), r]])
    proc failStep(r: string; ordinal, code: int) =
      discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, queued_at, exit_code, termination, attempt) VALUES (?, ?, 'j', ?, 'sh', 'FAILED', ?, 'alpine', 'false', '0', ?, 'timeout', 1)",
                            newId(), r, ordinal, profile, code]])
    proc rowsOf(w: WebhookRow): seq[tuple[run, event, key: string; sent: bool]] =
      let v = c.query(%*[["SELECT run_id, event, ekey, sent_at FROM webhook_deliveries WHERE webhook_id = ? ORDER BY created_at, event, ekey", w.id]])["results"][0]{"values"}
      if v != nil:
        for x in v: result.add (x[0].getStr, x[1].getStr, x[2].getStr, x[3].getInt > 0)
    proc bodyOf(w: WebhookRow; event: string): JsonNode =
      parseJson(c.query(%*[["SELECT body FROM webhook_deliveries WHERE webhook_id = ? AND event = ? ORDER BY created_at LIMIT 1", w.id, event]])["results"][0]{"values"}[0][0].getStr)
    proc secretNone(w: WebhookRow): string {.gcsafe.} = ""
    proc secretKey(w: WebhookRow): string {.gcsafe.} = "s3cret"

    test "a webhook is kept with its events, its secret's name and its scope; it is found by the organisation that owns it, listed, changed and deleted":
      fresh()
      let w = make(spec(@["run.finished"], secret = "HOOK_KEY"))
      check w.slug == slug and w.events == @["run.finished"] and w.secret == "HOOK_KEY" and w.enabled and w.groupPath == ""
      check c.listWebhooks(org).anyIt(it.id == w.id) and not c.listWebhooks(other).anyIt(it.id == w.id)
      check not c.getWebhook(other, w.id).found
      check c.webhookNameTaken(org, w.name) and not c.webhookNameTaken(other, w.name) and c.countWebhooks(org) >= 1
      var s2 = spec(@["run.started", "step.failed"], secret = "")
      s2.url = "https://hooks.example.org/x"
      s2.enabled = false
      check c.updateWebhook(org, w.id, s2)
      let u = c.getWebhook(org, w.id).row
      check u.url == "https://hooks.example.org/x" and u.events == @["run.started", "step.failed"] and u.secret == "" and not u.enabled and u.name == w.name
      check not c.updateWebhook(other, w.id, s2)
      check c.deleteWebhook(org, w.id) and not c.getWebhook(org, w.id).found and not c.deleteWebhook(org, w.id)

    test "a run that started is one event, a run that ended another; looking again writes nothing, and a run that is still queued gives none":
      fresh()
      let w = make(spec())
      let r = run()
      check c.queueEvents(getTime().toUnix(), "https://ui.example.org") == 0            # queued: nothing yet
      setState(r, "RUNNING")
      check c.queueEvents(getTime().toUnix(), "https://ui.example.org") >= 1
      check rowsOf(w).mapIt(it.event) == @["run.started"]
      check c.queueEvents(getTime().toUnix(), "https://ui.example.org") == 0            # the same look again
      setState(r, "OK")
      discard c.queueEvents(getTime().toUnix(), "https://ui.example.org")
      check rowsOf(w).mapIt(it.event).sorted == @["run.finished", "run.started"]
      check c.queueEvents(getTime().toUnix(), "https://ui.example.org") == 0
      let b = bodyOf(w, "run.started")
      check b["run"]["id"].getStr == r and b["run"]["state"].getStr == "RUNNING" and b["organization"].getStr == slug
      check b["run"]["link"].getStr == "https://ui.example.org/runs/" & r
      check bodyOf(w, "run.finished")["run"]["state"].getStr == "OK"
      discard c.deleteWebhook(org, w.id)

    test "a run that is seen only when it has ended still gives both events, and the failure is told":
      fresh()
      let w = make(spec())
      let r = run()
      setState(r, "FAILED")
      discard c.queueEvents(getTime().toUnix(), "")
      check rowsOf(w).mapIt(it.event).sorted == @["run.finished", "run.started"]
      let f = bodyOf(w, "run.finished")
      check f["run"]["state"].getStr == "FAILED" and f["failure"]["code"].getStr == "script_error" and "tests failed" in f["failure"]["message"].getStr
      check not f["run"].hasKey("link")
      discard c.deleteWebhook(org, w.id)

    test "every failed step is an event of its own, once, with its ids and its exit code":
      fresh()
      let w = make(spec(@["step.failed"]))
      let r = run()
      setState(r, "RUNNING")
      failStep(r, 28311556, 124)
      failStep(r, 28311557, 1)
      discard c.queueEvents(getTime().toUnix(), "")
      check rowsOf(w).len == 2 and rowsOf(w).allIt(it.event == "step.failed")
      check c.queueEvents(getTime().toUnix(), "") == 0
      let steps = c.query(%*[["SELECT body FROM webhook_deliveries WHERE webhook_id = ? ORDER BY ekey", w.id]])["results"][0]["values"].mapIt(parseJson(it[0].getStr))
      check steps[0]["step"]["job_id"].getStr == "0v" and steps[0]["step"]["step_id"].getStr == "0004" and steps[0]["step"]["exit_code"].getInt == 124
      failStep(r, 28311558, 2)                                                           # one more later: one more event
      check c.queueEvents(getTime().toUnix(), "") == 1
      discard c.deleteWebhook(org, w.id)

    test "only the events the webhook chose, only while it is on, and only the runs made after it was":
      fresh()
      let only = make(spec(@["run.finished"]))
      let off = make(spec(enabled = false))
      let late = make(spec(), at = getTime().toUnix() + 1000)                            # made "in the future": the runs below are before it
      let r = run()
      setState(r, "OK")
      discard c.queueEvents(getTime().toUnix(), "")
      check rowsOf(only).mapIt(it.event) == @["run.finished"]
      check rowsOf(off).len == 0 and rowsOf(late).len == 0
      for w in [only, off, late]: discard c.deleteWebhook(org, w.id)

    test "a webhook of one organisation sees the runs of that organisation only":
      fresh()
      let w = make(spec())
      let foreign = run(tenant = other)
      setState(foreign, "OK")
      discard c.queueEvents(getTime().toUnix(), "")
      check rowsOf(w).len == 0
      discard c.deleteWebhook(org, w.id)

    test "a webhook of a project sees the runs of that project and of the groups under it, and not those of the organisation or of another project":
      fresh()
      let team = c.createGroup(org, "team", t0)
      let sub = c.createGroup(org, "team/backend", t0)
      let rival = c.createGroup(org, "teamwork", t0)                                     # a name that only starts like it
      let w = make(spec(groupPath = "team"), groupId = team.id)
      let inTeam = run(team.id)
      let inSub = run(sub.id)
      let inRival = run(rival.id)
      let inOrg = run()
      for r in [inTeam, inSub, inRival, inOrg]: setState(r, "OK")
      discard c.queueEvents(getTime().toUnix(), "")
      let seen = rowsOf(w).mapIt(it.run).deduplicate
      check inTeam in seen and inSub in seen and inRival notin seen and inOrg notin seen
      check bodyOf(w, "run.started")["project"].getStr in ["team", "team/backend"]
      discard c.deleteWebhook(org, w.id)

    test "the due rows are posted: the address, the body as it was written, the event and the delivery in the headers; a row is sent once":
      fresh()
      let w = make(spec(@["run.finished"]))
      let r = run()
      setState(r, "OK")
      discard c.queueEvents(getTime().toUnix(), "")
      posted = @[]
      check c.deliverDue(getTime().toUnix(), fakePost, allowed, secretNone) == 1
      check posted.len == 1 and posted[0].url == "http://ci.lan:8080/in"
      check parseJson(posted[0].body)["run"]["id"].getStr == r
      let hs = posted[0].headers
      check ("Content-Type", "application/json") in hs and ("X-CiNim-Event", "run.finished") in hs and hs.anyIt(it[0] == "X-CiNim-Delivery" and it[1].len > 0)
      check not hs.anyIt(it[0] == "X-CiNim-Signature")                                    # no secret: no signature
      check rowsOf(w)[0].sent
      posted = @[]
      check c.deliverDue(getTime().toUnix(), fakePost, allowed, secretNone) == 0 and posted.len == 0
      discard c.deleteWebhook(org, w.id)

    test "a webhook with a secret signs the body with its value; a secret that cannot be had is not a reason to send unsigned: the row waits and is tried again":
      fresh()
      let w = make(spec(@["run.finished"], secret = "HOOK_KEY"))
      let r = run()
      setState(r, "OK")
      discard c.queueEvents(getTime().toUnix(), "")
      posted = @[]
      check c.deliverDue(getTime().toUnix(), fakePost, allowed, secretNone) == 0 and posted.len == 0
      check not rowsOf(w)[0].sent
      let later = getTime().toUnix() + 100
      check c.deliverDue(later, fakePost, allowed, secretKey) == 1
      check posted.len == 1 and ("X-CiNim-Signature", signature("s3cret", posted[0].body)) in posted[0].headers
      discard c.deleteWebhook(org, w.id)

    test "a refusal is tried again later and later, and given up after the last try; the row stays for a person to see":
      fresh()
      let w = make(spec(@["run.finished"]))
      let r = run()
      setState(r, "OK")
      discard c.queueEvents(getTime().toUnix(), "")
      answer = (false, "the receiver answered 503")
      var t = getTime().toUnix()
      posted = @[]
      check c.deliverDue(t, fakePost, allowed, secretNone) == 0 and posted.len == 1
      check c.deliverDue(t + 5, fakePost, allowed, secretNone) == 0 and posted.len == 1        # too soon: not asked again
      let d = c.query(%*[["SELECT attempts, next_at, last_error FROM webhook_deliveries WHERE webhook_id = ?", w.id]])["results"][0]["values"][0]
      check d[0].getInt == 1 and d[1].getBiggestInt >= t + 30 and "503" in d[2].getStr
      for i in 1 ..< maxAttempts:
        t += 4000
        discard c.deliverDue(t, fakePost, allowed, secretNone)
      check posted.len == maxAttempts
      t += 4000
      check c.deliverDue(t, fakePost, allowed, secretNone) == 0 and posted.len == maxAttempts   # no ninth try
      check not rowsOf(w)[0].sent
      answer = (true, "")
      discard c.deleteWebhook(org, w.id)

    test "an address the shard does not allow is never called, whatever the row says":
      fresh()
      let w = make(spec(@["run.finished"]))
      let r = run()
      setState(r, "OK")
      discard c.queueEvents(getTime().toUnix(), "")
      posted = @[]
      check c.deliverDue(getTime().toUnix(), fakePost, @["another.host"], secretNone) == 0 and posted.len == 0
      let d = c.query(%*[["SELECT attempts, last_error FROM webhook_deliveries WHERE webhook_id = ?", w.id]])["results"][0]["values"][0]
      check d[0].getInt == maxAttempts and "allow" in d[1].getStr
      discard c.deleteWebhook(org, w.id)

    test "a disabled webhook sends nothing that was waiting; a deleted one takes its rows with it":
      fresh()
      let w = make(spec(@["run.finished"]))
      let r = run()
      setState(r, "OK")
      discard c.queueEvents(getTime().toUnix(), "")
      var off = spec(@["run.finished"], enabled = false)
      off.url = w.url
      check c.updateWebhook(org, w.id, off)
      posted = @[]
      check c.deliverDue(getTime().toUnix(), fakePost, allowed, secretNone) == 0 and posted.len == 0
      check c.deleteWebhook(org, w.id)
      check c.query(%*[["SELECT count(*) FROM webhook_deliveries WHERE webhook_id = ?", w.id]])["results"][0]["values"][0][0].getInt == 0

    test "a ping, which a person asks for to see that the address answers, is a row that is sent at once":
      fresh()
      let w = make(spec())
      let id = c.queuePing(w, getTime().toUnix())
      check id.len > 0
      posted = @[]
      check c.deliverDue(getTime().toUnix(), fakePost, allowed, secretNone) >= 1
      check posted.anyIt(parseJson(it.body)["event"].getStr == "ping" and parseJson(it.body)["delivery"].getStr == id)
      discard c.deleteWebhook(org, w.id)

    test "what is done and old is removed, and what waits is kept":
      fresh()
      let w = make(spec(@["run.finished"]))
      let r = run()
      setState(r, "OK")
      discard c.queueEvents(getTime().toUnix(), "")
      discard c.execute(%*[["UPDATE webhook_deliveries SET created_at = created_at - 10 * 86400, sent_at = 1 WHERE webhook_id = ?", w.id]])
      check c.pruneDeliveries(getTime().toUnix()) >= 1
      check rowsOf(w).len == 0
      discard c.deleteWebhook(org, w.id)
