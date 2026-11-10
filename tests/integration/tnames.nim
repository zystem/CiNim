## The name of a trigger is unique in its project and the name of a webhook in its scope (the organisation or a project), not in the whole organisation (the owner, 2026-11-10): two projects may both
## have a trigger `nightly`. Against a real rqlite; needs CINIM_RQLITE_URL.
import std/[unittest, json, os, times, strutils]
import common/rqlite
import core/[schema, groups, triggers, webhooks]

let url = getEnv("CINIM_RQLITE_URL")

suite "names of triggers and webhooks are unique in their project or scope":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let slug = "nm" & newId()[^6 .. ^1].toLowerAscii
    let org = c.addOrganization(slug, "N")
    let now = getTime().toUnix()
    let a = c.createProject(org, "a", "https://example.test/a.git", now)
    let b = c.createProject(org, "b", "https://example.test/b.git", now)
    check a.error.len == 0 and b.error.len == 0
    proc trig(name, project: string): TriggerSpec =
      TriggerSpec(name: name, kind: "schedule", schedule: "0 1 * * *", groupPath: project, concurrency: "parallel", enabled: true)

    test "two projects both have a trigger `nightly`; one project cannot have it twice":
      discard c.createTrigger(org, trig("nightly", "a"), now, a.id)
      check c.nameTaken(org, a.id, "nightly") and not c.nameTaken(org, b.id, "nightly")
      discard c.createTrigger(org, trig("nightly", "b"), now, b.id)                                   # the other project: allowed
      check c.nameTaken(org, b.id, "nightly")
      expect RqError:
        discard c.createTrigger(org, trig("nightly", "a"), now, a.id)                                  # the same project: the index refuses
      check c.listTriggers(org).len == 2
    test "a webhook name is unique in its scope: the organisation has one `ops` and each project too":
      proc hook(name, project: string): WebhookSpec =
        WebhookSpec(name: name, url: "http://ci.lan:8080/in", groupPath: project, events: @["run.finished"], enabled: true)
      discard c.createWebhook(org, hook("ops", ""), "", now)
      discard c.createWebhook(org, hook("ops", "a"), a.id, now)
      check c.webhookNameTaken(org, "", "ops") and c.webhookNameTaken(org, a.id, "ops") and not c.webhookNameTaken(org, b.id, "ops")
      expect RqError:
        discard c.createWebhook(org, hook("ops", "a"), a.id, now)
