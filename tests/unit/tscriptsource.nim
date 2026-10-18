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
