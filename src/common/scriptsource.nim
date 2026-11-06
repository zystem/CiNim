## D-63: the script of a run read from a repository (by the conductor, `conductor/main.nim`: it has the organisation's egress rules, limits and a place for the process). A run (or a trigger) names a repository, a commit (or a branch, or a tag) and a path (`.ci/pipeline.lua` by default, PRJ-003);
## the file is read at that commit and its text is kept with the run (PIP-001: the run has an immutable bundle, the script and the SHA of the commit), then the run goes on as for a
## script that came in the request. The reading is `git fetch --depth 1` of the one commit into a directory of its own, then the one blob: `git` is run (the image has it)
## as a process with a deadline, with no terminal, no configuration of the system, no helpers and only the transports it is told (https and http by default,
## `GIT_ALLOW_PROTOCOL`); a repository that needs a login is not read (no credentials are given). Nothing but the one file leaves the directory, and the directory is removed.
import std/[os, osproc, streams, strutils, strtabs, times, random, hashes]

const
  defaultPath* = ".ci/pipeline.lua"
  maxScriptBytes* = 1024 * 1024         ## a pipeline script is source text, not data
  defaultTransports* = "https:http"

type
  Source* = object
    repository*, commit*, path*: string        ## what was asked: the repository URL, a commit / branch / tag, the path of the script in it
    refName*: string                           ## D-86: for a run, the name (a branch or a tag) the commit was asked by; "" when it was asked by its hash or by nothing

  Fetched* = object
    ok*: bool
    script*: string
    commit*: string                            ## the full SHA-1 (or SHA-256) of the commit that the name resolved to
    code*, message*: string                    ## when not ok: invalid_source, fetch_failed, script_missing, script_too_large, git_unavailable

const defaultSchemes* = ["https://", "http://"]

func validRepository*(url: string; schemes: openArray[string] = defaultSchemes): bool =
  ## one of `schemes` (https and http), a host, no spaces or control characters, not too long; `-` cannot start it (git would take it for an option)
  if url.len == 0 or url.len > 300: return false
  for c in url:
    if c <= ' ' or c == '\x7f' or c in {'\\', '\'', '"', '`'}: return false
  for sc in schemes:
    if url.startsWith(sc) and url.len > sc.len: return true

func validRef*(r: string): bool =
  ## a commit, a branch or a tag: letters, digits and `. _ / - @`, not starting with `-` or `/`, no `..`
  if r.len == 0 or r.len > 200 or r[0] in {'-', '/'} or ".." in r: return false
  for c in r:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '/', '-', '@'}: return false
  true

func validPath*(p: string): bool =
  ## a relative path inside the repository: no `..`, not absolute, not starting with `-`, no control characters
  if p.len == 0 or p.len > 300 or p[0] in {'/', '-'}: return false
  for part in p.split('/'):
    if part == ".." or part.len == 0: return false
  for c in p:
    if c < ' ' or c == '\x7f' or c in {'\\', ':', '"', '\'', '`'}: return false
  true

proc timedOut(p: Process; ms: int): bool =
  ## waits for the process; past the deadline it is killed
  result = p.waitForExit(ms) == -1 and p.running
  if result:
    p.kill()
    discard p.waitForExit(2000)

proc git(dir: string; args: seq[string]; transports: string; timeoutMs: int): tuple[code: int, output: string, timedOut: bool] =
  ## one `git` in `dir` with an environment of its own: the home is the directory, no terminal asks for a password, the system configuration is not read, and only `transports` may be used
  var env = newStringTable()
  env["LC_ALL"] = "C"                                 # the messages are matched below
  for k in ["PATH", "SSL_CERT_FILE", "SSL_CERT_DIR"]:
    if existsEnv(k): env[k] = getEnv(k)
  env["HOME"] = dir
  env["GIT_TERMINAL_PROMPT"] = "0"
  env["GIT_CONFIG_NOSYSTEM"] = "1"
  env["GIT_CONFIG_GLOBAL"] = "/dev/null"
  env["GIT_ASKPASS"] = "true"
  env["GIT_ALLOW_PROTOCOL"] = transports
  var p: Process
  try:
    p = startProcess("git", workingDir = dir, args = @["-c", "core.hooksPath=/dev/null", "-c", "protocol.version=2", "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=" & $max(timeoutMs div 1000, 5)] & args, env = env, options = {poStdErrToStdOut, poUsePath})
  except OSError as e:
    return (127, e.msg, false)
  defer: p.close()
  result.timedOut = p.timedOut(timeoutMs)
  if result.timedOut: return (-1, "", true)          # the helper that git started (git-remote-https) may hold the pipe for a while: the output is not waited for
  # the output of a fetch with `-q` is a few lines and fits the pipe, so reading after the wait cannot block the process; a `git cat-file` is bounded by the size asked first
  result.output = p.outputStream.readAll()
  result.code = p.peekExitCode

proc fetchCommit(dir, repository, ref0, transports: string; timeoutSeconds: int; started: float): tuple[sha, code, message: string] =
  ## `git fetch --depth 1` of the one commit `ref0` (a SHA, a branch or a tag) into `dir`, which `git init` has made: no history, and no blobs when the server can filter them (the trees are all
  ## that a look at the files needs). A server that cannot filter is asked again without the filter. `sha` is the full SHA of the commit; on failure `code` and `message`.
  proc left(): int = max(int((timeoutSeconds.float - (epochTime() - started)) * 1000), 1000)
  var fetched = false
  var last = ""
  for filter in [@["--filter=blob:none"], @[]]:
    let r = git(dir, @["fetch", "-q", "--depth", "1", "--no-tags", "--no-recurse-submodules"] & filter & @["--", repository, ref0], transports, left())
    if r.timedOut: return ("", "fetch_failed", "the repository did not answer within " & $timeoutSeconds & " s")
    if r.code == 0:
      fetched = true
      break
    last = r.output.strip
    if "too slow" in last: return ("", "fetch_failed", "the repository did not answer in time (" & last.splitLines()[^1] & ")")
    if "filter" notin last.toLowerAscii: break          # a server that cannot filter is asked again without the filter; any other refusal is final
  if not fetched: return ("", "fetch_failed", "could not read " & ref0 & " from the repository: " & last.splitLines()[^1])
  let r = git(dir, @["rev-parse", "--verify", "-q", "FETCH_HEAD^{commit}"], transports, 10_000)
  if r.code != 0 or r.output.strip.len < 40: return ("", "fetch_failed", ref0 & " is not a commit")
  (r.output.strip, "", "")

proc fetchScript*(s: Source; timeoutSeconds = 40; transports = defaultTransports; schemes: openArray[string] = defaultSchemes): Fetched =
  ## Reads `s.path` at `s.commit` from `s.repository`. Never raises: a refusal or a failure is `code` and `message`.
  let path = if s.path.len == 0: defaultPath else: s.path
  let ref0 = if s.commit.len == 0: "HEAD" else: s.commit
  if not validRepository(s.repository, schemes): return Fetched(code: "invalid_source", message: "the repository must be an https:// or http:// URL")
  if not validRef(ref0) and ref0 != "HEAD": return Fetched(code: "invalid_source", message: "the commit is a SHA, a branch or a tag name")
  if not validPath(path): return Fetched(code: "invalid_source", message: "the path of the script is a relative path inside the repository")
  let started = epochTime()
  randomize()
  let dir = getTempDir() / ("cinim-script-" & $getCurrentProcessId() & "-" & $rand(high(int32)) & "-" & $(hash(s.repository & ref0) and 0xffff))
  try:
    createDir(dir)
    defer:
      try: removeDir(dir) except OSError: discard
    proc left(): int = max(int((timeoutSeconds.float - (epochTime() - started)) * 1000), 1000)
    var r = git(dir, @["init", "-q"], transports, 10_000)
    if r.code != 0: return Fetched(code: "git_unavailable", message: "git did not start: " & r.output.strip)
    # the commit alone: no history
    let one = fetchCommit(dir, s.repository, ref0, transports, timeoutSeconds, started)
    if one.code.len > 0: return Fetched(code: one.code, message: one.message)
    let sha = one.sha
    r = git(dir, @["cat-file", "-s", sha & ":" & path], transports, left())
    if r.code != 0: return Fetched(code: "script_missing", message: "no file " & path & " in the commit " & sha[0 ..< 12], commit: sha)
    let size = try: parseInt(r.output.strip) except ValueError: -1
    if size < 0: return Fetched(code: "script_missing", message: path & " is not a file", commit: sha)
    if size > maxScriptBytes: return Fetched(code: "script_too_large", message: path & " is " & $size & " bytes; at most " & $maxScriptBytes, commit: sha)
    r = git(dir, @["cat-file", "blob", sha & ":" & path], transports, left())
    if r.code != 0: return Fetched(code: "script_missing", message: "could not read " & path & ": " & r.output.strip, commit: sha)
    Fetched(ok: true, script: r.output, commit: sha)
  except CatchableError as e:
    Fetched(code: "fetch_failed", message: e.msg)

type
  Changed* = object
    ok*: bool
    paths*: seq[string]                        ## the paths whose content differs between the two commits (added, changed, deleted), in order, at most `maxPaths`
    truncated*: bool                           ## there were more
    base*, commit*: string                     ## the full SHAs of the two commits
    code*, message*: string                    ## when not ok: invalid_source, fetch_failed, git_unavailable

proc changedPaths*(repository, base, commit: string; timeoutSeconds = 40; transports = defaultTransports; schemes: openArray[string] = defaultSchemes; maxPaths = 5000): Changed =
  ## PRJ-004, D-82: the paths that differ between `base` (the commit of the last run of the pipeline that ended OK) and `commit`, for a script that decides what to do by what changed. Each commit is
  ## fetched alone, trees only (no history, no blobs), and the two trees are compared by `git diff-tree`, which needs no file: a few seconds even for a big repository. The commits need no
  ## history in common. Never raises: a refusal or a failure is `code` and `message`.
  for name in [base, commit]:
    if not validRef(name): return Changed(code: "invalid_source", message: "a commit is a SHA, a branch or a tag name")
  if not validRepository(repository, schemes): return Changed(code: "invalid_source", message: "the repository must be an https:// or http:// URL")
  let started = epochTime()
  randomize()
  let dir = getTempDir() / ("cinim-changed-" & $getCurrentProcessId() & "-" & $rand(high(int32)) & "-" & $(hash(repository & base & commit) and 0xffff))
  try:
    createDir(dir)
    defer:
      try: removeDir(dir) except OSError: discard
    var r = git(dir, @["init", "-q"], transports, 10_000)
    if r.code != 0: return Changed(code: "git_unavailable", message: "git did not start: " & r.output.strip)
    let b = fetchCommit(dir, repository, base, transports, timeoutSeconds, started)
    if b.code.len > 0: return Changed(code: b.code, message: "the base: " & b.message)
    let c = fetchCommit(dir, repository, commit, transports, timeoutSeconds, started)
    if c.code.len > 0: return Changed(code: c.code, message: "the commit: " & c.message)
    # to a file: the list of a big change does not fit the pipe that `git` has to a process that waits for it to end
    let left = max(int((timeoutSeconds.float - (epochTime() - started)) * 1000), 1000)
    r = git(dir, @["diff-tree", "-r", "--name-only", "--no-renames", "-z", "--output=" & (dir / "changed.list"), b.sha, c.sha], transports, left)
    if r.timedOut: return Changed(code: "fetch_failed", message: "git did not finish comparing the two commits within " & $timeoutSeconds & " s")
    if r.code != 0: return Changed(code: "fetch_failed", message: "could not compare the two commits: " & r.output.strip)
    result = Changed(ok: true, base: b.sha, commit: c.sha)
    for name in readFile(dir / "changed.list").split('\0'):
      if name.len == 0: continue
      if result.paths.len >= maxPaths:
        result.truncated = true
        break
      result.paths.add name
  except CatchableError as e:
    result = Changed(code: "fetch_failed", message: e.msg)

proc resolveRef*(repository, ref0: string; timeoutSeconds = 30; transports = defaultTransports; schemes: openArray[string] = defaultSchemes): Fetched =
  ## D-76: the commit that `ref0` (a branch, a tag, HEAD; empty is HEAD) is at in `repository`, by `git ls-remote`: nothing is fetched. A SHA names itself. Never raises: a refusal or a failure is `code` and `message`.
  let wanted = if ref0.len == 0: "HEAD" else: ref0
  if not validRepository(repository, schemes): return Fetched(code: "invalid_source", message: "the repository must be an https:// or http:// URL")
  if not validRef(wanted) and wanted != "HEAD": return Fetched(code: "invalid_source", message: "the ref is a SHA, a branch or a tag name")
  if wanted.len == 40 and wanted.allCharsInSet({'0' .. '9', 'a' .. 'f'}): return Fetched(ok: true, commit: wanted)
  randomize()
  let dir = getTempDir() / ("cinim-script-" & $getCurrentProcessId() & "-" & $rand(high(int32)) & "-" & $(hash(repository & wanted) and 0xffff))
  try:
    createDir(dir)
    defer:
      try: removeDir dir except OSError: discard
    let r = git(dir, @["ls-remote", "--", repository, wanted], transports, timeoutSeconds * 1000)
    if r.timedOut: return Fetched(code: "fetch_failed", message: "the repository did not answer within " & $timeoutSeconds & " s")
    if r.code != 0: return Fetched(code: "fetch_failed", message: "could not read the refs of the repository: " & r.output.strip.splitLines()[^1])
    # "<sha>\t<name>" lines: the name asked for beats a name that only ends the same way, a branch beats a tag, and a peeled tag (`^{}`) is the commit of an annotated one
    var best = ""
    var bestRank = high(int)
    for line in r.output.splitLines():
      let cols = line.split('\t')
      if cols.len != 2 or cols[0].len != 40: continue
      let name = cols[1]
      let rank =
        if wanted == "HEAD": (if name == "HEAD": 0 else: high(int))
        elif name == "refs/heads/" & wanted: 0
        elif name == "refs/tags/" & wanted & "^{}": 1
        elif name == "refs/tags/" & wanted: 2
        elif name == wanted: 3
        else: high(int)
      if rank < bestRank:
        bestRank = rank
        best = cols[0]
    if best.len == 0: return Fetched(code: "fetch_failed", message: wanted & " is not in the repository")
    Fetched(ok: true, commit: best)
  except CatchableError as e:
    Fetched(code: "fetch_failed", message: e.msg)

const sourceKeys* = ["@source.repository", "@source.commit", "@source.path", "@source.base"]    ## launch-parameter entries that no declared name can be: how `run.source` reaches the script (executor/bootstrap.lua)

func sourceParams*(repository, commit, path: string; base = ""): seq[(string, string)] =
  ## `base` (D-82) is the commit of the last run of the same pipeline that ended OK, "" when there is none (and in a check before the run exists, which knows no history)
  @[(sourceKeys[0], repository), (sourceKeys[1], commit), (sourceKeys[2], path), (sourceKeys[3], base)]
