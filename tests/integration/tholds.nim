## DAT-006: a legal hold on a run (core/holds.nim), against a real rqlite and a store in memory: placed with a reason, released, listed; while it stands the sweep of the
## artifacts does not take the run's artifacts and the core does not release its volume. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, tables, strutils, times, sequtils]
import common/rqlite
import core/[schema, scheduler, storagebackend, artifactsweep, runstorage, holds]

type MemStore = ref object of ObjectBackend
  objects: Table[string, string]

method deleteObject(b: MemStore; key: string): Outcome =
  if key notin b.objects: return fail("no such object")
  b.objects.del key
  done()

let url = getEnv("CINIM_RQLITE_URL")

suite "DAT-006 a legal hold on a run":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let sfx = newId()[^6 .. ^1].toLowerAscii
    var n = 0
    let day = 86400'i64
    let now = getTime().toUnix()
    proc newOrg(): tuple[id, profile: string] =
      inc n
      let id = c.addOrganization("h" & $n & sfx, "H")
      (id, c.ensureOrganizationProfile(id, "cinim-001-h" & $n & sfx))
    proc endedRun(o: tuple[id, profile: string]; state = "SUCCEEDED"; endedAgo = 40 * day): string =
      result = co.createRun("return 1", o.id, o.profile)
      discard c.execute(%*[["UPDATE runs SET state = ?, updated_at = ? WHERE id = ?", state, $(now - endedAgo), result]])
    proc addArtifact(be: MemStore; tenant, run, path: string; age: int64): string =
      let key = tenant & "/" & run & "/" & path
      let id = newId()
      discard c.execute(%*[["INSERT INTO artifacts (id, tenant_id, run_id, step_ordinal, path, s3_key, size, sha256, state, created_at) VALUES (?, ?, ?, 0, ?, ?, 1, 'x', 'stored', ?)",
        id, tenant, run, path, key, now - age]])
      be.objects[key] = "data"
      id
    proc rowExists(id: string): bool =
      c.query(%*[["SELECT count(*) FROM artifacts WHERE id = ?", id]])["results"][0]["values"][0][0].getInt > 0

    test "a hold needs a reason, is placed once, and its first reason stands; it is released and listed":
      let o = newOrg()
      let r = endedRun(o)
      check c.placeHold(r, o.id, "  ", "ann", now).error.len > 0
      check c.placeHold(r, o.id, "x".repeat(1001), "ann", now).error.len > 0
      check not c.holdOf(r).held
      let first = c.placeHold(r, o.id, "case 4411", "ann", now)
      check first.error == "" and first.placed
      let again = c.placeHold(r, o.id, "another reason", "bob", now + 5)
      check again.error == "" and not again.placed
      let h = c.holdOf(r)
      check h.held and h.hold.reason == "case 4411" and h.hold.placedBy == "ann"
      check c.listHolds(o.id).len == 1 and c.heldCount(o.id) == 1
      check c.releaseHold(r) and not c.releaseHold(r) and not c.holdOf(r).held and c.heldCount(o.id) == 0
    test "the sweep does not take the artifacts of a run under a hold, whatever their age, and takes them once the hold is released":
      let o = newOrg()
      let be = MemStore(objects: initTable[string, string]())
      let held = endedRun(o)
      let free = endedRun(o)
      let a1 = be.addArtifact(o.id, held, "old.txt", 40 * day)
      let a2 = be.addArtifact(o.id, free, "old.txt", 40 * day)
      check c.placeHold(held, o.id, "audit", "ann", now).placed
      discard c.sweepArtifacts(be, now, 30 * day)
      check rowExists(a1) and (o.id & "/" & held & "/old.txt") in be.objects
      check not rowExists(a2) and (o.id & "/" & free & "/old.txt") notin be.objects
      check c.releaseHold(held)
      discard c.sweepArtifacts(be, now, 30 * day)
      check not rowExists(a1) and (o.id & "/" & held & "/old.txt") notin be.objects
    test "the volume of a run under a hold is not released, and is once the hold is gone":
      let o = newOrg()
      putEnv("CINIM_STORAGE_RETENTION_SUCCEEDED", "0")
      putEnv("CINIM_STORAGE_RETENTION_FAILED", "0")
      runstorage.coreStartedAt = 0
      let held = endedRun(o, "FAILED", 100000)
      let free = endedRun(o, "SUCCEEDED", 5)
      check c.placeHold(held, o.id, "audit", "ann", now).placed
      let named = c.releasableRuns(o.profile, now, runstorage.retentionFromEnv())
      check free in named and held notin named
      check c.releaseHold(held)
      check held in c.releasableRuns(o.profile, now, runstorage.retentionFromEnv())
    test "the run's view says it is held, and by whom and why":
      let o = newOrg()
      let r = endedRun(o)
      check not co.getRun(r).hasKey("hold")
      check c.placeHold(r, o.id, "regulator's request", "ann", now).placed
      let view = co.getRun(r)
      check view["hold"]["reason"].getStr == "regulator's request" and view["hold"]["placed_by"].getStr == "ann"
    test "an organisation is listed with its holds only":
      let a = newOrg()
      let b = newOrg()
      let ra = endedRun(a)
      let rb = endedRun(b)
      check c.placeHold(ra, a.id, "x", "ann", now).placed and c.placeHold(rb, b.id, "y", "ann", now).placed
      check c.listHolds(a.id).len == 1 and c.listHolds(a.id)[0].runId == ra and c.heldCount(b.id) == 1
      check c.listOrganizationsFull().filterIt(it.slug == "h" & $(n - 1) & sfx)[0].held == 1
