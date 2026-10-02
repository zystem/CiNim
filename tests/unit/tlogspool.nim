## D-27: the shim's log spool - records, secret masking, gzip blocks, the file queue and its size limit.
import std/[unittest, json, strutils, os, sequtils, atomics, unicode]
import zippy
import shim/logspool

proc records(blk: LogBlock): seq[JsonNode] =
  for l in uncompress(blk.data).splitLines:
    if l.len > 0: result.add parseJson(l)

proc msgs(blocks: seq[LogBlock]): seq[string] =
  for b in blocks:
    for r in records(b): result.add r["_msg"].getStr

proc newB(secrets: seq[string] = @[]): Builder = newBuilder("ci-s1-run-0-1", "s1_run", 1_000_000, secrets)

suite "records and blocks":
  test "lines become jsonline records with the labels, ln and the monotonic _time":
    var b = newB()
    var blocks = b.feed("hello\nworld\n", 5000)
    blocks.add b.flush(5000)
    check blocks.len == 1
    let r = records(blocks[0])
    check r.len == 2
    check r[0]["_msg"].getStr == "hello" and r[0]["ln"].getInt == 0
    check r[1]["_msg"].getStr == "world" and r[1]["ln"].getInt == 1
    check r[1]["_time"].getInt == 1_000_001            # base + ln
    check r[1]["ts"].getInt == 5000                      # the wall clock is kept separately
    check r[0]["job"].getStr == "ci-s1-run-0-1" and r[0]["run"].getStr == "s1_run"
    check blocks[0].encoding == "gzip" and blocks[0].lines == 2 and blocks[0].firstLn == 0 and blocks[0].seq == 1

  test "a line split across two reads is joined; the unfinished line waits":
    var b = newB()
    check b.feed("par", 1).len == 0
    check b.feed("tial\nnext", 1).len == 0
    let blocks = b.flush(1)
    check msgs(blocks) == @["partial"]                   # "next" has no newline yet
    check msgs(b.flush(2, final = true)) == @["next"]    # ... until the final flush

  test "block seq and firstLn are gap-free across blocks":
    var b = newB()
    var all: seq[LogBlock]
    for i in 0 ..< 3000: all.add b.feed("line " & $i & " " & 'x'.repeat(40) & "\n", 1)
    all.add b.flush(1, final = true)
    check all.len > 2
    var nextSeq = 1'u64
    var nextLn = 0'u64
    for blk in all:
      check blk.seq == nextSeq
      check blk.firstLn == nextLn
      nextSeq.inc
      nextLn += blk.lines
    check nextLn == 3000
    check msgs(all).len == 3000
    check msgs(all)[2999].startsWith("line 2999")

  test "blocks are cut around 64 KiB of records, not much larger":
    var b = newB()
    var blocks: seq[LogBlock]
    for i in 0 ..< 5000: blocks.add b.feed('y'.repeat(100) & "\n", 1)
    for blk in blocks: check uncompress(blk.data).len < blockRawTarget + 400

  test "CRLF is trimmed, a very long line is split, invalid UTF-8 is made safe":
    var b = newB()
    var blocks = b.feed("dos line\r\n", 1)
    blocks.add b.feed('z'.repeat(maxLineBytes * 2 + 10) & "\n", 1)
    blocks.add b.feed("bad \xff\xfe bytes\n", 1)
    blocks.add b.flush(1)
    let m = msgs(blocks)
    check m[0] == "dos line"
    check m[1].len == maxLineBytes and m[2].len == maxLineBytes and m[3].len == 10
    check m[4] == "bad \xEF\xBF\xBD\xEF\xBF\xBD bytes"

  test "control characters and quotes survive as valid JSON":
    var b = newB()
    check msgs(b.feed("tab\there \"quoted\" back\\slash \x1b[31mred\x1b[0m\n", 1) & b.flush(1)) ==
      @["tab\there \"quoted\" back\\slash \x1b[31mred\x1b[0m"]

  test "typical CI output compresses to about a tenth":
    var b = newB()
    var blocks: seq[LogBlock]
    var rawLen = 0
    for i in 0 ..< 20000:
      let l = "[" & $i & "] compiling src/module_" & $(i mod 300) & "/file.nim took " & $(i mod 977) & "ms"
      rawLen += l.len + 1
      blocks.add b.feed(l & "\n", 1)
    blocks.add b.flush(1)
    let packed = blocks.mapIt(it.data.len).foldl(a + b)
    check packed * 100 < rawLen * 30

suite "secrets (DAT-002 in the shim)":
  test "known values are masked before compression, in every position":
    var b = newB(@["s3cr3t-token", "hunter22"])
    let m = msgs(b.feed("login s3cr3t-token ok\nhunter22 and hunter22\nnothing here\n", 1) & b.flush(1))
    check m == @["login *** ok", "*** and ***", "nothing here"]

  test "the plain secret is not present anywhere in the compressed block":
    var b = newB(@["Zq9-very-secret"])
    let blocks = b.feed("password=Zq9-very-secret\n", 1) & b.flush(1)
    check "Zq9-very-secret" notin uncompress(blocks[0].data)

  test "values shorter than minSecretLen are left alone (they would mangle ordinary output)":
    var b = newB(@["ab", "abc"])
    check msgs(b.feed("abc abcd\n", 1) & b.flush(1)) == @["abc abcd"]

suite "spool files":
  let dir = getTempDir() / "tlogspool-" & $getCurrentProcessId()
  setup: initSpool(dir)
  teardown: removeDir(dir)

  proc blk(seq: uint64; size: int): LogBlock =
    LogBlock(seq: seq, firstLn: (seq - 1) * 10, lines: 10, encoding: "gzip", data: 'q'.repeat(size))

  test "blocks come back in seq order with their metadata and bytes":
    add(dir, blk(2, 30)); add(dir, blk(1, 20)); add(dir, blk(3, 10))
    let q = peek(dir, maxBlocks = 10)
    check q.mapIt(it.blk.seq) == @[1'u64, 2, 3]
    check q[1].blk.firstLn == 10 and q[1].blk.lines == 10 and q[1].blk.encoding == "gzip"
    check q[0].blk.data == 'q'.repeat(20)
    check spoolBytes.load == 60

  test "removing an acknowledged block frees its bytes; the rest stays queued":
    add(dir, blk(1, 100)); add(dir, blk(2, 50))
    peek(dir, 1)[0].remove()
    check spoolBytes.load == 50
    check peek(dir).mapIt(it.blk.seq) == @[2'u64]
    peek(dir)[0].remove()
    check spoolBytes.load == 0 and isEmpty(dir)

  test "a batch respects its block and byte limits but always carries at least one block":
    for i in 1'u64 .. 5: add(dir, blk(i, 100))
    check peek(dir, maxBlocks = 3, maxBytes = 10_000).len == 3
    check peek(dir, maxBlocks = 10, maxBytes = 250).len == 2
    check peek(dir, maxBlocks = 10, maxBytes = 10).len == 1

  test "the size limit: a block that does not fit waits (backpressure) - except into an empty spool":
    check fits(100, blk(1, 500))                     # empty: always, or a big block could never be written
    add(dir, blk(1, 60))
    check fits(100, blk(2, 40))
    check not fits(100, blk(2, 41))
    peek(dir)[0].remove()
    check fits(100, blk(2, 100))

  test "stale files of an earlier run are never resumed":
    writeFile(dir / "000000000007-0-1-gzip.blk", "old")
    initSpool(dir)
    check isEmpty(dir) and spoolBytes.load == 0

suite "UTF-8: allowed, safely truncated":
  test "valid UTF-8 passes unchanged":
    check safeText("héllo, wörld — 日本語 🚀") == "héllo, wörld — 日本語 🚀"
  test "only the bad bytes are replaced, the rest of the line keeps its text":
    check safeText("ok \xFF héllo \xC0\xAF end") == "ok \xEF\xBF\xBD héllo \xEF\xBF\xBD\xEF\xBF\xBD end"
    check safeText("\xED\xA0\x80") == "\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD"      # a UTF-16 surrogate is not UTF-8
    check safeText("a\xE2\x82") == "a\xEF\xBF\xBD\xEF\xBF\xBD"                      # truncated sequence
    check validateUtf8(safeText("\xF4\x90\x80\x80 \xF8\x88\x80\x80\x80")) < 0       # above U+10FFFF / 5-byte: all replaced
  test "a long line is split between characters, never inside one":
    var b = newB()
    let line = repeat("é", maxLineBytes)            # 2 bytes each: a cut at exactly maxLineBytes is on a boundary ...
    let odd = "x" & repeat("é", maxLineBytes)       # ... here the naive cut lands in the middle of a letter
    var blocks = b.feed(odd & "\n", 1) & b.flush(1)
    let rs = msgs(blocks)
    check rs.len == 3                                # 65537 bytes, cut at character boundaries
    for m in rs: check validateUtf8(m) < 0 and "\xEF\xBF\xBD" notin m
    check rs.join == odd
    discard line
  test "a 4-byte emoji straddling the cut survives intact":
    var b = newB()
    let s = repeat("a", maxLineBytes - 2) & repeat("🚀", 5)
    let rs = msgs(b.feed(s & "\n", 1) & b.flush(1))
    check rs.join == s
    for m in rs: check validateUtf8(m) < 0
  test "a character split across two reads is not mistaken for bad bytes":
    var b = newB()
    check b.feed("\xE2\x82", 1).len == 0
    check msgs(b.feed("\xAC\n", 1) & b.flush(1)) == @["€"]
  test "a runaway line without newline waits with an incomplete tail":
    var b = newB()
    let junk = repeat("z", maxLineBytes * 4 + 10)
    let blocks = b.feed(junk & "\xE2\x82", 1) & b.flush(1)
    check (msgs(blocks)).join == junk
    check msgs(b.feed("\xAC\n", 1) & b.flush(1)) == @["€"]
  test "completeLen / charBoundary":
    check completeLen("abc") == 3
    check completeLen("ab\xE2\x82") == 2
    check completeLen("ab\xE2\x82\xAC") == 5
    check completeLen("ab\xF0\x9F") == 2
    check charBoundary("ab\xD1\x8F", 3) == 2
    check charBoundary("abcdef", 3) == 3

suite "log_max_bytes: the step's log is cut with a marker":
  test "past the limit one marker line is stored, the rest is counted and dropped":
    var b = newBuilder("ci-x", "s1_r", 1_000_000, maxBytes = 1000)
    var blocks: seq[LogBlock]
    for i in 0 ..< 100: blocks.add b.feed("line number " & $i & " with some padding text\n", 1)
    blocks.add b.flush(2, final = true)
    let m = msgs(blocks)
    check b.truncated
    check m[^1].startsWith("[cicd: log truncated")
    check "limit of 1000 bytes" in m[^1]
    check m.len < 30 and m.len > 5                       # stored: what fitted, plus the marker
    check b.droppedLines > 60
    check b.linesWritten == uint64(m.len)
  test "no limit (0) stores everything":
    var b = newBuilder("ci-x", "s1_r", 1_000_000)
    var blocks: seq[LogBlock]
    for i in 0 ..< 1000: blocks.add b.feed("line number " & $i & "\n", 1)
    blocks.add b.flush(2, final = true)
    check msgs(blocks).len == 1000 and not b.truncated
  test "ln stays gap-free across the marker":
    var b = newBuilder("ci-x", "s1_r", 1_000_000, maxBytes = 200)
    var blocks = b.feed(repeat("0123456789\n", 40), 1)
    blocks.add b.flush(2, final = true)
    var lns: seq[int]
    for blk in blocks:
      for r in records(blk): lns.add r["ln"].getInt
    check lns == toSeq(0 ..< lns.len)
