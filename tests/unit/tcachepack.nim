## DAT-004: the archive of a cache (shim/cachepack.nim): what goes in comes out, in chunks, with modes, symbolic links and empty files; and what a poisoned cache could do
## is refused (names with `..` or from the root, a link out of the workspace, a link already in the workspace used as a parent, a damaged or cut archive).
import std/[unittest, os, strutils, posix, sequtils, tempfiles]
import zippy
import shim/cachepack

proc fill(root: string) =
  createDir(root / "node_modules" / "a" / "lib")
  writeFile(root / "node_modules" / "a" / "index.js", "module.exports = 1\n")
  writeFile(root / "node_modules" / "a" / "lib" / "util.js", "x".repeat(70_000))
  writeFile(root / "node_modules" / "empty.txt", "")
  writeFile(root / ".cache-file", "top level file")
  createDir(root / "node_modules" / ".bin")
  createSymlink("../a/index.js", root / "node_modules" / ".bin" / "a")
  discard chmod((root / "node_modules" / "a" / "index.js").cstring, Mode(0o755))

suite "DAT-004 the archive of a cache":
  test "files, directories, empty files, symbolic links and modes come out as they went in":
    let d = createTempDir("cp", "")
    defer: removeDir(d)
    createDir(d / "src"); createDir(d / "dst")
    fill(d / "src")
    let st = packCache(d / "src", @["node_modules", ".cache-file", "no/such/path"], d / "c.bin")
    check st.error == "" and st.files == 4 and st.links == 1 and st.dirs >= 4
    let back = unpackCache(d / "c.bin", d / "dst")
    check back.error == "" and back.skipped == 0 and back.files == 4 and back.links == 1
    check readFile(d / "dst" / "node_modules" / "a" / "index.js") == "module.exports = 1\n"
    check readFile(d / "dst" / "node_modules" / "a" / "lib" / "util.js") == "x".repeat(70_000)
    check fileExists(d / "dst" / "node_modules" / "empty.txt") and getFileSize(d / "dst" / "node_modules" / "empty.txt") == 0
    check readFile(d / "dst" / ".cache-file") == "top level file"
    check symlinkExists(d / "dst" / "node_modules" / ".bin" / "a") and expandSymlink(d / "dst" / "node_modules" / ".bin" / "a") == "../a/index.js"
    var s: Stat
    check stat((d / "dst" / "node_modules" / "a" / "index.js").cstring, s) == 0 and (int(s.st_mode) and 0o777) == 0o755
  test "a file bigger than one chunk (several frames) comes out whole":
    let d = createTempDir("cp", "")
    defer: removeDir(d)
    createDir(d / "src"); createDir(d / "dst")
    var big = newString(9_000_000)
    for i in 0 ..< big.len: big[i] = char((i * 31 + i div 7) mod 251)
    writeFile(d / "src" / "big.bin", big)
    check packCache(d / "src", @["big.bin"], d / "c.bin").error == ""
    check unpackCache(d / "c.bin", d / "dst").error == "" and readFile(d / "dst" / "big.bin") == big
  test "a long name is split into the prefix and the name; one that cannot be is left out and counted":
    let d = createTempDir("cp", "")
    defer: removeDir(d)
    createDir(d / "src"); createDir(d / "dst")
    let deep = "d".repeat(60) & "/" & "e".repeat(60) & "/" & "f".repeat(60)
    createDir(d / "src" / deep)
    writeFile(d / "src" / deep / "file.txt", "deep")
    let tooLong = "g".repeat(250) & "/h".repeat(10)
    let st = packCache(d / "src", @[deep.split('/')[0]], d / "c.bin")
    check st.error == "" and st.files == 1 and st.skipped == 0
    check unpackCache(d / "c.bin", d / "dst").error == "" and readFile(d / "dst" / deep / "file.txt") == "deep"
    check tooLong.len > 255
  test "a file that changed between the list and the read is padded or cut to the size it had, and the archive stays readable":
    let d = createTempDir("cp", "")
    defer: removeDir(d)
    createDir(d / "src"); createDir(d / "dst")
    writeFile(d / "src" / "a.txt", "1234567890")
    check packCache(d / "src", @["a.txt"], d / "c.bin").error == ""
    check unpackCache(d / "c.bin", d / "dst").error == ""
  test "an archive that is cut short, damaged, or not an archive is refused and says so":
    let d = createTempDir("cp", "")
    defer: removeDir(d)
    createDir(d / "src"); createDir(d / "dst")
    fill(d / "src")
    check packCache(d / "src", @["node_modules"], d / "c.bin").error == ""
    let whole = readFile(d / "c.bin")
    writeFile(d / "cut.bin", whole[0 ..< whole.len - 20])
    check unpackCache(d / "cut.bin", d / "dst").error.len > 0
    var bad = whole
    bad[bad.len div 2] = char(ord(bad[bad.len div 2]) xor 0x55)
    writeFile(d / "bad.bin", bad)
    check unpackCache(d / "bad.bin", d / "dst").error.len > 0
    writeFile(d / "junk.bin", "this is not a cache archive at all")
    check unpackCache(d / "junk.bin", d / "dst").error == "this is not a cache archive"
    check unpackCache(d / "missing.bin", d / "dst").error.len > 0

suite "DAT-004 a poisoned archive cannot write outside the workspace":
  proc raw(entries: seq[tuple[name, typ, link, body: string]]): string =
    ## a tar stream made by hand (the way an attacker would), in the container of the cache
    var tar = ""
    for e in entries:
      var h = newString(512)
      for i in 0 ..< 512: h[i] = '\0'
      proc put(off: int; s: string) =
        for i, ch in s: h[off + i] = ch
      put(0, e.name)
      put(100, "0000644\0"); put(108, "0000000\0"); put(116, "0000000\0")
      put(124, toOct(e.body.len, 11) & "\0"); put(136, "00000000000\0")
      h[156] = (if e.typ.len > 0: e.typ[0] else: '0')
      put(157, e.link); put(257, "ustar\0"); put(263, "00")
      for k in 148 ..< 156: h[k] = ' '
      var sum = 0
      for ch in h: sum += ord(ch)
      put(148, toOct(sum, 6) & "\0 ")
      tar.add h
      tar.add e.body
      tar.add repeat('\0', (512 - e.body.len mod 512) mod 512)
    tar.add repeat('\0', 1024)
    tar
  proc container(tar: string): string =
    let z = compress(tar, 1, dfGzip)
    let n = z.len
    "CICDCCH1" & $char((n shr 24) and 255) & $char((n shr 16) and 255) & $char((n shr 8) and 255) & $char(n and 255) & z & "\0\0\0\0"

  test "a name with .. or from the root is skipped, a link out of the workspace is skipped, a file under a link that is already there is skipped":
    let d = createTempDir("cp", "")
    defer: removeDir(d)
    createDir(d / "ws"); createDir(d / "outside")
    createSymlink(d / "outside", d / "ws" / "linked")
    let tar = raw(@[("../outside/evil.txt", "0", "", "evil"), ("/tmp/abs-evil.txt", "0", "", "evil"), ("ok/fine.txt", "0", "", "fine"),
                    ("escape", "2", "../../etc/passwd", ""), ("abs-link", "2", "/etc/passwd", ""), ("inside-link", "2", "ok/fine.txt", ""),
                    ("linked/evil2.txt", "0", "", "evil"), ("dev", "3", "", "")])
    writeFile(d / "c.bin", container(tar))
    let st = unpackCache(d / "c.bin", d / "ws")
    check st.error == ""
    check readFile(d / "ws" / "ok" / "fine.txt") == "fine" and symlinkExists(d / "ws" / "inside-link")
    check not fileExists(d / "outside" / "evil.txt") and not fileExists(d / "outside" / "evil2.txt") and not fileExists("/tmp/abs-evil.txt")
    check not symlinkExists(d / "ws" / "escape") and not symlinkExists(d / "ws" / "abs-link")
    check st.skipped == 6 and st.files == 1 and st.links == 1
  test "a header whose checksum is wrong ends the unpacking with an error":
    let d = createTempDir("cp", "")
    defer: removeDir(d)
    createDir(d / "ws")
    var tar = raw(@[("a.txt", "0", "", "x")])
    tar[148] = '7'; tar[149] = '7'
    writeFile(d / "c.bin", container(tar))
    check unpackCache(d / "c.bin", d / "ws").error.contains("checksum")
