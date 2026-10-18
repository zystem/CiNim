## DAT-004: the cache between runs, the core's side, against a real rqlite and a store in memory: the choice of the entry (the key, else the latest a restore key names), the
## immutability of a key, what a step may find and save, the room (least recently used go first), the sweep, and the requests of the channel (cache_find, put_*, get_block).
## Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, tables, strutils, times, sequtils]
import checksums/sha2
import common/rqlite
import common/storagebackend
import core/[schema, cachestore, objectstore, artifactingest, groups, storageclient]
import common/storagetoken

type MemStore = ref object of ObjectBackend
  direct: seq[PartRecord]                       ## what the storage module would report for a direct upload
  objects: Table[string, string]
  uploads: Table[string, tuple[key: string, parts: Table[int, string]]]
  next: int

method uploadedParts(b: MemStore; key, uploadId: string): tuple[res: Outcome, known: bool, parts: seq[PartRecord]] = (done(), true, b.direct)
method putObject(b: MemStore; key, data: string): Outcome =
  b.objects[key] = data
  done()
method createMultipart(b: MemStore; key: string): tuple[res: Outcome, uploadId: string] =
  inc b.next
  let id = "up" & $b.next
  b.uploads[id] = (key, initTable[int, string]())
  (done(), id)
method uploadPart(b: MemStore; key, uploadId: string; part: int; data: string): tuple[res: Outcome, etag: string] =
  b.uploads[uploadId].parts[part] = data
  (done(), "etag" & $part)
method completeMultipart(b: MemStore; key, uploadId: string; parts: seq[(int, string)]): Outcome =
  var all = ""
  var sent = true
  for (n, _) in parts:
    if n notin b.uploads[uploadId].parts: sent = false          # the parts went straight to the module (D-61): the test put the object there
    else: all.add b.uploads[uploadId].parts[n]
  if sent: b.objects[key] = all
  b.uploads.del uploadId
  done()
method abortMultipart(b: MemStore; key, uploadId: string): Outcome =
  b.uploads.del uploadId
  done()
method readRange(b: MemStore; key: string; offset, length: int64): tuple[res: Outcome, data: string] =
  if key notin b.objects: return (fail("no such object"), "")
  (done(), b.objects[key][int(offset) ..< int(min(offset + length, b.objects[key].len))])
method objectSize(b: MemStore; key: string): tuple[res: Outcome, size: int64] =
  if key notin b.objects: return (fail("no such object"), -1'i64)
  (done(), int64(b.objects[key].len))
method deleteObject(b: MemStore; key: string): Outcome =
  if key notin b.objects: return fail("no such object")
  b.objects.del key
  done()

func shaOf(s: string): string =
  for c in secureHash(Sha_256, s): result.add toHex(ord(c), 2).toLowerAscii

let url = getEnv("CINIM_RQLITE_URL")

suite "DAT-004 the cache between runs":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let sfx = newId()[^6 .. ^1].toLowerAscii
    var n = 0
    let now = getTime().toUnix()
    proc tenant(): string =
      inc n
      "t" & $n & sfx
    proc store(): MemStore = MemStore(objects: initTable[string, string](), uploads: initTable[string, tuple[key: string, parts: Table[int, string]]]())
    proc save(be: MemStore; t, scope, key, data: string; at: int64 = now) =
      let s3 = objectKeyOf(t, scope, key)
      check c.beginEntry(newId(), t, scope, key, s3, int64(data.len), shaOf(data), "stored", "", at)
      be.objects[s3] = data

    test "the exact key is found; failing that the latest entry whose key starts with a restore key; a miss is a miss":
      let t = tenant()
      let be = store()
      be.save(t, "", "deps-a1", "one", now - 300)
      be.save(t, "", "deps-b2", "two", now - 200)
      be.save(t, "", "other-x", "three", now - 100)
      check c.findEntry(t, "", "deps-a1", @[], now).key == "deps-a1"
      check c.findEntry(t, "", "deps-zz", @["deps-"], now).key == "deps-b2"                  # the latest of those that start with deps-
      check c.findEntry(t, "", "nope-1", @["nope-", "other-"], now).key == "other-x"         # the restore keys in order
      check not c.findEntry(t, "", "nope-1", @["nope-"], now).found
      check c.findEntry(t, "", "deps-a1", @[], now).found
    test "a restore key is a prefix, not a pattern: % and _ in it mean themselves":
      let t = tenant()
      let be = store()
      be.save(t, "", "a_b-1", "x")
      be.save(t, "", "aXb-2", "y")
      check c.findEntry(t, "", "zz", @["a_b"], now).key == "a_b-1"
      check not c.findEntry(t, "", "zz", @["a%"], now).found
    test "a group sees its own caches only, and so does an organisation":
      let t = tenant()
      let u = tenant()
      let be = store()
      be.save(t, "g1", "k", "in g1")
      check c.findEntry(t, "g1", "k", @[], now).found
      check not c.findEntry(t, "g2", "k", @[], now).found and not c.findEntry(t, "", "k", @[], now).found and not c.findEntry(u, "g1", "k", @[], now).found
    test "a key is immutable: a second begin for the same key gives way, stored or still being uploaded":
      let t = tenant()
      check c.beginEntry(newId(), t, "", "k", "obj", 3, "sha", "uploading", "up1", now)
      check not c.beginEntry(newId(), t, "", "k", "obj2", 3, "sha", "uploading", "up2", now)
      check c.uploadingEntry(t, "", "k").found and c.markEntryStored(t, "", "k") and not c.uploadingEntry(t, "", "k").found
      check not c.beginEntry(newId(), t, "", "k", "obj3", 3, "sha", "stored", "", now)
    test "room: the entries used least recently go first, an entry that cannot fit even in an empty cache is refused, what is being uploaded is not taken":
      let t = tenant()
      let be = store()
      be.save(t, "", "old", "x".repeat(40), now - 500)
      be.save(t, "", "mid", "x".repeat(40), now - 400)
      be.save(t, "", "new", "x".repeat(40), now - 300)
      discard c.findEntry(t, "", "old", @[], now)                                           # used just now: no longer the oldest
      check c.makeRoom(fixedStoreSet(be), t, "", 40, 130).ok                                                      # 120 held + 40 > 130: one goes, the least recently used (mid)
      check not c.storedEntry(t, "", "mid").found and c.storedEntry(t, "", "old").found and c.storedEntry(t, "", "new").found
      check objectKeyOf(t, "", "mid") notin be.objects
      check not c.makeRoom(fixedStoreSet(be), t, "", 500, 130).ok
      check c.makeRoom(fixedStoreSet(be), t, "", 1, 0).ok                                                         # no quota: no limit
    test "the sweep takes entries not used for the retention and uploads abandoned for a day, and nothing else":
      let t = tenant()
      let be = store()
      be.save(t, "", "stale", "s", now - 10 * 86400)
      be.save(t, "", "fresh", "f", now)
      discard c.execute(%*[["UPDATE caches SET last_used_at = ? WHERE tenant_id = ? AND key = 'stale'", now - 10 * 86400, t]])
      check c.beginEntry(newId(), t, "", "half", objectKeyOf(t, "", "half"), 10, "s", "uploading", "up9", now - 3 * 86400)
      be.uploads["up9"] = (objectKeyOf(t, "", "half"), initTable[int, string]())
      let rep = c.sweepCaches(fixedStoreSet(be), now, 7 * 86400)
      check rep.expired >= 1 and rep.abandoned >= 1
      check not c.storedEntry(t, "", "stale").found and c.storedEntry(t, "", "fresh").found and not c.uploadingEntry(t, "", "half").found
      check "up9" notin be.uploads

suite "DAT-004 the limits: the shard's, the organisation's, the groups'":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let sfx = newId()[^6 .. ^1].toLowerAscii
    var n = 0
    let now = getTime().toUnix()
    let day = 86400'i64
    proc store(): MemStore = MemStore(objects: initTable[string, string](), uploads: initTable[string, tuple[key: string, parts: Table[int, string]]]())
    proc newOrg(): string =
      inc n
      let id = c.addOrganization("cl" & $n & sfx, "L")
      discard c.ensureOrganizationProfile(id, "cinim-001-cl" & $n & sfx)
      id
    proc setOrg(org: string; quota, days: int64) =
      discard c.execute(%*[["UPDATE execution_profiles SET cache_quota_bytes = ?, cache_retention_days = ? WHERE tenant_id = ?", quota, days, org]])
    proc group(org, path: string): string =
      doAssert c.createGroup(org, path, now).error == ""
      c.groupIdOf(org, path).id
    proc put(be: MemStore; org, scope, key: string; size: int; usedAgo: int64 = 0) =
      let s3 = objectKeyOf(org, scope, key)
      doAssert c.beginEntry(newId(), org, scope, key, s3, int64(size), "sha", "stored", "", now - usedAgo)
      discard c.execute(%*[["UPDATE caches SET last_used_at = ? WHERE tenant_id = ? AND scope = ? AND key = ?", now - usedAgo, org, scope, key]])
      be.objects[s3] = "x".repeat(size)
    proc has(org, scope, key: string): bool = c.storedEntry(org, scope, key).found

    test "the organisation's quota is its own (above the shard's), -1 is no limit even when the shard has one, 0 is the shard's":
      let org = newOrg()
      let be = store()
      be.put(org, "", "a", 60, 300)
      be.put(org, "", "b", 60, 200)
      check c.makeRoom(fixedStoreSet(be), org, "", 30, 100).ok                  # 0: the shard's 100: 120 held + 30 > 100 -> the oldest go
      check not has(org, "", "a") and has(org, "", "b")
      setOrg(org, 70, 0)
      check c.makeRoom(fixedStoreSet(be), org, "", 30, 1000).ok                  # the organisation's 70, not the shard's 1000: b (60) goes
      check not has(org, "", "b")
      setOrg(org, -1, 0)
      be.put(org, "", "c", 5000)
      check c.makeRoom(fixedStoreSet(be), org, "", 9999, 100).ok and has(org, "", "c")
    test "a group's quota binds the entries of the group and of the groups below it, not its neighbours, and the organisation's binds all":
      let org = newOrg()
      let be = store()
      let team = group(org, "team")
      let back = group(org, "team/backend")
      let other = group(org, "other")
      discard c.execute(%*[["INSERT INTO group_settings (group_id, cache_quota_bytes, cache_retention_days) VALUES (?, 100, 0)", team]])
      be.put(org, team, "t", 50, 400)
      be.put(org, back, "b", 40, 300)
      be.put(org, other, "o", 500, 900)
      check c.makeRoom(fixedStoreSet(be), org, back, 30, 0).ok                    # team's pool: 50 + 40 + 30 > 100: the least recently used of team and below (t) goes
      check not has(org, team, "t") and has(org, back, "b") and has(org, other, "o")
      check not c.makeRoom(fixedStoreSet(be), org, back, 150, 0).ok               # bigger than the group's quota
      check c.makeRoom(fixedStoreSet(be), org, other, 1000, 0).ok                 # the neighbour has no limit of its own
      setOrg(org, 600, 0)
      check c.makeRoom(fixedStoreSet(be), org, other, 200, 0).ok                  # the organisation's 600: 40 + 500 + 200 > 600 -> the least recently used of the whole organisation goes: o (900 s ago), and then it fits
      check not has(org, other, "o") and has(org, back, "b")
    test "the view: the entries of an organisation, or of a group and the groups below it, the most recently used first, with what each limit holds":
      let org = newOrg()
      let other = newOrg()
      let be = store()
      let team = group(org, "team")
      let back = group(org, "team/backend")
      let side = group(org, "side")
      be.put(org, "", "root-key", 10, 100)
      be.put(org, team, "team-key", 20, 50)
      be.put(org, back, "back-key", 30, 10)
      be.put(org, side, "side-key", 40, 70)
      be.put(other, "", "not-mine", 99)
      check c.listCaches(org, "").mapIt(it.key) == @["back-key", "team-key", "side-key", "root-key"]
      let t = c.listCaches(org, "team")
      check t.mapIt(it.key) == @["back-key", "team-key"] and t[0].groupPath == "team/backend" and t[0].size == 30 and t[0].state == "stored"
      check c.listCaches(org, "side").len == 1 and c.listCaches(org, "").len == 4 and c.listCaches(org, "", limit = 2).len == 2
      check c.listCaches(org, "").filterIt(it.groupPath == "").mapIt(it.key) == @["root-key"]
      setGroupLimit(c, team, 100, 0)
      setOrg(org, 1000, 0)
      let pools = c.poolUsage(org, 5000)
      check pools[0].name == "organization" and pools[0].quota == 1000 and pools[0].bytes == 100
      check pools.len == 2 and pools[1].groupPath == "team" and pools[1].quota == 100 and pools[1].bytes == 50          # team's own and backend's
      setOrg(org, 0, 0)
      check c.poolUsage(org, 5000)[0].quota == 5000
      setOrg(org, -1, 0)
      check c.poolUsage(org, 5000)[0].quota == 0
    test "the deletion by hand: one entry, or all of exactly one scope; the object goes too; what is being uploaded stays; another scope and another organisation are not touched":
      let org = newOrg()
      let other = newOrg()
      let be = store()
      let team = group(org, "team")
      let back = group(org, "team/backend")
      be.put(org, team, "a", 5)
      be.put(org, team, "b", 5)
      be.put(org, back, "c", 5)
      be.put(org, "", "d", 5)
      be.put(other, team, "a", 5)
      check c.beginEntry(newId(), org, team, "half", objectKeyOf(org, team, "half"), 5, "s", "uploading", "up1", now)
      check c.deleteEntries(fixedStoreSet(be), org, team, "a") == (1, 0)
      check not has(org, team, "a") and objectKeyOf(org, team, "a") notin be.objects and has(org, team, "b")
      check c.deleteEntries(fixedStoreSet(be), org, team, "nope") == (0, 0)
      check c.deleteEntries(fixedStoreSet(be), org, team, "") == (1, 0)                 # all of team: b; the group below, the root and "half" stay
      check has(org, back, "c") and has(org, "", "d") and c.uploadingEntry(org, team, "half").found
      check c.deleteEntries(fixedStoreSet(be), org, "", "") == (1, 0) and not has(org, "", "d")
      check has(other, team, "a")
    test "the retention: the nearest group that says something, then the organisation, then the shard; -1 keeps for ever":
      let org = newOrg()
      let team = group(org, "team")
      let back = group(org, "team/backend")
      let shard = 5 * day
      check c.retentionSeconds(org, back, shard) == shard
      setOrg(org, 0, 20)
      check c.retentionSeconds(org, back, shard) == 20 * day and c.retentionSeconds(org, "", shard) == 20 * day
      c.setGroupLimit(team, 0, 3)
      check c.retentionSeconds(org, back, shard) == 3 * day and c.retentionSeconds(org, team, shard) == 3 * day and c.retentionSeconds(org, "", shard) == 20 * day
      c.setGroupLimit(back, 0, -1)
      check c.retentionSeconds(org, back, shard) == 0                # for ever
      setOrg(org, 0, -1)
      check c.retentionSeconds(org, "", shard) == 0
    test "the sweep applies the retention of each entry's scope, not one for all":
      let org = newOrg()
      let be = store()
      let short = group(org, "short")
      let long = group(org, "long")
      c.setGroupLimit(short, 0, 1)
      c.setGroupLimit(long, 0, -1)
      for scope in [short, long, ""]: be.put(org, scope, "k", 5, 10 * day)
      let rep = c.sweepCaches(fixedStoreSet(be), now, 7 * day)                      # the shard's 7 days; the organisation has nothing of its own
      check rep.expired >= 2
      check not has(org, short, "k") and has(org, long, "k") and not has(org, "", "k")
    test "what a group may have is checked: 0 or 1 MiB..1 PiB, and retention -1, 0 or 1..3650":
      check validGroupLimit(0, 0) == "" and validGroupLimit(1024 * 1024, 3650) == "" and validGroupLimit(0, -1) == ""
      check validGroupLimit(-1, 0).len > 0 and validGroupLimit(100, 0).len > 0 and validGroupLimit(1'i64 shl 51, 0).len > 0
      check validGroupLimit(0, -2).len > 0 and validGroupLimit(0, 3651).len > 0

suite "DAT-004 the requests of the cache on the channel":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let sfx = newId()[^6 .. ^1].toLowerAscii
    var n = 0
    let now = getTime().toUnix()
    proc store(): MemStore = MemStore(objects: initTable[string, string](), uploads: initTable[string, tuple[key: string, parts: Table[int, string]]]())
    proc tenant(): string =
      inc n
      "q" & $n & sfx
    let decls = @[CacheDecl(key: "deps-1", paths: @["node_modules"], restoreKeys: @["deps-"])]
    proc req(op, path: string; cache = true): ArtifactRequest = ArtifactRequest(op: op, path: path, cache: cache)

    proc withDirect(body: proc ()) =
      configureStorage("http://module.test:18090", "a-secret-of-the-shard-for-grants", "001", "http://module.test:18091")
      try: body()
      finally: configureStorage("", "", "001")
    proc direct(op, path: string): ArtifactRequest =
      result = req(op, path)
      result.direct = true

    test "a step saves the key it declared, and a second saver of the key gives way with cache_exists":
      withDirect(proc () =
        let t = tenant()
        let be = store()
        var r = direct("put_begin", "deps-1")
        let data = "archive bytes"
        r.size = uint64(data.len)
        r.sha256 = shaOf(data)
        let began = handleCache(c, r, t, "", decls, fixedStoreSet(be), now)
        check began.accepted and began.upload_id.len > 0
        check not c.storedEntry(t, "", "deps-1").found                          # not stored until it is complete
        let again = handleCache(c, r, t, "", decls, fixedStoreSet(be), now)
        check not again.accepted and again.failure.code == "cache_exists"
        # an empty entry, and the ways that carried bytes through the core, are not
        var empty = direct("put_begin", "deps-1"); empty.size = 0; empty.sha256 = shaOf("")
        check handleCache(c, empty, t, "", decls, fixedStoreSet(be), now).failure.code in ["cache_exists", "bad_request"]
        for op in ["put_object", "put_part", "get_block"]:
          check handleCache(c, req(op, "deps-1"), t, "", decls, fixedStoreSet(be), now).failure.code == "bad_request")
    test "D-61 a shim that can send its bytes straight to the module is given a grant, and the upload is completed only when the digests it reported are those the module made":
      configureStorage("http://module.test:18090", "a-secret-of-the-shard-for-grants", "001", "http://module.test:18091")
      defer: configureStorage("", "", "001")
      let t = tenant()
      discard c.execute(%*[["INSERT OR REPLACE INTO org_storage (tenant_id, purpose, store_name, updated_by, updated_at) VALUES (?, 'caches', 'mem', 'test', 1)", t]])
      let be = store()
      let data = "a".repeat(20) & "b".repeat(20)
      var b = req("put_begin", "deps-1")
      b.size = uint64(data.len)
      b.sha256 = shaOf(data)
      let plain = handleCache(c, b, t, "", decls, fixedStoreSet(be), now)                       # a shim that cannot use a grant: refused, nothing is started
      check not plain.accepted and plain.failure.code == "direct_required"
      check not c.uploadingEntry(t, "", "deps-1").found
      b.direct = true
      configureStorage("http://module.test:18090", "a-secret-of-the-shard-for-grants", "001", "")      # a shard with no port for shims
      check handleCache(c, b, t, "", decls, fixedStoreSet(be), now).failure.code == "direct_required"
      check not c.uploadingEntry(t, "", "deps-1").found
      configureStorage("http://module.test:18090", "a-secret-of-the-shard-for-grants", "001", "http://module.test:18091")
      let began = handleCache(c, b, t, "", decls, fixedStoreSet(be), now)
      check began.accepted and began.grant.startsWith("g1.001.") and began.direct_url == "http://module.test:18091"
      check began.direct_path == "/s/mem/" & objectKeyOf(t, "", "deps-1")
      check verifyGrant("a-secret-of-the-shard-for-grants", "001", "mem", objectKeyOf(t, "", "deps-1"), began.upload_id, "w", began.grant, now)
      be.objects[objectKeyOf(t, "", "deps-1")] = data                                            # what completing the upload at the store would leave
      var e = req("put_end", "deps-1"); e.upload_id = began.upload_id
      # the shim's digests differ from the module's: nothing is stored, the upload is dropped
      be.direct = @[(1, shaOf(data[0 ..< 20]), 20'i64), (2, shaOf("not what the shim has"), 20'i64)]
      e.parts = @[ArtifactPart(part: 1, etag: "e1", sha256: shaOf(data[0 ..< 20])), ArtifactPart(part: 2, etag: "e2", sha256: shaOf(data[20 .. ^1]))]
      let differ = handleCache(c, e, t, "", decls, fixedStoreSet(be), now)
      check not differ.accepted and differ.failure.code == "digest_mismatch"
      check not c.storedEntry(t, "", "deps-1").found and not c.uploadingEntry(t, "", "deps-1").found
      # a second try that agrees
      let again = handleCache(c, b, t, "", decls, fixedStoreSet(be), now)
      check again.accepted and again.grant.len > 0
      e.upload_id = again.upload_id
      be.direct = @[(1, shaOf(data[0 ..< 20]), 20'i64), (2, shaOf(data[20 .. ^1]), 20'i64)]
      be.objects[objectKeyOf(t, "", "deps-1")] = data
      check handleCache(c, e, t, "", decls, fixedStoreSet(be), now).accepted
      check c.storedEntry(t, "", "deps-1").found
      # digests for some parts only, or in the wrong form
      let third = handleCache(c, b, t, "", @[CacheDecl(key: "deps-2", paths: @["x"])], fixedStoreSet(be), now)
      check not third.accepted                                                                    # (not its key: refused before anything else)
      # the entry is offered for a direct read, with a grant for reading and the path of the object
      var find = req("cache_find", "deps-1")
      find.direct = true
      let found = handleCache(c, find, t, "", decls, fixedStoreSet(be), now)
      check found.files.len == 1 and found.files[0].grant.startsWith("g1.001.") and found.files[0].direct_path == "/s/mem/" & objectKeyOf(t, "", "deps-1") and found.direct_url == "http://module.test:18091"
      check verifyGrant("a-secret-of-the-shard-for-grants", "001", "mem", objectKeyOf(t, "", "deps-1"), "", "r", found.files[0].grant, now)
      find.direct = false
      check handleCache(c, find, t, "", decls, fixedStoreSet(be), now).failure.code == "direct_required"   # a shim that cannot use a grant is not given the entry

    test "a size that is not the one announced is refused and nothing stays":
      withDirect(proc () =
        let t = tenant()
        let be = store()
        var b = direct("put_begin", "deps-1")
        b.size = 99
        b.sha256 = shaOf("x")
        let began = handleCache(c, b, t, "", decls, fixedStoreSet(be), now)
        be.objects[objectKeyOf(t, "", "deps-1")] = "short"                       # what the store holds after the complete
        be.direct = @[(1, shaOf("short"), 5'i64)]
        var e = req("put_end", "deps-1"); e.upload_id = began.upload_id; e.parts = @[ArtifactPart(part: 1, etag: "e1", sha256: shaOf("short"))]
        let ended = handleCache(c, e, t, "", decls, fixedStoreSet(be), now)
        check not ended.accepted and ended.failure.code == "size_mismatch"
        check not c.storedEntry(t, "", "deps-1").found and not c.uploadingEntry(t, "", "deps-1").found)
    test "a step finds and reads what it declared (the key, or what a restore key names) and nothing else; saves its own key only":
      let t = tenant()
      let be = store()
      be.objects[objectKeyOf(t, "", "deps-0")] = "older archive"
      check c.beginEntry(newId(), t, "", "deps-0", objectKeyOf(t, "", "deps-0"), 13, shaOf("older archive"), "stored", "", now - 100, "mem")
      be.objects[objectKeyOf(t, "", "secret-x")] = "not yours"
      check c.beginEntry(newId(), t, "", "secret-x", objectKeyOf(t, "", "secret-x"), 9, shaOf("not yours"), "stored", "", now, "mem")
      withDirect(proc () =
        let found = handleCache(c, direct("cache_find", "deps-1"), t, "", decls, fixedStoreSet(be), now)
        check found.accepted and found.files.len == 1 and found.files[0].path == "deps-0" and found.files[0].size == 13 and found.files[0].sha256 == shaOf("older archive")
        check found.files[0].grant.len > 0
        check handleCache(c, direct("cache_find", "secret-x"), t, "", decls, fixedStoreSet(be), now).failure.code == "not_declared"
        var w = direct("put_begin", "deps-0"); w.size = 1; w.sha256 = shaOf("x")
        check handleCache(c, w, t, "", decls, fixedStoreSet(be), now).failure.code == "not_declared"           # a restore key lets a step read, not save
        check handleCache(c, direct("cache_find", "deps-nothing"), t, "", @[CacheDecl(key: "deps-nothing", paths: @["x"])], fixedStoreSet(be), now).files.len == 0)
    test "an entry that does not fit the organisation's quota is refused with quota_exceeded":
      let t = tenant()
      let be = store()
      putEnv("CINIM_CACHE_QUOTA", "10")
      var r = direct("put_begin", "deps-1")
      r.size = 20; r.sha256 = shaOf("y".repeat(20))
      var refused: ArtifactAck
      withDirect(proc () = refused = handleCache(c, r, t, "", decls, fixedStoreSet(be), now))
      delEnv("CINIM_CACHE_QUOTA")
      check not refused.accepted and refused.failure.code == "quota_exceeded"
      check not c.uploadingEntry(t, "", "deps-1").found
    test "the declaration is checked when the step is taken: keys, paths, restore keys, how many":
      check checkCacheDecl("") == "" and checkCacheDecl("""{"cache":[{"key":"a","paths":["x"],"restore_keys":["a"]}]}""") == ""
      check checkCacheDecl("""{"cache":[{"key":"a/b","paths":["x"],"restore_keys":[]}]}""").len > 0
      check checkCacheDecl("""{"cache":[{"key":"a","paths":["../x"],"restore_keys":[]}]}""").len > 0
      check checkCacheDecl("""{"cache":[{"key":"a","paths":[],"restore_keys":[]}]}""").len > 0
      check checkCacheDecl("""{"cache":[{"key":"a","paths":["x"],"restore_keys":["a b"]}]}""").len > 0
      # the steps of j.cache.restore and j.cache.save: a restore needs no path, a save does, and there are two modes only
      check checkCacheDecl("""{"cache":[{"key":"a","mode":"restore","paths":[],"restore_keys":["a"]}]}""") == ""
      check checkCacheDecl("""{"cache":[{"key":"a","mode":"save","paths":["x"],"restore_keys":[]}]}""") == ""
      check checkCacheDecl("""{"cache":[{"key":"a","mode":"save","paths":[],"restore_keys":[]}]}""").len > 0
      check checkCacheDecl("""{"cache":[{"key":"a","mode":"both","paths":["x"],"restore_keys":[]}]}""").len > 0
      check cacheDecls("""{"cache":[{"key":"a","mode":"restore","paths":[],"restore_keys":[]}]}""")[0].mode == "restore"
