## The shim's part of the artifacts (DAT-003): patterns, the files found, the hash, and the transfer against a small server of the test's own.
import std/[sequtils, unittest, os, strutils, tempfiles, json]
import shim/artifacts

suite "DAT-003 artifact patterns":
  test "DAT-003 * stays inside a name, ** crosses directories, ? is one character":
    check globMatch("dist/*.txt", "dist/a.txt")
    check not globMatch("dist/*.txt", "dist/sub/a.txt")
    check globMatch("dist/**", "dist/sub/deeper/a.txt")
    check globMatch("dist/**/a.txt", "dist/a.txt")
    check globMatch("dist/**/a.txt", "dist/x/y/a.txt")
    check globMatch("**/a.txt", "a.txt")
    check globMatch("**/*.log", "x/y/z.log")
    check globMatch("a?c", "abc")
    check not globMatch("a?c", "a/c")
    check not globMatch("dist/*", "other/a")
    check globMatch("app", "app")
    check not globMatch("app", "app2")

  test "DAT-003 a pattern with many wildcards on a long name does not take exponential time":
    check not globMatch("*a*a*a*a*a*a*a*a*b", "a".repeat(300))
    check not globMatch("**a**a**a**a**a**b", "a".repeat(300))

suite "DAT-003 finding the files":
  test "DAT-003 the files that match, sorted, without the run directory, links or directories":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    createDir(root / "dist" / "sub")
    createDir(root / ".run")
    writeFile(root / "dist" / "b.txt", "b")
    writeFile(root / "dist" / "a.txt", "a")
    writeFile(root / "dist" / "sub" / "c.txt", "c")
    writeFile(root / ".run" / "CICD_ENV", "X=1")
    writeFile(root / "other.bin", "o")
    createSymlink(root / "other.bin", root / "dist" / "link")
    let c = collectFiles(root, @["dist/**"])
    check c.error == ""
    check c.files == @["dist/a.txt", "dist/b.txt", "dist/sub/c.txt"]
    check collectFiles(root, @["**"]).files.find(".run/CICD_ENV") < 0

  test "DAT-003 a pattern that matches nothing is an error that names it":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    writeFile(root / "a", "x")
    let c = collectFiles(root, @["a", "nothing/**"])
    check "nothing/**" in c.error

  test "DAT-003 the SHA-256 of a file is the usual one, also over several blocks":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    writeFile(root / "abc", "abc")
    check fileSha256(root / "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    writeFile(root / "big", "a".repeat(200_000))
    check fileSha256(root / "big") == "2287d207f24a941ff3b56c04c8a25ad56b63e3023207b3bb5b4ac0c9869d74be"

suite "DAT-003 blocks and the manifest":
  test "DAT-003 a block is read from an offset, short at the end of the file":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    writeFile(root / "f", "0123456789")
    check readBlock(root / "f", 0, 4) == "0123"
    check readBlock(root / "f", 6, 4) == "6789"
    check readBlock(root / "f", 8, 100) == "89"

  test "DAT-003 the manifest keeps what is still to be delivered, and a missing or damaged one says nothing":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    let m = root / "artifacts.manifest"
    check readManifest(m).len == 0
    writeManifest(m, @[ManifestFile(path: "dist/a", size: 3, sha256: "ab"), ManifestFile(path: "b", size: 0, sha256: "cd")])
    let back = readManifest(m)
    check back.len == 2 and back[0].path == "dist/a" and back[0].size == 3 and back[1].sha256 == "cd"
    writeFile(m, "{broken")
    check readManifest(m).len == 0

  test "DAT-003 files are delivered in turn, the manifest loses each one as soon as it is delivered and is removed after the last (no iteration over a list that changes)":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    let m = root / "artifacts.manifest"
    let files = @[ManifestFile(path: "a", size: 1, sha256: "x"), ManifestFile(path: "b", size: 2, sha256: "y"), ManifestFile(path: "c", size: 3, sha256: "z")]
    writeManifest(m, files)
    var put, seen: seq[string]
    let r = deliverFiles(m, files, proc (f: ManifestFile): tuple[ok, retry: bool; detail: string] =
      put.add f.path
      (true, false, ""), proc (f: ManifestFile) = seen.add f.path)
    check r.ok and put == @["a", "b", "c"] and seen == put
    check not fileExists(m)
  test "DAT-003 a file that is not accepted stops the delivery there: the ones before it are off the manifest, it and the rest stay, and the answer says which":
    let root = createTempDir("art", "")
    defer: removeDir(root)
    let m = root / "artifacts.manifest"
    let files = @[ManifestFile(path: "a", size: 1, sha256: "x"), ManifestFile(path: "b", size: 2, sha256: "y"), ManifestFile(path: "c", size: 3, sha256: "z")]
    writeManifest(m, files)
    let r = deliverFiles(m, files, proc (f: ManifestFile): tuple[ok, retry: bool; detail: string] =
      if f.path == "b": (false, true, "store_unavailable") else: (true, false, ""))
    check not r.ok and r.retry and r.path == "b" and r.detail == "store_unavailable"
    check readManifest(m).mapIt(it.path) == @["b", "c"]
    let refused = deliverFiles(m, readManifest(m), proc (f: ManifestFile): tuple[ok, retry: bool; detail: string] = (false, false, "quota_exceeded"))
    check not refused.ok and not refused.retry and refused.path == "b" and readManifest(m).len == 2

suite "DAT-003 the declaration in the step's options":
  test "DAT-003 an option with only an upload list (no download list) is read without a crash":
    let d = declaredArtifacts(parseJson("""{"artifacts":{"upload":["dist/**"]},"timeout":5}"""))
    check d.upload == @["dist/**"] and d.download.len == 0
    let e = declaredArtifacts(parseJson("""{"artifacts":{"download":["app","dist"]}}"""))
    check e.upload.len == 0 and e.download == @["app", "dist"]

  test "DAT-003 no artifacts, or something that is not a declaration, declares nothing":
    for j in ["""{}""", """{"artifacts":null}""", """{"artifacts":[]}""", """{"artifacts":{"upload":"x","download":5}}""", """{"artifacts":{"upload":[1,null]}}"""]:
      let d = declaredArtifacts(parseJson(j))
      check d.upload.len == 0 and d.download.len == 0
    check declaredArtifacts(nil).upload.len == 0
