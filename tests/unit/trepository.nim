## The rules of CLAUDE.md that are kept by memory, kept by a test instead: what the owner and the assistant once paid time for, and what is easy to write again.
##   * every HTTP server is made with `newService` of src/common/httpsrv.nim, not with `newHttpServer` (GuildenStern 9.0.1 closed connections; "Things that cost time");
##   * `pkill -f` is never written (it kills what its pattern happens to match: the hook refuses it in a session, and a script would not be stopped by the hook);
##   * no proc, func, const, template, iterator or macro is named `declared` (a magic of Nim);
##   * the repository holds no tokens: the shapes of the common ones (GitHub, GitLab, Slack, AWS) and private keys are looked for (a test vector is listed below with the reason);
##   * the repository holds no private addresses, host names or cluster names: those are the owner's, so they are not in this file either. A list of regular words, one per line, is read from
##     `$CINIM_PRIVATE_WORDS_FILE` or `~/.config/cinim/private-words` and the test fails when a tracked file holds one; without the file this part is skipped (it says so).
## The rules are procs that take a path and a text and answer the lines they refuse, so that the first suite proves that each one sees a violation (a rule that sees nothing is worse than none);
## the second reads the repository.
import std/[unittest, os, strutils, sequtils, json, re]

type Finding = tuple[file: string, line: int, what: string]

proc code(line: string): string =
  ## the line without its `#` comment (a `#` inside a string is cut too: a rule may miss a violation in a string after it, never invent one)
  let h = line.find('#')
  if h >= 0: line[0 ..< h] else: line

proc isIdent(c: char): bool = c in IdentChars

proc hasWord(s, word: string): bool =
  ## `word` stands in `s` with no identifier character on either side
  var at = 0
  while true:
    let i = s.find(word, at)
    if i < 0: return false
    let before = i == 0 or not isIdent(s[i - 1])
    let after = i + word.len >= s.len or not isIdent(s[i + word.len])
    if before and after: return true
    at = i + 1

proc newHttpServerCalls*(path, text: string): seq[Finding] =
  ## `newHttpServer(` outside src/common/httpsrv.nim
  if path.endsWith("src/common/httpsrv.nim") or not path.endsWith(".nim"): return
  for n, raw in toSeq(text.splitLines):
    if raw.code.contains("newHttpServer("):
      result.add (path, n + 1, "newHttpServer: make a server with newService of src/common/httpsrv.nim")

proc pkillF*(path, text: string): seq[Finding] =
  ## `pkill` with a flag that holds `f` (`-f`, `-xf`, `--full`)
  for n, raw in toSeq(text.splitLines):
    let words = raw.splitWhitespace
    for i, w in words:
      if w == "pkill" or w.endsWith("/pkill"):
        for a in words[i + 1 .. ^1]:
          if a == "--full" or (a.len > 1 and a[0] == '-' and a[1] != '-' and 'f' in a): result.add (path, n + 1, "pkill -f: use pkill -x <name> or a PID")
          if not a.startsWith("-"): break

proc declaredName*(path, text: string): seq[Finding] =
  ## a proc, func, const, template, iterator or macro called `declared`
  if not path.endsWith(".nim"): return
  for n, raw in toSeq(text.splitLines):
    let words = raw.code.splitWhitespace
    if words.len >= 2 and words[0].strip(chars = {'*'}) in ["proc", "func", "const", "template", "iterator", "macro", "method", "converter"]:
      var name = words[1]
      for stop in ['*', '(', '[', ':', '=']:
        let k = name.find(stop)
        if k >= 0: name = name[0 ..< k]
      if name == "declared": result.add (path, n + 1, "`declared` is a magic of Nim: another name")

const
  knownTestVectors = ["AKIAIOSFODNN7EXAMPLE"]       ## the example key of AWS's own documentation (the SigV4 test of tsigv4)
  keyAllowedIn = ["tests/certs/", "tests/vectors/"]

proc runOf(s: string; at: int; ok: proc (c: char): bool): int =
  ## how many characters from `at` satisfy `ok`
  while at + result < s.len and ok(s[at + result]): inc result

proc tokenShapes*(path, text: string): seq[Finding] =
  ## the shapes of tokens: GitHub (`ghp_`, `gho_`, `ghs_`, `github_pat_`), GitLab (`glpat-`), Slack (`xoxb-`, `xoxp-`), AWS (`AKIA` and 16 capitals or digits), and a private key block
  let alnum = proc (c: char): bool = c in Letters + Digits
  let tail = proc (c: char): bool = c in Letters + Digits + {'_', '-'}
  let cap = proc (c: char): bool = c in {'A'..'Z', '0'..'9'}
  for n, raw in toSeq(text.splitLines):
    for prefix in ["ghp_", "gho_", "ghs_", "ghu_", "ghr_"]:
      var at = 0
      while (let i = raw.find(prefix, at); i >= 0):
        if runOf(raw, i + prefix.len, alnum) >= 30: result.add (path, n + 1, "a GitHub token")
        at = i + 1
    for prefix in ["github_pat_", "glpat-"]:
      var at = 0
      while (let i = raw.find(prefix, at); i >= 0):
        if runOf(raw, i + prefix.len, tail) >= 20: result.add (path, n + 1, "a " & (if prefix == "glpat-": "GitLab" else: "GitHub") & " token")
        at = i + 1
    for prefix in ["xoxb-", "xoxp-"]:
      let i = raw.find(prefix)
      if i >= 0 and runOf(raw, i + prefix.len, proc (c: char): bool = c in Digits + {'-'}) >= 10: result.add (path, n + 1, "a Slack token")
    var at = 0
    while (let i = raw.find("AKIA", at); i >= 0):
      let body = raw[i + 4 ..< min(raw.len, i + 20)]
      if body.len == 16 and body.allIt(cap(it)) and ("AKIA" & body) notin knownTestVectors and (i == 0 or not isIdent(raw[i - 1])):
        result.add (path, n + 1, "an AWS access key")
      at = i + 1
    if raw.contains("-----BEGIN ") and raw.contains("PRIVATE KEY-----") and not keyAllowedIn.anyIt(path.replace('\\', '/').contains(it)):
      result.add (path, n + 1, "a private key (keys of tests live in tests/certs and tests/vectors)")

proc privateWords*(path, text: string; words: seq[string]): seq[Finding] =
  ## a word of the owner's list (a plain substring, compared in lower case)
  for n, raw in toSeq(text.splitLines):
    let low = raw.toLowerAscii
    for w in words:
      if w.len > 0 and low.contains(w): result.add (path, n + 1, "a word of the private list")   # the word itself is not printed: this output ends in logs

# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

proc unguardedPorts*(path, text: string): seq[Finding] =
  ## A test that starts a server or a process on a port of its own and never asks whether the port is free (tests/support/freeport.nim): what holds the port is answered instead. A port of a test is a
  ## number of five digits next to the word port; starting is a bind, a serve, a start or a process.
  if not (path.startsWith("tests/unit/") or path.startsWith("tests/integration/")) or "requireFreePort" in text: return
  var hasPort, starts = false
  for raw in text.splitLines:
    let line = code(raw)
    if line.contains("Port(") or line.toLowerAscii.contains("port"):
      for i in 0 .. line.len - 5:
        if line[i .. i + 4].allIt(it in Digits) and (i == 0 or line[i - 1] notin Digits) and (i + 5 >= line.len or line[i + 5] notin Digits) and
           (line.toLowerAscii.contains("port") and not line.contains("\"")): hasPort = true
    if "bindAddr(" in line or ".serve(" in line or ".start(" in line or "startProcess(" in line or "startEmulator(" in line or "startFake" in line or "startProxy(" in line: starts = true
  if hasPort and starts: result.add (path, 1, "starts something on a port of its own and does not call requireFreePort (tests/support/freeport.nim)")

proc uncheckedDownload*(path, text: string): seq[Finding] =
  ## An archive that a Dockerfile or a script fetches with `curl` and unpacks without comparing its SHA-256 (`curl ... | tar x` checks nothing: the build takes whatever the address serves that day).
  ## The archive is saved to a file, `sha256sum -c` checks it, and then it is unpacked. Only a download of a release or of a tar file is looked at.
  if not (path.contains("Dockerfile") or path.endsWith(".sh")) or path.startsWith("tests/") : return
  let checked = "sha256sum -c" in text
  for i, raw in toSeq(text.splitLines):
    let line = code(raw)
    if "curl " in line and "http" in line and ("releases/download" in line or ".tar" in line):
      if "| tar" in line or "|tar" in line: result.add (path, i + 1, "an archive goes from curl into tar with no check of its SHA-256 (save it, `sha256sum -c`, then unpack)")
      elif not checked: result.add (path, i + 1, "an archive is fetched and the file has no `sha256sum -c`")

proc unpinnedSource*(path, text: string): seq[Finding] =
  ## What a build takes from outside is named by something that does not move: a base image by its digest (`FROM image:tag@sha256:...`; `scratch` and an `ARG`'s value are not looked at), an image of the pipeline
  ## the same, and a source tree by its commit (`git clone` follows a tag or a branch, which can be moved: fetch the commit, tools/k8s/build_client.sh `fetch_commit`). The exception is the tag of our own
  ## hsmgate (`HSMGATE_REF`, which Renovate moves).
  if path.startsWith("tests/") or path.startsWith("docs") or path.startsWith("deploy/examples/"): return       # the examples are the reader's to pin (Renovate leaves them too)
  for i, raw in toSeq(text.splitLines):
    let line = code(raw).strip
    if path.contains("Dockerfile") and line.startsWith("FROM "):
      let image = line.splitWhitespace[1]
      if image != "scratch" and not image.startsWith("$") and "@sha256:" notin image:
        result.add (path, i + 1, "the base image " & image & " has no digest (`image:tag@sha256:...`)")
    if path == ".ci/pipeline.lua" and line.startsWith("local ") and line.contains(" = \"") and line.count(':') >= 1 and not line.contains("\\n"):
      let q = line.split('"')
      if q.len >= 3 and q[1].contains('/') and q[1].contains(':') and not q[1].contains(" ") and "@sha256:" notin q[1]:
        result.add (path, i + 1, "the image " & q[1] & " has no digest")
    if (path.contains("Dockerfile") or path.endsWith(".sh")) and "git clone" in line and "HSMGATE_REF" notin line:
      result.add (path, i + 1, "`git clone` follows a tag or a branch: fetch the commit (fetch_commit in tools/k8s/build_client.sh)")

const
  docRoots = ["src/", "tools/", "deploy/", "tests/", "proto/", "lua/", "docs/", ".ci/"]
  docRefExempt = [".ci/NN.lua", ".ci/lock.json", "docs/how-to/talos.md"]     ## names the specification plans (the pipeline files of a project, D-68), and a file of another repository

proc missingDocPaths*(path, text: string; exists: proc (p: string): bool): seq[Finding] =
  ## A path in code quotes (`src/core/x.nim`) in a document that names no file of the repository: a file that was deleted or renamed and is still told of. What was deleted is in git, not in
  ## the text; a document that points at nothing misleads. Only the paths that start at a directory of the repository and end in an extension are looked at; a pattern (`*`, `<name>`, `$VAR`) is not a path.
  if not path.endsWith(".md"): return
  for n, line in toSeq(text.splitLines):
    let parts = line.split('`')
    for i in countup(1, parts.high, 2):                                       # the odd pieces are inside the quotes
      let p = parts[i].strip(chars = {'.', ',', ';', ':'})
      if not docRoots.anyIt(p.startsWith(it)) or p in docRefExempt: continue
      if p.anyIt(it in {' ', '*', '<', '>', '$', '{', '}', '(', ')', '|', '"', '\''}): continue
      let ext = p.splitFile.ext
      if ext.len < 2 or ext.len > 6: continue
      if not exists(p): result.add (path, n + 1, "names a file that is not in the repository: " & p)

suite "CLAUDE.md rules: each rule sees a violation":
  test "a test that starts a server on a port of its own and does not ask whether it is free is seen":
    check unguardedPorts("tests/unit/tx.nim", "const port = 18941\nlet s = newService(h)\ndiscard s.start(port, 2)\n").len == 1
    check unguardedPorts("tests/unit/tx.nim", "const port = 18941\nrequireFreePort(port, \"tx\")\ndiscard s.start(port, 2)\n").len == 0
    check unguardedPorts("tests/unit/tx.nim", "check cfg.collectorAddr == \"tcp://core:19743\"\n").len == 0          # a port in a string that nothing binds
    check unguardedPorts("tests/unit/tx.nim", "s.bindAddr(Port(0), \"127.0.0.1\")\n").len == 0                     # port 0: the system chooses a free one
    check unguardedPorts("src/core/x.nim", "const port = 18941\ndiscard s.start(port, 2)\n").len == 0
  test "a base image with no digest and a clone of a tag or a branch are refused":
    check unpinnedSource("tools/image/Dockerfile.x", "FROM nimlang/nim:2.4.0\n").len == 1
    check unpinnedSource("tools/image/Dockerfile.x", "FROM nimlang/nim:2.4.0@sha256:e35e49da9bb8a5d4562f9c4f8afc1945c9cdeb525b2a9b3e76431d0556ac0c8f AS b\nFROM scratch\nFROM ${DEPS_IMAGE} AS x\n").len == 0
    check unpinnedSource(".ci/pipeline.lua", "local GIT = \"alpine/git:v2.47.2\"\n").len == 1
    check unpinnedSource(".ci/pipeline.lua", "local GIT = \"alpine/git:v2.47.2@sha256:062a01ad7a0eb17cff382bc5e26086b4d710e56dfdfdf001109a49b6d9bd378c\"\nlocal X = \"set -eu\\nsh\"\n").len == 0
    check unpinnedSource("tools/k8s/x.sh", "git clone -q --depth 1 --branch v1 https://github.com/a/b b\n").len == 1
    check unpinnedSource("tools/image/Dockerfile.test", "RUN git clone -q --depth 1 --branch \"${HSMGATE_REF}\" https://github.com/zystem/hsmgate.git /src\n").len == 0
  test "an archive that is downloaded and unpacked without a check of its SHA-256 is refused":
    check uncheckedDownload("tools/image/Dockerfile.x", "RUN curl -fsSL \"https://h/releases/download/v1/a.tar.xz\" | tar xJ -C /tmp\n").len == 1
    check uncheckedDownload("tools/image/Dockerfile.x", "RUN curl -fsSL -o /tmp/a.tar.xz \"https://h/releases/download/v1/a.tar.xz\"\n").len == 1
    check uncheckedDownload("tools/image/Dockerfile.x", "RUN curl -fsSL -o /tmp/a.tar.xz \"https://h/releases/download/v1/a.tar.xz\" \\\n && echo \"$SUM  /tmp/a.tar.xz\" | sha256sum -c -\n").len == 0
    check uncheckedDownload("tools/x.sh", "curl -fsS https://h/api/v1/x\n").len == 0                          # not an archive
  test "a path in quotes that names no file is seen, a pattern, an exempt name and a path that is there are not":
    let there = proc (p: string): bool = p == "src/core/api.nim"
    check missingDocPaths("a.md", "see `src/core/gone.nim` for it\n", there).len == 1
    check missingDocPaths("a.md", "see `src/core/api.nim` for it\n", there).len == 0
    check missingDocPaths("a.md", "`src/core/*.nim`, `tools/<name>.sh`, `deploy/$X.yaml`, `src/core`\n", there).len == 0
    check missingDocPaths("a.md", "the pipeline file `.ci/NN.lua`\n", there).len == 0
    check missingDocPaths("a.nim", "`src/core/gone.nim`\n", there).len == 0             # documents only
  test "newHttpServer outside httpsrv.nim is seen, in httpsrv.nim and in a comment it is not":
    check newHttpServerCalls("src/core/x.nim", "let s = newHttpServer(handler)\n").len == 1
    check newHttpServerCalls("src/common/httpsrv.nim", "  newHttpServer(onrequest)\n").len == 0
    check newHttpServerCalls("src/core/x.nim", "# newHttpServer(handler) was here\n").len == 0
    check newHttpServerCalls("src/core/x.nim", "# newHttpServer's callback type\n").len == 0
  test "pkill with -f in any spelling is seen, pkill -x and a PID are not":
    check pkillF("a.sh", "pkill -f caddy\n").len == 1
    check pkillF("a.sh", "  sudo pkill -9 -f caddy\n").len == 1
    check pkillF("a.sh", "pkill -xf caddy\n").len == 1
    check pkillF("a.sh", "pkill --full caddy\n").len == 1
    check pkillF("a.sh", "pkill -x caddy\n").len == 0
    check pkillF("a.sh", "pkill -9 -x caddy\n").len == 0
  test "a proc, const or template called declared is seen, a local variable is not":
    check declaredName("a.nim", "proc declared(x: int): bool =\n").len == 1
    check declaredName("a.nim", "proc declared*(x: int): bool =\n").len == 1
    check declaredName("a.nim", "const declared = 3\n").len == 1
    check declaredName("a.nim", "template declared(x: untyped) =\n").len == 1
    check declaredName("a.nim", "  let declared = 3\n").len == 0
    check declaredName("a.nim", "proc declaredNames(x: int): bool =\n").len == 0
  test "the shapes of tokens are seen, the example key of AWS and a short word are not":
    check tokenShapes("a.md", "token: ghp_" & 'a'.repeat(36) & "\n").len == 1
    check tokenShapes("a.md", "github_pat_" & 'B'.repeat(40) & "\n").len == 1
    check tokenShapes("a.md", "glpat-" & 'c'.repeat(20) & "\n").len == 1
    check tokenShapes("a.md", "xoxb-1234567890-abc\n").len == 1
    check tokenShapes("a.md", "key AKIA" & "ABCDEFGHIJKLMNOP\n").len == 1
    check tokenShapes("a.md", "AKIAIOSFODNN7EXAMPLE\n").len == 0
    check tokenShapes("a.md", "the ghp_ prefix of GitHub tokens\n").len == 0
    check tokenShapes("a.md", "-----BEGIN RSA " & "PRIVATE KEY-----\n").len == 1
    check tokenShapes("tests/certs/x.pem", "-----BEGIN RSA " & "PRIVATE KEY-----\n").len == 0
  test "a word of the private list is seen whatever its case, and an empty line of the list sees nothing":
    check privateWords("a.md", "see Host.Example.Test for it\n", @["host.example.test"]).len == 1
    check privateWords("a.md", "nothing\n", @["host.example.test"]).len == 0
    check privateWords("a.md", "nothing\n", @[""]).len == 0

# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

const
  skipDirs = [".git", "build", "nimcache", "third_party", "docs-tr", "node_modules", ".claude"]
  textExts = [".nim", ".nims", ".nimble", ".cfg", ".lua", ".sh", ".py", ".md", ".yaml", ".yml", ".tpl", ".nimja", ".proto", ".toml", ".json", ".txt", ".css", ".js", ".html"]
  maxBytes = 2_000_000

proc root(): string = currentSourcePath().parentDir.parentDir.parentDir

iterator repositoryFiles(dir: string): string =
  ## the text files of the working tree that git would track (no build directories, no vendored code, no mirror of the docs), as paths relative to the root
  var stack = @[dir]
  while stack.len > 0:
    let d = stack.pop
    for kind, p in walkDir(d, relative = false):
      let name = p.extractFilename
      if kind == pcDir:
        if name notin skipDirs: stack.add p
      elif kind == pcFile and p.getFileSize <= maxBytes:
        let (_, base, ext) = p.splitFile
        if ext in textExts or base.startsWith("Dockerfile") or name in ["Makefile", ".gitignore"]:
          yield p.relativePath(root()).replace('\\', '/')

proc scan(rule: proc (path, text: string): seq[Finding]; files: seq[string]): seq[string] =
  for f in files:
    if f == "tests/unit/trepository.nim": continue          # this file names every shape it looks for
    for x in rule(f, readFile(root() / f)):
      result.add x.file & ":" & $x.line & ": " & x.what

suite "CLAUDE.md rules: the repository keeps them":
  let files = toSeq(repositoryFiles(root()))
  test "the walk found the tree (a walk that finds nothing proves nothing)":
    check files.len > 200
    check "src/common/httpsrv.nim" in files
    check "CLAUDE.md" in files
  test "every HTTP server is made with newService":
    check scan(newHttpServerCalls, files) == newSeq[string]()
  test "no script, document or source holds pkill -f":
    check scan(pkillF, files.filterIt(it != "CLAUDE.md")) == newSeq[string]()
  test "nothing is called declared":
    check scan(declaredName, files) == newSeq[string]()
  test "no file holds the shape of a token or a private key outside the places for test keys":
    check scan(tokenShapes, files) == newSeq[string]()
  test "every test that starts something on a port of its own asks whether the port is free (tests/support/freeport.nim)":
    check scan(unguardedPorts, files) == newSeq[string]()
  test "the documents name files that are in the repository (what was deleted is in git, not in the text)":
    let there = proc (p: string): bool = fileExists(root() / p) or dirExists(root() / p)
    check scan(proc (path, text: string): seq[Finding] = missingDocPaths(path, text, there), files) == newSeq[string]()
  test "renovate.json: every custom manager finds pins in the files it names, and every `# renovate:` comment is followed by the pin it describes":
    let cfg = parseJson(readFile(root() / "renovate.json"))
    var annotated, matched = 0
    for f in files:
      if f == "tests/unit/trepository.nim": continue
      annotated += readFile(root() / f).splitLines.countIt(it.strip.startsWith("# renovate:"))
    for m in cfg["customManagers"]:
      let patterns = toSeq(m["managerFilePatterns"]).mapIt(re(it.getStr[1 ..< it.getStr.len - 1]))      # "/regex/"
      var found = 0
      for f in files:
        if f == "tests/unit/trepository.nim" or not patterns.anyIt(f.contains(it)): continue
        for ms in m["matchStrings"]: found += readFile(root() / f).findAll(re(ms.getStr, {reMultiLine})).len
      check found > 0
      if m["matchStrings"][0].getStr.contains("renovate:"): matched = found
    check annotated > 0 and matched == annotated
  test "no archive is unpacked unchecked, and the sums of one archive are the same in every file that names it":
    check scan(uncheckedDownload, files) == newSeq[string]()
    check scan(unpinnedSource, files) == newSeq[string]()
    var sums: seq[string]
    for f in files:
      if not (f.contains("Dockerfile") or f == "tools/shim/build_static.sh") or f.startsWith("tests/"): continue
      for line in readFile(root() / f).splitLines:
        let l = line.strip(chars = {' ', '\t'}).replace("ARG ", "")
        if l.startsWith("NGHTTP2_SHA256="):
          sums.add l["NGHTTP2_SHA256=".len .. ^1]
    check sums.len == 4                                    # Dockerfile.deps, Dockerfile.test, tools/soak/Dockerfile, tools/shim/build_static.sh
    check sums.deduplicate.len == 1 and sums[0].len == 64 and sums[0].allIt(it in HexDigits and it notin {'A' .. 'F'})
  test "cinim.lock holds every package that cinim.nimble asks for, in a version that satisfies the ask (tools/deps/lock.sh makes it again)":
    let lock = parseJson(readFile(root() / "cinim.lock"))["packages"]
    proc atLeast(have, want: string): bool =
      let h = have.split('.').mapIt(parseInt(it))
      let w = want.split('.').mapIt(parseInt(it))
      for i in 0 ..< max(h.len, w.len):
        let a = if i < h.len: h[i] else: 0
        let b = if i < w.len: w[i] else: 0
        if a != b: return a > b
      true
    var asked = 0
    for line in readFile(root() / "cinim.nimble").splitLines:
      let t = line.strip
      if not t.startsWith("requires \""): continue
      let ask = t["requires \"".len ..< t.find('"', "requires \"".len)]
      inc asked
      if ask.startsWith("https://"):
        let commit = ask.split('#')[^1]
        check toSeq(lock.pairs).anyIt(it[1]["vcsRevision"].getStr == commit)        # a package pinned by its commit
      elif " >= " in ask:
        let name = ask.split(" >= ")[0].strip
        let want = ask.split(" >= ")[1].strip
        check lock.hasKey(name)
        if lock.hasKey(name): check atLeast(lock[name]["version"].getStr, want)
      else: check false              # a form of `requires` that this test does not read: teach it
    check asked > 5
  test "the files that a visitor of the repository looks for are there (the community profile of GitHub)":
    for f in ["README.md", "LICENSE", "SECURITY.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md", "GOVERNANCE.md", "DCO.md", "CHANGELOG.md", ".github/PULL_REQUEST_TEMPLATE.md", ".github/workflows/dco.yml"]:
      check fileExists(root() / f)
    check dirExists(root() / ".github/ISSUE_TEMPLATE")
  test "no tracked file holds a word of the owner's private list":
    let listed = getEnv("CINIM_PRIVATE_WORDS_FILE", getHomeDir() / ".config" / "cinim" / "private-words")
    if not fileExists(listed):
      echo "  (skipped: no list of private words at ", listed, ", set CINIM_PRIVATE_WORDS_FILE or make that file; the list is the owner's and is not in the repository)"
      skip()
    else:
      let words = readFile(listed).splitLines.mapIt(it.strip.toLowerAscii).filterIt(it.len > 0 and not it.startsWith("#"))
      check scan(proc (path, text: string): seq[Finding] = privateWords(path, text, words), files) == newSeq[string]()
