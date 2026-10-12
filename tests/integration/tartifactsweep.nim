## DAT-006: the sweep of the artifacts (core/artifactsweep.nim), against a real rqlite and a store in memory. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, tables, strutils, times]
import common/rqlite
import core/[schema, scheduler, storagebackend, artifactsweep]

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
      let r = co.createRun("p", "return 1", "t1", defaultProfile)
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
