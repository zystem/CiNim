## DAT-003, D-57 (docs/store.md): how the store node names a file for a key. Every segment of a key becomes one safe file name, the name can be turned back into the key, a name that is
## too long keeps a readable start and a hash, and a key that could be a trick (`..`, an empty segment, a control character) is refused and never rewritten. Pure.
import std/[unittest, strutils, sequtils]
import storage/layout

suite "D-57 the escape of a segment":
  test "letters, digits and - _ . + = @ , ( ) stay, a space inside stays":
    for s in ["app.txt", "a-b_c", "x+y=z@h,(1)", "with space inside", "v1.2.3"]:
      check escapeSegment(s) == s
  test "everything else becomes %XX, upper case hex, byte by byte":
    check escapeSegment("a?b") == "a%3Fb"
    check escapeSegment("q\"s") == "q%22s"
    check escapeSegment("hash#tag") == "hash%23tag"
    check escapeSegment("100%") == "100%25"
    check escapeSegment("ключ") == "%D0%BA%D0%BB%D1%8E%D1%87"
    check escapeSegment("a\tb") == "a%09b"
    check escapeSegment("back\\slash") == "back%5Cslash"
    check escapeSegment("a~b") == "a%7Eb"
  test "a leading dot, a trailing dot and a space at either end are escaped: nothing is hidden or special":
    check escapeSegment(".hidden") == "%2Ehidden"
    check escapeSegment("ends.") == "ends%2E"
    check escapeSegment(" lead") == "%20lead"
    check escapeSegment("trail ") == "trail%20"
    check escapeSegment("..") == "%2E%2E"
    check escapeSegment(".") == "%2E"
  test "an escaped name is turned back into the segment it was":
    for s in [".hidden", "ends.", " x ", "a?b#c%d", "ключ-鍵-🔑", "tab\tname", "a~b", "plain", "x" & '\0' & "y"]:
      let u = unescapeSegment(escapeSegment(s))
      check u.ok and u.exact and u.text == s
  test "a name that is not an escape of anything is not turned back":
    check not unescapeSegment("100%").ok
    check not unescapeSegment("%G1").ok
    check not unescapeSegment("a%2").ok
  test "a segment whose escape is over 200 bytes keeps 120 readable bytes, ~ and 24 hex digits of its hash":
    let long = "a".repeat(900)
    let e = escapeSegment(long)
    check e.len == 120 + 1 + 24 and e.startsWith("a".repeat(120) & "~")
    check e != escapeSegment("a".repeat(901))
    let u = unescapeSegment(e)
    check u.ok and not u.exact and u.text == "a".repeat(120)
    let wide = escapeSegment("ключ".repeat(40))              # 6 bytes of escape per letter: the cut must not split a %XX
    check wide.len <= 200 and "~" in wide
    check not unescapeSegment(wide).text.contains("%")
  test "a name of exactly 200 bytes is not shortened, one of 201 is":
    check escapeSegment("b".repeat(200)) == "b".repeat(200)
    check "~" in escapeSegment("b".repeat(201))
  test "two long segments with the same start do not meet":
    check escapeSegment("a".repeat(300) & "1") != escapeSegment("a".repeat(300) & "2")

suite "D-57 the keys":
  test "a good key":
    check validKey("acme/s1_01a1/dist/app.txt") == ""
    check validKey("t/cache/_/abcdef") == ""
    check validKey("x") == ""
  test "what is refused, with a reason, and never rewritten":
    for k in ["", "/lead", "trail/", "a//b", "a/./b", "a/../b", "..", ".", "a/b/..", "has\x01control", "del\x7f", "nul\0byte", "a".repeat(1025)]:
      check validKey(k).len > 0
  test "1024 bytes is the longest key":
    check validKey("a".repeat(1024)) == ""
    check validKey("a/".repeat(512)[0 ..< 1023]) == ""
  test "a key is a path of escaped segments and back":
    let k = "acme/s1_x/odd dir/q?mark/ключ/.hidden/ends."
    let rel = keyToRel(k)
    check rel == "acme/s1_x/odd dir/q%3Fmark/%D0%BA%D0%BB%D1%8E%D1%87/%2Ehidden/ends%2E"
    let back = relToKey(rel)
    check back.exact and back.key == k
  test "the path of a key with a long segment is readable at the start, and is not exact the other way":
    let k = "t/r/" & "z".repeat(500) & "/file"
    let back = relToKey(keyToRel(k))
    check not back.exact and back.key.startsWith("t/r/" & "z".repeat(120)) and back.key.endsWith("/file")
  test "no escaped segment is `.`, `..`, empty, or starts with a dot":
    for s in [".", "..", "...", ".a", "a.", ""]:
      let e = escapeSegment(s)
      check e != "." and e != ".." and not e.startsWith(".") and (s.len == 0 or e.len > 0)
