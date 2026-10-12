## DAT-006: the sweep of the artifacts (core/artifactsweep.nim), against a real rqlite and a store in memory. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, tables, strutils, times]
import common/rqlite
import core/[schema, scheduler, storagebackend, artifactsweep, objectstore, retrypolicy]

type MemStore = ref object of ObjectBackend
  objects: Table[string, string]
  uploads: Table[string, string]           # upload id -> key
  down: bool                               # the store does not answer

method deleteObject(b: MemStore; key: string): Outcome =
  if b.down: return fail("connection refused", retry = true)
  if key notin b.objects: return fail("no such object")
  b.objects.del key
  done()
method abortMultipart(b: MemStore; key, uploadId: string): Outcome =
  if b.down: return fail("connection refused", retry = true)
  if uploadId notin b.uploads: return fail("NoSuchUpload")
  b.uploads.del uploadId
  done()

let url = getEnv("CINIM_RQLITE_URL")

suite "DAT-006 the sweep of the artifacts":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let day = 86400'i64
    let now = getTime().toUnix()
    proc newStore(): MemStore = MemStore(objects: initTable[string, string](), uploads: initTable[string, string]())
    proc newRun(state = "SUCCEEDED"): string =
      let r = co.createRun("return 1", "t1", defaultProfile)
      discard c.execute(%*[["UPDATE runs SET state = ? WHERE id = ?", state, r]])
      r
    proc add(be: MemStore; run, path, state: string; age: int64; uploadId = ""): string =
      let key = "t1/" & run & "/" & path
      let id = newId()
      discard c.execute(%*[["INSERT INTO artifacts (id, tenant_id, run_id, step_ordinal, path, s3_key, size, sha256, state, created_at, upload_id) VALUES (?, 't1', ?, 0, ?, ?, 1, 'x', ?, ?, ?)",
        id, run, path, key, state, now - age, uploadId]])
      if state == "stored": be.objects[key] = "data"
      if uploadId.len > 0: be.uploads[uploadId] = key
      id
    proc rowExists(id: string): bool =
      c.query(%*[["SELECT count(*) FROM artifacts WHERE id = ?", id]])["results"][0]["values"][0][0].getInt > 0

    test "an artifact older than the retention, of a run that has ended, is deleted from the store and from the database; a younger one stays":
      let be = newStore()
      let r = newRun()
      let old = be.add(r, "old.txt", "stored", 40 * day)
      let young = be.add(r, "young.txt", "stored", 2 * day)
      let rep = c.sweepArtifacts(be, now, 30 * day)
      check rep.expired >= 1
      check not rowExists(old) and rowExists(young)
      check "t1/" & r & "/old.txt" notin be.objects and "t1/" & r & "/young.txt" in be.objects
    test "the artifacts of a run that is still under way are never taken, however old":
      let be = newStore()
      let r = newRun("RUNNING")
      let a = be.add(r, "a.txt", "stored", 400 * day)
      discard c.sweepArtifacts(be, now, 30 * day)
      check rowExists(a) and be.objects.len == 1
    test "a retention of 0 or less keeps for ever":
      let be = newStore()
      let r = newRun()
      let a = be.add(r, "a.txt", "stored", 4000 * day)
      discard c.sweepArtifacts(be, now, 0)
      check rowExists(a)
    test "an upload that was never finished is aborted in the store and forgotten, after the time allowed; one that is under way now is not touched":
      let be = newStore()
      let r = newRun("RUNNING")
      let stale = be.add(r, "big.bin", "uploading", 3 * day, uploadId = "up-stale-" & r)
      let fresh = be.add(r, "next.bin", "uploading", 60, uploadId = "up-fresh-" & r)
      let rep = c.sweepArtifacts(be, now, 30 * day, abandonAfter = day)
      check rep.abandoned >= 1
      check not rowExists(stale) and rowExists(fresh)
      check ("up-stale-" & r) notin be.uploads and ("up-fresh-" & r) in be.uploads
    test "an object the store does not have is as good as deleted: the row goes":
      let be = newStore()
      let r = newRun()
      let a = be.add(r, "gone.txt", "stored", 40 * day)
      be.objects.clear()
      discard c.sweepArtifacts(be, now, 30 * day)
      check not rowExists(a)
    test "a store that does not answer leaves everything for the next pass, and the pass after it does the work":
      let be = newStore()
      let r = newRun()
      let a = be.add(r, "a.txt", "stored", 40 * day)
      let u = be.add(r, "b.bin", "uploading", 3 * day, uploadId = "up-down-" & r)
      be.down = true
      let rep = c.sweepArtifacts(be, now, 30 * day)
      check rep.failed >= 2 and rowExists(a) and rowExists(u)
      be.down = false
      discard c.sweepArtifacts(be, now, 30 * day)
      check not rowExists(a) and not rowExists(u)
    test "the artifacts of a run that is not in the database any more are deleted, stored or half uploaded":
      let be = newStore()
      let ghost = "s1_ghost-" & newId()
      let a = be.add(ghost, "a.txt", "stored", 60)
      let b = be.add(ghost, "b.bin", "uploading", 60, uploadId = "up-ghost-" & ghost)
      let rep = c.sweepArtifacts(be, now, 30 * day)
      check rep.orphans >= 2
      check not rowExists(a) and not rowExists(b)
      check be.objects.len == 0 and be.uploads.len == 0

    test "an organisation's own retention (days in its profile) is its own: shorter than the shard's, it expires sooner; longer, it keeps; 0 is the shard's":
      let be = newStore()
      var s7 = defaultSettings()
      s7.artifactRetentionDays = 7
      var s90 = defaultSettings()
      s90.artifactRetentionDays = 90
      let org7 = c.addOrganization("rt7" & newId()[^6 .. ^1].toLowerAscii, "R7")
      let org90 = c.addOrganization("rt90" & newId()[^6 .. ^1].toLowerAscii, "R90")
      let p7 = c.ensureOrganizationProfile(org7, "cinim-001-rt7-" & newId()[^6 .. ^1].toLowerAscii)
      let p90 = c.ensureOrganizationProfile(org90, "cinim-001-rt90-" & newId()[^6 .. ^1].toLowerAscii)
      co.setProfileSettings(s7, p7)
      co.setProfileSettings(s90, p90)
      let r7 = co.createRun("return 1", org7, p7)
      let r90 = co.createRun("return 1", org90, p90)
      let rDefault = newRun()
      for r in [r7, r90]: discard c.execute(%*[["UPDATE runs SET state = 'SUCCEEDED' WHERE id = ?", r]])
      let a7 = be.add(r7, "a.txt", "stored", 10 * day)             # 10 days old: past 7, within 90 and within the shard's 30
      let a90 = be.add(r90, "a.txt", "stored", 40 * day)           # 40 days old: past the shard's 30, within 90
      let aDef = be.add(rDefault, "a.txt", "stored", 40 * day)     # 40 days old, no setting: the shard's 30
      discard c.sweepArtifacts(be, now, 30 * day)
      check not rowExists(a7) and rowExists(a90) and not rowExists(aDef)
    test "an organisation with a retention of its own keeps its artifacts even when the shard keeps nothing for ever... and the shard's 0 still means for ever for the rest":
      let be = newStore()
      let org = c.addOrganization("rtk" & newId()[^6 .. ^1].toLowerAscii, "RK")
      let p = c.ensureOrganizationProfile(org, "cinim-001-rtk-" & newId()[^6 .. ^1].toLowerAscii)
      var s = defaultSettings()
      s.artifactRetentionDays = 5
      co.setProfileSettings(s, p)
      let mine = co.createRun("return 1", org, p)
      discard c.execute(%*[["UPDATE runs SET state = 'SUCCEEDED' WHERE id = ?", mine]])
      let other = newRun()
      let a = be.add(mine, "a.txt", "stored", 6 * day)
      let b = be.add(other, "a.txt", "stored", 4000 * day)
      discard c.sweepArtifacts(be, now, 0)                         # the shard keeps for ever
      check not rowExists(a) and rowExists(b)

suite "DAT-006 the quota of an organisation":
  if url.len > 0:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let now = getTime().toUnix()
    let sfx = newId()[^6 .. ^1].toLowerAscii
    proc add(org, run, path: string; size: int64; state = "stored") =
      discard c.execute(%*[["INSERT INTO artifacts (id, tenant_id, run_id, step_ordinal, path, s3_key, size, sha256, state, created_at) VALUES (?, ?, ?, 0, ?, ?, ?, 'x', ?, ?)",
        newId(), org, run, path, org & "/" & run & "/" & path, size, state, now]])
    test "the quota is the profile's setting of the organisation the run belongs to, 0 when there is none; the bytes are the organisation's, stored and under way, without the file a new one replaces":
      let org = c.addOrganization("qa" & sfx, "QA")
      let other = c.addOrganization("qb" & sfx, "QB")
      let p = c.ensureOrganizationProfile(org, "cinim-001-qa-" & sfx)
      var s = defaultSettings()
      s.artifactQuotaBytes = 5 * 1024 * 1024
      co.setProfileSettings(s, p)
      let r1 = co.createRun("return 1", org, p)
      let r2 = co.createRun("return 1", org, p)
      let rOther = co.createRun("return 1", other, c.ensureOrganizationProfile(other, "cinim-001-qb-" & sfx))
      check c.orgQuota(r1) == 5 * 1024 * 1024 and c.orgQuota(rOther) == 0
      add(org, r1, "a.bin", 2 * 1024 * 1024)
      add(org, r2, "b.bin", 1024 * 1024, "uploading")
      add(other, rOther, "c.bin", 100 * 1024 * 1024)
      check c.orgBytes(org, r1, "new.bin") == 3 * 1024 * 1024               # the other organisation's bytes are not counted
      check c.orgBytes(org, r1, "a.bin") == 1024 * 1024                      # a file this one replaces is not counted
      check c.orgBytes(org, r2, "new.bin") == 3 * 1024 * 1024
