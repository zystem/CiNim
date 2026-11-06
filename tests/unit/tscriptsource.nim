## D-63: the script of a run read from a repository, against repositories made here (git over file://, which the tests allow and the core does not by default).
import std/[unittest, os, osproc, strutils, sequtils, net, times]
import ../../src/common/scriptsource

proc run(dir: string; cmd: string) =
  let (o, c) = execCmdEx(cmd, workingDir = dir)
  doAssert c == 0, cmd & ": " & o

let root = getTempDir() / "tscriptsource"
removeDir root
createDir root
let repo = root / "repo"
createDir repo
run repo, "git init -q -b main"
run repo, "git config user.email t@example.test && git config user.name t"
createDir repo / ".ci"
writeFile repo / ".ci" / "pipeline.lua", "return ci.pipeline{ name = 'one' }\n"
writeFile repo / "other.lua", "return 2\n"
writeFile repo / "big.lua", "x".repeat(maxScriptBytes + 1)
run repo, "git add -A && git commit -q -m one"
let first = execProcess("git rev-parse HEAD", workingDir = repo).strip
writeFile repo / ".ci" / "pipeline.lua", "return ci.pipeline{ name = 'two' }\n"
run repo, "git commit -q -am two && git tag v1"
let second = execProcess("git rev-parse HEAD", workingDir = repo).strip
let url = "file://" & repo

proc get(commit = ""; path = ""; repository = url): Fetched =
  fetchScript(Source(repository: repository, commit: commit, path: path), timeoutSeconds = 20, transports = "file", schemes = ["file://"])

suite "D-82 the entries of the source that the core hands to the script":
  test "the repository, the commit, the path and the base (the last good commit) are four entries no declared name can be":
    check sourceParams("https://x/r.git", "c1", ".ci/p.lua", "b0") == @[("@source.repository", "https://x/r.git"), ("@source.commit", "c1"), ("@source.path", ".ci/p.lua"), ("@source.base", "b0")]
    check sourceParams("https://x/r.git", "c1", ".ci/p.lua").len == 4 and sourceParams("https://x/r.git", "c1", ".ci/p.lua")[3] == ("@source.base", "")
    check sourceKeys.len == 4 and sourceKeys.allIt(it.startsWith("@source."))

suite "D-63 a script read from a repository":
  test "the default path at a branch: the text and the SHA the branch is at":
    let f = get("main")
    check f.ok and "'two'" in f.script and f.commit == second
  test "a commit by its SHA, a tag, and no name at all (HEAD) give the commit they name":
    check get(first).script.contains("'one'") and get(first).commit == first
    check get("v1").commit == second
    check get().commit == second
  test "another path":
    check get("main", "other.lua").script == "return 2\n"
  test "a missing file, a missing commit, a file too big":
    check get("main", "nothing.lua").code == "script_missing"
    check get("no-such-branch").code == "fetch_failed"
    let big = get("main", "big.lua")
    check big.code == "script_too_large" and big.commit == second
  test "what is not a repository URL, a commit name or a path is refused before git is run":
    check fetchScript(Source(repository: "ssh://git@example.test/x.git")).code == "invalid_source"
    check fetchScript(Source(repository: "file:///etc")).code == "invalid_source"
    check fetchScript(Source(repository: "https://example.test/x.git", commit: "--upload-pack=x")).code == "invalid_source"
    check fetchScript(Source(repository: "https://example.test/x.git", commit: "a..b")).code == "invalid_source"
    check fetchScript(Source(repository: "https://example.test/x.git", path: "../etc/passwd")).code == "invalid_source"
    check fetchScript(Source(repository: "https://example.test/x.git", path: "/etc/passwd")).code == "invalid_source"
    check fetchScript(Source(repository: "https://example.test/x y.git")).code == "invalid_source"
  test "the transports the core allows are the only ones: file:// is refused by default":
    let f = fetchScript(Source(repository: "file://" & repo & "/", commit: "main"))
    check not f.ok
  test "D-76 the commit a branch, a tag or HEAD is at is read without fetching anything":
    proc at(ref0: string; repository = url): Fetched = resolveRef(repository, ref0, timeoutSeconds = 20, transports = "file", schemes = ["file://"])
    check at("main").commit == second and at("main").ok and at("v1").commit == second and at("").commit == second and at("HEAD").commit == second
    run repo, "git branch side " & first
    check at("side").commit == first                                   # a branch, not the tag or the branch of another name that ends the same
    check at(second).commit == second                                  # a SHA names itself
    check at("no-such-branch").code == "fetch_failed"
    check at("main", "file://" & root & "/nothing").code == "fetch_failed"
  test "D-76 a ref is refused before git is run when it is not a name":
    check resolveRef("https://example.test/x.git", "--upload-pack=x").code == "invalid_source"
    check resolveRef("ssh://git@example.test/x.git", "main").code == "invalid_source"
  test "nothing is left behind":
    check walkDir(getTempDir()).toSeq.filterIt("cinim-script-" in it.path).len == 0
  test "a repository that does not answer in time is given up at the deadline":
    # a socket that listens and never accepts: the connection is made and nothing comes back
    var sock = newSocket()
    sock.bindAddr(Port(0), "127.0.0.1")
    sock.listen()
    let port = sock.getLocalAddr()[1]
    let t0 = epochTime()
    let f = fetchScript(Source(repository: "http://127.0.0.1:" & $port & "/x.git", commit: "main"), timeoutSeconds = 3, transports = "http")
    sock.close()
    check f.code == "fetch_failed" and "did not answer" in f.message and epochTime() - t0 < 12

# PRJ-004, D-82: the paths that differ between the commit of the last good run (the base) and the commit of this run
let repo2 = root / "repo2"
createDir repo2
run repo2, "git init -q -b main"
run repo2, "git config user.email t@example.test && git config user.name t"
createDir repo2 / "src" / "core"
createDir repo2 / "docs"
createDir repo2 / ".ci"
writeFile repo2 / "src" / "core" / "a.nim", "a\n"
writeFile repo2 / "src" / "b.nim", "b\n"
writeFile repo2 / "docs" / "x.md", "x\n"
writeFile repo2 / "gone.txt", "g\n"
writeFile repo2 / ".ci" / "pipeline.lua", "return 1\n"
run repo2, "git add -A && git commit -q -m c1"
let c1 = execProcess("git rev-parse HEAD", workingDir = repo2).strip
writeFile repo2 / "src" / "core" / "a.nim", "a2\n"            # changed
writeFile repo2 / "docs" / "new file with spaces.md", "n\n"       # added, a name with spaces
removeFile repo2 / "gone.txt"                                         # deleted
run repo2, "git add -A && git commit -q -m c2 && git tag base-tag"
let c2 = execProcess("git rev-parse HEAD", workingDir = repo2).strip
writeFile repo2 / "src" / "b.nim", "b3\n"
run repo2, "git commit -q -am c3"
let c3 = execProcess("git rev-parse HEAD", workingDir = repo2).strip
let url2 = "file://" & repo2

proc changed(base, commit: string; maxPaths = 5000; repository = url2): Changed =
  changedPaths(repository, base, commit, timeoutSeconds = 20, transports = "file", schemes = ["file://"], maxPaths = maxPaths)

suite "PRJ-004 the paths that changed between the base and the commit":
  test "a change, an addition and a deletion are paths, in order, and the two commits are named by their SHAs":
    let c = changed(c1, c2)
    check c.ok and not c.truncated
    check c.paths == @["docs/new file with spaces.md", "gone.txt", "src/core/a.nim"]
    check c.base == c1 and c.commit == c2
  test "the base may be a name, and the commits need no history in common with each other or a fetch of the history":
    let c = changed("base-tag", c3)
    check c.ok and c.paths == @["src/b.nim"] and c.base == c2
    check changed(c1, c3).paths == @["docs/new file with spaces.md", "gone.txt", "src/b.nim", "src/core/a.nim"]
  test "the same commit changes nothing":
    let c = changed(c2, c2)
    check c.ok and c.paths.len == 0
  test "a list longer than the limit is cut, and says so":
    let c = changed(c1, c3, maxPaths = 2)
    check c.ok and c.truncated and c.paths == @["docs/new file with spaces.md", "gone.txt"]
  test "a base that is not in the repository is a failure with a code, and so is a repository that is not one":
    let c = changed("0000000000000000000000000000000000000001", c2)
    check not c.ok and c.code == "fetch_failed" and c.message.len > 0
    check changed(c1, "no-such-branch").code == "fetch_failed"
    check changed(c1, c2, repository = "https://127.0.0.1:1/none.git").ok == false
  test "what git would take for an option, and a repository that is not a URL, are refused before git is run":
    check changed("--upload-pack=x", c2).code == "invalid_source"
    check changed(c1, "-x").code == "invalid_source"
    check changed(c1, c2, repository = "/etc/passwd").code == "invalid_source"

