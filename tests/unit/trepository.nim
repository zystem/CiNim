## The rules of CLAUDE.md that are kept by memory, kept by a test instead: what the owner and the assistant once paid time for, and what is easy to write again.
##   * every HTTP server is made with `newService` of src/common/httpsrv.nim, not with `newHttpServer` (GuildenStern 9.0.1 closed connections; "Things that cost time");
##   * `pkill -f` is never written (it kills what its pattern happens to match: the hook refuses it in a session, and a script would not be stopped by the hook);
##   * no proc, func, const, template, iterator or macro is named `declared` (a magic of Nim);
##   * the repository holds no tokens: the shapes of the common ones (GitHub, GitLab, Slack, AWS) and private keys are looked for (a test vector is listed below with the reason);
##   * the repository holds no private addresses, host names or cluster names: those are the owner's, so they are not in this file either. A list of regular words, one per line, is read from
##     `$CINIM_PRIVATE_WORDS_FILE` or `~/.config/cinim/private-words` and the test fails when a tracked file holds one; without the file this part is skipped (it says so).
## The rules are procs that take a path and a text and answer the lines they refuse, so that the first suite proves that each one sees a violation (a rule that sees nothing is worse than none);
## the second reads the repository.
import std/[unittest, os, strutils, sequtils]

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

suite "CLAUDE.md rules: each rule sees a violation":
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
  test "no tracked file holds a word of the owner's private list":
    let listed = getEnv("CINIM_PRIVATE_WORDS_FILE", getHomeDir() / ".config" / "cinim" / "private-words")
    if not fileExists(listed):
      echo "  (skipped: no list of private words at ", listed, ", set CINIM_PRIVATE_WORDS_FILE or make that file; the list is the owner's and is not in the repository)"
      skip()
    else:
      let words = readFile(listed).splitLines.mapIt(it.strip.toLowerAscii).filterIt(it.len > 0 and not it.startsWith("#"))
      check scan(proc (path, text: string): seq[Finding] = privateWords(path, text, words), files) == newSeq[string]()
