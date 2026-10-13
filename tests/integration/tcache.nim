## DAT-004: the cache between runs, the core's side, against a real rqlite and a store in memory: the choice of the entry (the key, else the latest a restore key names), the
## immutability of a key, what a step may find and save, the room (least recently used go first), the sweep, and the requests of the channel (cache_find, put_*, get_block).
## Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, tables, strutils, times, sequtils]
import checksums/sha2
import common/rqlite
import core/[schema, storagebackend, cachestore, artifactingest, groups]

type MemStore = ref object of ObjectBackend
  objects: Table[string, string]
  uploads: Table[string, tuple[key: string, parts: Table[int, string]]]
  next: int

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
  for (n, _) in parts: all.add b.uploads[uploadId].parts[n]
  b.objects[key] = all
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
      check c.makeRoom(be, t, "", 40, 130).ok                                                      # 120 held + 40 > 130: one goes, the least recently used (mid)
      check not c.storedEntry(t, "", "mid").found and c.storedEntry(t, "", "old").found and c.storedEntry(t, "", "new").found
      check objectKeyOf(t, "", "mid") notin be.objects
      check not c.makeRoom(be, t, "", 500, 130).ok
      check c.makeRoom(be, t, "", 1, 0).ok                                                         # no quota: no limit
    test "the sweep takes entries not used for the retention and uploads abandoned for a day, and nothing else":
      let t = tenant()
      let be = store()
      be.save(t, "", "stale", "s", now - 10 * 86400)
      be.save(t, "", "fresh", "f", now)
      discard c.execute(%*[["UPDATE caches SET last_used_at = ? WHERE tenant_id = ? AND key = 'stale'", now - 10 * 86400, t]])
      check c.beginEntry(newId(), t, "", "half", objectKeyOf(t, "", "half"), 10, "s", "uploading", "up9", now - 3 * 86400)
      be.uploads["up9"] = (objectKeyOf(t, "", "half"), initTable[int, string]())
      let rep = c.sweepCaches(be, now, 7 * 86400)
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
      check c.makeRoom(be, org, "", 30, 100).ok                  # 0: the shard's 100: 120 held + 30 > 100 -> the oldest go
      check not has(org, "", "a") and has(org, "", "b")
      setOrg(org, 70, 0)
      check c.makeRoom(be, org, "", 30, 1000).ok                  # the organisation's 70, not the shard's 1000: b (60) goes
      check not has(org, "", "b")
      setOrg(org, -1, 0)
      be.put(org, "", "c", 5000)
      check c.makeRoom(be, org, "", 9999, 100).ok and has(org, "", "c")
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
      check c.makeRoom(be, org, back, 30, 0).ok                    # team's pool: 50 + 40 + 30 > 100: the least recently used of team and below (t) goes
      check not has(org, team, "t") and has(org, back, "b") and has(org, other, "o")
      check not c.makeRoom(be, org, back, 150, 0).ok               # bigger than the group's quota
      check c.makeRoom(be, org, other, 1000, 0).ok                 # the neighbour has no limit of its own
      setOrg(org, 600, 0)
      check c.makeRoom(be, org, other, 200, 0).ok                  # the organisation's 600: 40 + 500 + 200 > 600 -> the least recently used of the whole organisation goes: o (900 s ago), and then it fits
      check not has(org, other, "o") and has(org, back, "b")
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
      let rep = c.sweepCaches(be, now, 7 * day)                      # the shard's 7 days; the organisation has nothing of its own
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

    test "a step saves the key it declared (one block), and a second saver of the key gives way with cache_exists":
      let t = tenant()
      let be = store()
      var r = req("put_object", "deps-1")
      let data = "archive bytes"
      r.size = uint64(data.len)
      r.sha256 = shaOf(data)
      r.data = cast[seq[byte]](data)
      check handleCache(c, r, t, "", decls, be, now).accepted
      check be.objects[objectKeyOf(t, "", "deps-1")] == data
      let again = handleCache(c, r, t, "", decls, be, now)
      check not again.accepted and again.failure.code == "cache_exists"
    test "a bigger entry goes by put_begin, put_part, put_end, and is stored only when the store has it with the size announced":
      let t = tenant()
      let be = store()
      let data = "a".repeat(20) & "b".repeat(20)
      var b = req("put_begin", "deps-1")
      b.size = uint64(data.len)
      b.sha256 = shaOf(data)
      let began = handleCache(c, b, t, "", decls, be, now)
      check began.accepted and began.upload_id.len > 0
      check not c.storedEntry(t, "", "deps-1").found                          # not stored until it is complete
      var p1 = req("put_part", "deps-1"); p1.upload_id = began.upload_id; p1.part = 1; p1.data = cast[seq[byte]](data[0 ..< 20])
      var p2 = req("put_part", "deps-1"); p2.upload_id = began.upload_id; p2.part = 2; p2.data = cast[seq[byte]](data[20 .. ^1])
      let a1 = handleCache(c, p1, t, "", decls, be, now)
      let a2 = handleCache(c, p2, t, "", decls, be, now)
      check a1.accepted and a2.accepted
      var e = req("put_end", "deps-1"); e.upload_id = began.upload_id
      e.parts = @[ArtifactPart(part: 1, etag: a1.etag), ArtifactPart(part: 2, etag: a2.etag)]
      check handleCache(c, e, t, "", decls, be, now).accepted
      check c.storedEntry(t, "", "deps-1").found and be.objects[objectKeyOf(t, "", "deps-1")] == data
    test "a size that is not the one announced is refused and nothing stays":
      let t = tenant()
      let be = store()
      var b = req("put_begin", "deps-1")
      b.size = 99
      b.sha256 = shaOf("x")
      let began = handleCache(c, b, t, "", decls, be, now)
      var p1 = req("put_part", "deps-1"); p1.upload_id = began.upload_id; p1.part = 1; p1.data = cast[seq[byte]]("short")
      let a1 = handleCache(c, p1, t, "", decls, be, now)
      var e = req("put_end", "deps-1"); e.upload_id = began.upload_id; e.parts = @[ArtifactPart(part: 1, etag: a1.etag)]
      let ended = handleCache(c, e, t, "", decls, be, now)
      check not ended.accepted and ended.failure.code == "size_mismatch"
      check not c.storedEntry(t, "", "deps-1").found and not c.uploadingEntry(t, "", "deps-1").found
    test "a step finds and reads what it declared (the key, or what a restore key names) and nothing else; saves its own key only":
      let t = tenant()
      let be = store()
      be.objects[objectKeyOf(t, "", "deps-0")] = "older archive"
      check c.beginEntry(newId(), t, "", "deps-0", objectKeyOf(t, "", "deps-0"), 13, shaOf("older archive"), "stored", "", now - 100)
      be.objects[objectKeyOf(t, "", "secret-x")] = "not yours"
      check c.beginEntry(newId(), t, "", "secret-x", objectKeyOf(t, "", "secret-x"), 9, shaOf("not yours"), "stored", "", now)
      let found = handleCache(c, req("cache_find", "deps-1"), t, "", decls, be, now)
      check found.accepted and found.files.len == 1 and found.files[0].path == "deps-0" and found.files[0].size == 13 and found.files[0].sha256 == shaOf("older archive")
      var g = req("get_block", "deps-0"); g.offset = 0; g.length = 5
      let blk = handleCache(c, g, t, "", decls, be, now)
      check blk.accepted and cast[string](blk.data) == "older"
      check handleCache(c, req("cache_find", "secret-x"), t, "", decls, be, now).failure.code == "not_declared"
      var g2 = req("get_block", "secret-x"); g2.offset = 0; g2.length = 5
      check handleCache(c, g2, t, "", decls, be, now).failure.code == "not_declared"
      var w = req("put_object", "deps-0"); w.size = 1; w.sha256 = shaOf("x"); w.data = cast[seq[byte]]("x")
      check handleCache(c, w, t, "", decls, be, now).failure.code == "not_declared"           # a restore key lets a step read, not save
      check handleCache(c, req("cache_find", "deps-nothing"), t, "", @[CacheDecl(key: "deps-nothing", paths: @["x"])], be, now).files.len == 0
    test "an entry that does not fit the organisation's quota is refused with quota_exceeded":
      let t = tenant()
      let be = store()
      putEnv("CINIM_CACHE_QUOTA", "10")
      var r = req("put_object", "deps-1")
      r.size = 20; r.sha256 = shaOf("y".repeat(20)); r.data = cast[seq[byte]]("y".repeat(20))
      let refused = handleCache(c, r, t, "", decls, be, now)
      delEnv("CINIM_CACHE_QUOTA")
      check not refused.accepted and refused.failure.code == "quota_exceeded"
      check not c.uploadingEntry(t, "", "deps-1").found
    test "the declaration is checked when the step is taken: keys, paths, restore keys, how many":
      check checkCacheDecl("") == "" and checkCacheDecl("""{"cache":[{"key":"a","paths":["x"],"restore_keys":["a"]}]}""") == ""
      check checkCacheDecl("""{"cache":[{"key":"a/b","paths":["x"],"restore_keys":[]}]}""").len > 0
      check checkCacheDecl("""{"cache":[{"key":"a","paths":["../x"],"restore_keys":[]}]}""").len > 0
      check checkCacheDecl("""{"cache":[{"key":"a","paths":[],"restore_keys":[]}]}""").len > 0
      check checkCacheDecl("""{"cache":[{"key":"a","paths":["x"],"restore_keys":["a b"]}]}""").len > 0
