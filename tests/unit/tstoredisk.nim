## DAT-003, D-57 (docs/store.md): the disk of a store node. Objects are plain files under readable, escaped paths; a write is whole or absent; a multipart upload is put together in
## order and checked; a listing keeps the order of the segments and pages by a cursor; a key that could be a trick is refused. Real files in a scratch directory.
import std/[unittest, os, strutils, sequtils, times, tables, algorithm]
import checksums/sha2
import store/[layout, disk]

func sha(s: string): string =
  for c in secureHash(Sha_256, s): result.add toHex(ord(c), 2).toLowerAscii

let base = getTempDir() / ("tstoredisk-" & $getCurrentProcessId())

proc fresh(name: string): Disk =
  let r = base / name
  removeDir(r)
  openDisk(r)

proc tmpFiles(d: Disk): seq[string] =
  for p in walkDirRec(d.root / "tmp"): result.add p

suite "D-57 the disk: whole objects":
  test "an object is put, found by size, read by ranges, hashed and deleted":
    let d = fresh("basic")
    check d.putObject("acme/s1_x/dist/app.txt", "hello world").ok
    check d.objectSize("acme/s1_x/dist/app.txt").size == 11
    let r = d.readRange("acme/s1_x/dist/app.txt", 6, 5)
    check r.res.ok and r.data == "world" and r.size == 11
    check d.readRange("acme/s1_x/dist/app.txt", 0, 1000).data == "hello world"       # the end is clamped
    check d.readRange("acme/s1_x/dist/app.txt", 11, 5).data == ""                      # at the end: nothing, not an error
    check d.readRange("acme/s1_x/dist/app.txt", 12, 5).res.code == "bad_range"
    check d.hashOf("acme/s1_x/dist/app.txt").sha256 == sha("hello world")
    check d.deleteObject("acme/s1_x/dist/app.txt").ok
    check d.objectSize("acme/s1_x/dist/app.txt").res.code == "not_found"
    check d.readRange("acme/s1_x/dist/app.txt", 0, 1).res.code == "not_found"
  test "the file is where the key says, with the segments escaped":
    let d = fresh("where")
    check d.putObject("t/r/odd dir/q?mark/.hidden", "x").ok
    check fileExists(d.root / "data" / "t" / "r" / "odd dir" / "q%3Fmark" / "%2Ehidden")
  test "a put with a SHA-256 that is not the data's is refused and leaves nothing":
    let d = fresh("badhash")
    check d.putObject("a/b", "data", sha("data")).ok
    let r = d.putObject("a/c", "data", sha("other"))
    check not r.ok and r.code == "bad_hash"
    check d.objectSize("a/c").res.code == "not_found"
    check d.tmpFiles.len == 0
  test "a put replaces an object whole":
    let d = fresh("replace")
    check d.putObject("a/b", "first version, longer").ok
    check d.putObject("a/b", "second").ok
    check d.readRange("a/b", 0, 100).data == "second"
    check d.tmpFiles.len == 0
  test "a key that could be a trick is refused, never rewritten":
    let d = fresh("trick")
    for k in ["", "/a", "a/", "a//b", "a/../b", "../x", "a/./b", "has\x01ctl"]:
      check d.putObject(k, "x").code == "bad_key"
      check d.objectSize(k).res.code == "bad_key"
      check d.deleteObject(k).code == "bad_key"
    check toSeq(walkDirRec(d.root / "data")).len == 0
  test "an empty object, a 5 MiB object, and every byte value":
    let d = fresh("sizes")
    check d.putObject("e", "").ok and d.objectSize("e").size == 0 and d.readRange("e", 0, 10).data == ""
    let big = "0123456789abcdef".repeat(5 shl 16)
    check d.putObject("big", big, sha(big)).ok and d.hashOf("big").sha256 == sha(big)
    var all = ""
    for i in 0 .. 255: all.add char(i)
    check d.putObject("bytes", all).ok and d.readRange("bytes", 0, 256).data == all
  test "deleting a missing object is not an error, and the empty directories above it go":
    let d = fresh("delete")
    check d.deleteObject("nothing/here").ok
    check d.putObject("t/r/one/x", "1").ok and d.putObject("t/r/two/y", "2").ok
    check d.deleteObject("t/r/one/x").ok
    check not dirExists(d.root / "data" / "t" / "r" / "one") and dirExists(d.root / "data" / "t" / "r" / "two")
    check d.deleteObject("t/r/two/y").ok
    check not dirExists(d.root / "data" / "t") and dirExists(d.root / "data")
  test "a key and a key below it cannot both exist: conflict, and what was there stays":
    let d = fresh("conflict")
    check d.putObject("a/b", "file").ok
    check d.putObject("a/b/c", "x").code == "conflict"
    check d.putObject("a", "x").code == "conflict"
    check d.readRange("a/b", 0, 10).data == "file"
    check d.tmpFiles.len == 0
  test "odd names are written, read back and listed as written":
    let d = fresh("odd")
    let keys = @["odd/plain", "odd/with space", "odd/ключ-鍵-🔑", "odd/q?mark", "odd/hash#tag", "odd/percent%25", "odd/star*", "odd/quote\"s", "odd/back\\slash", "odd/ends.",
                 "odd/.hidden", "odd/ñandú", "odd/" & "x".repeat(900) & "/leaf", "odd/at@sign:colon"]
    for i, k in keys: check d.putObject(k, "data-" & $i).ok
    for i, k in keys: check d.readRange(k, 0, 100).data == "data-" & $i
    let l = d.listKeys("odd/", "", 100)
    check l.entries.len == keys.len and l.next == ""
    for k in keys:
      if k.len < 400: check k in l.entries.mapIt(it.key)
    check l.entries.filterIt(not it.exact).len == 1                                  # only the one with the 900-byte segment

suite "D-57 the disk: multipart uploads":
  test "parts uploaded in any order are put together in the order listed, and the SHA-256 of the whole is checked":
    let d = fresh("mp")
    let up = d.mpCreate("t/r/big.bin")
    check up.res.ok and up.uploadId.len == 32
    let p3 = d.mpPart(up.uploadId, 3, "CCC")
    let p1 = d.mpPart(up.uploadId, 1, "AAAA")
    let p2 = d.mpPart(up.uploadId, 2, "BB")
    check p1.etag == sha("AAAA") and p2.res.ok and p3.res.ok
    check d.objectSize("t/r/big.bin").res.code == "not_found"                              # not there before the complete
    let done = d.mpComplete(up.uploadId, @[(1, p1.etag), (2, p2.etag), (3, p3.etag)], sha("AAAABBCCC"))
    check done.ok
    check d.readRange("t/r/big.bin", 0, 100).data == "AAAABBCCC"
    check d.tmpFiles.len == 0
  test "a part sent again replaces the earlier one":
    let d = fresh("mp-again")
    let up = d.mpCreate("k")
    discard d.mpPart(up.uploadId, 1, "old")
    let p = d.mpPart(up.uploadId, 1, "new")
    check d.mpComplete(up.uploadId, @[(1, p.etag)]).ok and d.readRange("k", 0, 10).data == "new"
  test "a wrong etag, a part that was never sent, an order that is not ascending, and a wrong whole hash are refused":
    let d = fresh("mp-bad")
    let up = d.mpCreate("k")
    let p1 = d.mpPart(up.uploadId, 1, "one")
    let p2 = d.mpPart(up.uploadId, 2, "two")
    check d.mpComplete(up.uploadId, @[(1, sha("zzz"))]).code == "bad_part"
    check d.mpComplete(up.uploadId, @[(1, p1.etag), (3, sha("three"))]).code == "bad_part"
    check d.mpComplete(up.uploadId, @[(2, p2.etag), (1, p1.etag)]).code == "bad_part"
    check d.mpComplete(up.uploadId, @[]).code == "bad_part"
    check d.mpComplete(up.uploadId, @[(1, p1.etag), (2, p2.etag)], sha("not it")).code == "bad_hash"
    check d.objectSize("k").res.code == "not_found"
    check d.mpComplete(up.uploadId, @[(1, p1.etag), (2, p2.etag)], sha("onetwo")).ok            # the upload is still there after the refusals
  test "an upload is gone after the complete and after an abort; an unknown or malformed id is refused":
    let d = fresh("mp-gone")
    let up = d.mpCreate("k")
    let p = d.mpPart(up.uploadId, 1, "x")
    check d.mpComplete(up.uploadId, @[(1, p.etag)]).ok
    check d.mpComplete(up.uploadId, @[(1, p.etag)]).code == "bad_upload"
    check d.mpPart(up.uploadId, 2, "y").res.code == "bad_upload"
    let up2 = d.mpCreate("k2")
    discard d.mpPart(up2.uploadId, 1, "x")
    check d.mpAbort(up2.uploadId).ok and d.tmpFiles.len == 0
    check d.mpPart(up2.uploadId, 1, "x").res.code == "bad_upload"
    for id in ["", "../x", "short", "Z".repeat(32)]:
      check d.mpPart(id, 1, "x").res.code == "bad_upload"
      check d.mpAbort(id).code == "bad_upload"
  test "part numbers outside 1..10000 and a bad key at the start are refused":
    let d = fresh("mp-num")
    let up = d.mpCreate("k")
    check d.mpPart(up.uploadId, 0, "x").res.code == "bad_part" and d.mpPart(up.uploadId, 10001, "x").res.code == "bad_part"
    check d.mpCreate("a/../b").res.code == "bad_key"
  test "the upload that replaces an object does it whole":
    let d = fresh("mp-replace")
    check d.putObject("k", "old old old").ok
    let up = d.mpCreate("k")
    let p = d.mpPart(up.uploadId, 1, "new")
    check d.readRange("k", 0, 100).data == "old old old"                                # until the complete
    check d.mpComplete(up.uploadId, @[(1, p.etag)]).ok and d.readRange("k", 0, 100).data == "new"

suite "D-57 the disk: listing, statistics, upkeep":
  test "the order is that of the segments, so a/b comes before a-b":
    let d = fresh("order")
    for k in ["a-b", "a/b", "a/c", "b", "a0"]: check d.putObject(k, "x").ok
    check d.listKeys("", "", 100).entries.mapIt(it.key) == @["a/b", "a/c", "a-b", "a0", "b"]
  test "a prefix keeps whole segments equal and the last one a beginning":
    let d = fresh("prefix")
    for k in ["acme/r1/x", "acme/r1/y", "acme/r2/x", "acmeX/r1/x", "other/r1/x"]: check d.putObject(k, "x").ok
    check d.listKeys("acme/", "", 100).entries.mapIt(it.key) == @["acme/r1/x", "acme/r1/y", "acme/r2/x"]
    check d.listKeys("acme/r1/", "", 100).entries.mapIt(it.key) == @["acme/r1/x", "acme/r1/y"]
    check d.listKeys("acme", "", 100).entries.mapIt(it.key) == @["acme/r1/x", "acme/r1/y", "acme/r2/x", "acmeX/r1/x"]
    check d.listKeys("acme/r", "", 100).entries.len == 3
    check d.listKeys("nope/", "", 100).entries.len == 0
  test "pages are cut by the limit and go on from `next`; the pages together are the whole listing once":
    let d = fresh("pages")
    var want: seq[string]
    for i in 0 ..< 23:
      let k = "t/" & (if i mod 2 == 0: "even" else: "odd") & "/f" & align($i, 3, '0')
      check d.putObject(k, $i).ok
      want.add k
    let all = d.listKeys("t/", "", 1000).entries.mapIt(it.key)
    check all.len == 23 and all.sorted == want.sorted
    var got: seq[string]
    var after = ""
    var pages = 0
    while true:
      let p = d.listKeys("t/", after, 5)
      got.add p.entries.mapIt(it.key)
      inc pages
      if p.next == "": break
      after = p.next
    check got == all and pages == 5
    check d.listKeys("t/", "", 0).entries.len == 0
  test "an entry has its size and time":
    let d = fresh("entry")
    check d.putObject("a/b", "12345").ok
    let e = d.listKeys("", "", 10).entries[0]
    check e.size == 5 and e.exact and abs(e.mtime - getTime().toUnix) < 5
  test "statistics say how much disk there is":
    let d = fresh("stats")
    let s = d.stats
    check s.total > 0 and s.free > 0 and s.free <= s.total
  test "what a crash left in tmp is removed when it is old enough, and nothing else is":
    let d = fresh("sweep")
    check d.putObject("keep/me", "x").ok
    writeFile(d.root / "tmp" / "put-dead", "half a write")
    createDir(d.root / "tmp" / "up-dead")
    writeFile(d.root / "tmp" / "up-dead" / "part-1", "x")
    setLastModificationTime(d.root / "tmp" / "put-dead", getTime() - initDuration(hours = 30))
    setLastModificationTime(d.root / "tmp" / "up-dead", getTime() - initDuration(hours = 30))
    writeFile(d.root / "tmp" / "put-fresh", "being written now")
    check d.sweepTmp(24 * 3600) == 2
    check not fileExists(d.root / "tmp" / "put-dead") and not dirExists(d.root / "tmp" / "up-dead") and fileExists(d.root / "tmp" / "put-fresh")
    check d.readRange("keep/me", 0, 10).data == "x"
  test "a leftover in tmp is never listed as an object":
    let d = fresh("leftover")
    writeFile(d.root / "tmp" / "put-half", "partial")
    check d.listKeys("", "", 10).entries.len == 0

removeDir(base)
