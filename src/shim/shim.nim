## Runner shim (RUN-010): wraps the step command inside the step Pod. It is the first process of the container and outlives the
## command; its priority is higher than the build's.
##   cicd-shim --run-dir DIR [--workspace DIR] [--state-dir DIR] [--termination-log FILE] [--secrets-file FILE] [--collector-addr ADDR --core-addr ADDR --certs-dir DIR
##             --run-id ID --step-seq N --step-attempt N --log-spool-dir DIR ...] [--opts-json JSON] -- command args...
## What it does (D-27 – D-30, docs/):
##   - gives the command $CICD_ENV, $CICD_OUTPUT, $CICD_MASK and $CICD_WORKSPACE, validates the files after it (STO-003, SEC-011); with --workspace and
##     --state-dir (the run volume of STO-001) the workspace and the env file are the ones every step of the run shares, --run-dir is the step's own;
##   - starts the command in its own process group, below its own CPU priority, and enforces the step's timeout and SIGTERM;
##   - turns the output into masked, numbered, compressed blocks in a spool on the run's volume (so that it outlives the Pod, D-53) and delivers them to
##     core (logclient.nim); the Pod's own log carries only the shim's events (shimlog.nim);
##   - samples the container's resources, reads a JVM's counters and scrapes the application's endpoints (metrics);
##   - reports its state to core with every heartbeat and its result in StepReport, then waits for core's permission to exit; the
##     termination message (at most 4 KiB) and the Pod status stay the fallback;
##   - `--drain ...` delivers what a step that has ended left on the volume (its log spool, the manifest of its artifacts), in a Pod the job-controller makes when core orders it;
##   - on SIGTERM (a cancelled step, a Pod being removed) stops the build (SIGTERM to its process group, SIGKILL after 20 s), delivers the log and exits.
## Exit code: the command's, 124 for a timeout, 70 for env_rejected, 72 for logs_undelivered, 71 for an internal error.
## The default build has no ZeroMQ (it runs in any image); the production build is -d:shimLogging, linked statically
## (tools/shim/build_static.sh).

import std/[os, osproc, json, strutils, strtabs, posix, times, atomics, options, base64, sequtils]
import checksums/sha2
import dotenv, shimlog, secretmask, appmetrics, resmetrics, appscrape, artifacts, varsheader, cachepack
import ../common/[stepenv, cachedecl]
when defined(shimLogging):
  import logclient   ## also brings in StepRef (import_proto3-generated) for the calls below
else:
  # Default build: no ZeroMQ at all. logclient.nim pulls in zmqcurve -> zmq/bindings.nim, which dlopens
  # libzmq at program start (a version check at import) - an arbitrary step image (busybox, ...) has no
  # libzmq, so a shim linked against it dies before running the command, silently breaking A.6's
  # "static, dependency-free shim" property for every step, logging or not. These stubs keep main()'s
  # logging calls compiling to no-ops; the real LogIngest/StepReport client is built with -d:shimLogging
  # (tools/shim/build_static.sh links libzmq statically, so it runs in any image).
  type
    LogPipeline = object
    StepRef = object
      run_id: string
      seq, attempt: uint32
  proc canAccept(lp: var LogPipeline): bool = true
  proc write(lp: var LogPipeline; data: string) = discard
  proc tick(lp: var LogPipeline) = discard
  proc addSecrets(lp: var LogPipeline; values: openArray[string]) = discard
  proc finish(lp: var LogPipeline; limitSeconds = 0): bool = true
  proc sendStepReport(coreAddr, certs: string; step: StepRef; exitCode: int; reason: string): bool = true
  type FetchedSecrets = object
    ok, retry: bool
    values: seq[(string, string)]
    code, detail: string
  proc fetchStepSecrets(coreAddr, certs: string; step: StepRef; token: string): FetchedSecrets =
    FetchedSecrets(code: "no_core_client", detail: "this build has no client of core (-d:shimLogging)")

const
  exitTimeout = 124            ## the step ran past its timeout_seconds (the same code `timeout(1)` uses)
  exitEnvRejected = 70
  exitSecretsUnavailable = 73  ## the step's secrets could not be fetched from core: the command was not started
  exitArtifactsFailed = 74     ## the command succeeded, but its artifacts could not be put into the store (DAT-003)
  exitArtifactsUndelivered = 76  ## the command succeeded, its artifacts are still on the Pod: the core could not take them (the controller drains them when the core orders it)
  exitArtifactsUnavailable = 75  ## the artifacts the step asked for could not be fetched: the command was not started
  exitLogsUndelivered = 72     ## D-27: the command ran, but its log did not reach vlagent within log_hold_timeout
  maxTerminationBytes = 4096

proc sha256hex(data: string): string =
  for c in secureHash(Sha_256, data): result.add toHex(ord(c), 2).toLowerAscii

proc writeTermination(path: string; msg: JsonNode) =
  var text = $msg
  if text.len > maxTerminationBytes:      # never exceed the Kubernetes limit; drop the detail first
    msg["detail"] = %"(truncated)"
    text = $msg
  try:
    writeFile(path, text)
  except IOError:
    discard

var termSignal: Atomic[int]     ## set by the SIGTERM/SIGINT handler: the signal number that asked the shim to stop

proc onTerminate(sig: cint) {.noconv.} =
  termSignal.store(int(sig))

proc signalBuild(pid: int; sig: cint) =
  ## The build runs in its own process group (see lowerBuildPriority), so the whole tree gets the signal - not only `sh`.
  if kill(Pid(-pid), sig) != 0: discard kill(Pid(pid), sig)

proc setpriorityC(which: cint; who: cuint; prio: cint): cint {.importc: "setpriority", header: "<sys/resource.h>".}
var environ {.importc: "environ".}: cstringArray
proc exitImmediately(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

type Build = object
  pid: int
  fd: cint                 ## read end of the pipe carrying the build's stdout and stderr (merged)

proc spawnBuild(cmd: seq[string]; env: StringTableRef; nice, oomAdj: int; cwd = ""): Build =
  ## Starts the build in its own process group, with its CPU priority lowered and its OOM score raised, *before* it
  ## execs - so there is no window in which it runs at the shim's priority, and every process it starts inherits all
  ## three. (osproc.startProcess cannot do this: setpgid after exec is refused.) Why the build is made less important
  ## rather than the shim more: the shim must outlive trouble in the build - under CPU contention it still has to read
  ## the pipe, report to core and deliver the log, and when the container runs out of memory the OOM killer should take
  ## the build, not the shim; an unprivileged process can only lower itself and its children. Why the group: a timeout or
  ## SIGTERM has to reach everything the build started, not only `sh`.
  ## Called while the shim is still single-threaded (the log sender starts later), which is what makes fork safe here.
  ## `cwd`: the directory the command starts in (the run's workspace, STO-002); "" leaves the working directory of the image.
  var fds, errFds: array[2, cint]
  if pipe(fds) != 0 or pipe(errFds) != 0: raise newException(OSError, "pipe failed")
  discard fcntl(errFds[1], F_SETFD, FD_CLOEXEC)       # closes by itself when the exec succeeds: the parent sees EOF
  var argv = allocCStringArray(cmd)
  var envp: seq[string]
  for k, v in env: envp.add k & "=" & v
  let envArr = allocCStringArray(envp)
  let oomPath = "/proc/self/oom_score_adj"
  let oomVal = $oomAdj
  let cwdC = cwd.cstring
  let pid = fork()
  if pid < 0: raise newException(OSError, "fork failed")
  if pid == 0:
    # the child: only async-signal-safe calls from here to exec
    discard setpgid(Pid(0), Pid(0))
    if cwd.len > 0: discard chdir(cwdC)       # async-signal-safe; a failure leaves the image's own directory
    if nice > 0: discard setpriorityC(0, 0, cint(nice))
    if oomAdj > 0:
      let f = open(oomPath.cstring, O_WRONLY)
      if f >= 0:
        discard posix.write(f, oomVal.cstring, oomVal.len)
        discard close(f)
    discard dup2(fds[1], 1)
    discard dup2(fds[1], 2)
    discard close(fds[0])
    discard close(fds[1])
    environ = envArr
    discard execvp(argv[0], argv)
    var e = errno                                    # exec failed: tell the parent why (it reports shim_error)
    discard posix.write(errFds[1], addr e, sizeof(e))
    exitImmediately(127)
  discard close(fds[1])
  discard close(errFds[1])
  var childErrno: cint
  let got = posix.read(errFds[0], addr childErrno, sizeof(childErrno))
  discard close(errFds[0])
  if got == sizeof(childErrno):
    discard close(fds[0])
    var st: cint
    discard waitpid(pid, st, 0)
    raise newException(OSError, "cannot execute " & cmd[0] & ": " & $strerror(childErrno))
  Build(pid: int(pid), fd: fds[0])

proc prepareVolume(args: seq[string]): int =
  ## `cicd-shim --prepare-volume DIR SUB...` is the init container of a step Pod that mounts the run volume (STO-001, STO-002): it makes the subdirectories of the
  ## volume that the step then mounts (`workspace`, `state`) and opens them to everyone, because the kubelet would make a missing `subPath` as root, and a step
  ## that is not root could not write there; the steps of one run are not all the same user (a build Pod is root of its user namespace).
  if args.len < 3:
    stderr.writeLine "usage: cicd-shim --prepare-volume DIR SUBDIRECTORY..."
    return 2
  for sub in args[2 .. ^1]:
    if sub.len == 0 or sub[0] == '/' or ".." in sub.split('/'):
      stderr.writeLine "cicd-shim: --prepare-volume: " & sub & " is not a relative path inside the volume"
      return 2
    let dir = args[1] / sub
    let open = {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupWrite, fpGroupExec, fpOthersRead, fpOthersWrite, fpOthersExec}
    try:
      createDir(dir)
      # a directory that an earlier step made (a build Pod is root of a user namespace, an ordinary step another user) is already open and is not
      # this user's to change: only a directory that is not open yet needs the change
      if getFilePermissions(dir) * open != open: setFilePermissions(dir, open)
    except CatchableError as e:
      stderr.writeLine "cicd-shim: --prepare-volume: " & dir & ": " & e.msg
      return 1
  0

when defined(shimLogging):
  proc safeRel(p: string): bool =
    ## a path core named: relative and inside the workspace, whatever core says
    p.len > 0 and p[0] != '/' and ".." notin p.split('/') and '\0' notin p

  proc downloadArtifacts(artifactAddr, certs: string; step: StepRef; token: string; names: seq[string]; workspace: string; patience: int): string =
    ## the artifacts the step asked for, from this run, into the workspace, block by block; "" or what went wrong
    let c = newArtifactClient(artifactAddr, certs)
    defer: c.close()
    let list = ask(c, step, token, ArtifactRequest(op: "get_list", names: names, direct: true), patience)
    if not list.ok: return list.code & ": " & list.detail
    for f in list.ack.files:
      if not safeRel(f.path): return "core named the path " & f.path & ", which is not inside the workspace"
      let dest = workspace / f.path
      createDir(parentDir(dest))
      let err = c.fetchTo(step, token, f.path, f.size, dest & ".part", patience, directUrl = list.ack.direct_url, grant = f.grant, directPath = f.direct_path)
      if err.len > 0:
        removeFile(dest & ".part")
        return err
      moveFile(dest & ".part", dest)
      if fileSha256(dest) != f.sha256:
        removeFile(dest)
        return f.path & ": the SHA-256 is not the one recorded when it was put"
    ""

  type UploadResult = object
    failure: string            ## "" = all delivered
    undelivered: bool          ## the core did not answer for the whole patience: the manifest stays, the Pod is kept for the controller to drain on the core's order

  proc uploadArtifacts(artifactAddr, certs: string; step: StepRef; token: string; patterns: seq[string]; workspace, manifestPath: string;
                       patience: int; say: proc (line: string) {.closure.}): UploadResult =
    ## the files under the workspace that match, sent to the core in blocks and stored by it; what is still to be delivered is on record in the manifest
    let found = collectFiles(workspace, patterns)
    if found.error.len > 0: return UploadResult(failure: found.error)
    var files: seq[ManifestFile]
    for f in found.files: files.add ManifestFile(path: f, size: getFileSize(workspace / f), sha256: fileSha256(workspace / f))
    createDir(parentDir(manifestPath))
    writeManifest(manifestPath, files)          # before the first block: whatever happens next, what the command left is on record
    let c = newArtifactClient(artifactAddr, certs)
    defer: c.close()
    let d = deliverFiles(manifestPath, files,
      proc (f: ManifestFile): tuple[ok, retry: bool; detail: string] =
        let r = putFile(c, step, token, f.path, workspace / f.path, f.size, f.sha256, patience)
        (r.ok, r.retry, r.code & ": " & r.detail),
      proc (f: ManifestFile) = say "artifact " & f.path & " put (" & $f.size & " bytes" & (if lastPutDirect: ", straight to the storage module" else: "") & ")")
    if d.ok: UploadResult() else: UploadResult(failure: d.path & ": " & d.detail, undelivered: d.retry)

  const cachePatience = 30          ## seconds: a cache is a convenience, a core that does not answer is not waited for long

  proc restoreCaches(artifactAddr, certs: string; step: StepRef; token: string; specs: seq[CacheDecl]; workspace, tmpDir: string): tuple[notes: seq[string], hit: seq[string], restored: seq[string]] =
    ## DAT-004: before the command, for each cache the step declared: the entry of its key, or of the latest key a restore key names, is fetched and unpacked into the workspace.
    ## Nothing here fails the step: a miss, an archive that is damaged or a core that does not answer is a line in the step's log.
    if artifactAddr.len == 0 or token.len == 0:
      result.notes.add "cache: not restored (the Pod was given no address of the core's artifact service, or no credential)"
      return
    let c = newArtifactClient(artifactAddr, certs)
    defer: c.close()
    result.restored = newSeq[string](specs.len)       # the key restored for each cache, "" where there was none: the answer of a `j.cache.restore` step
    for i, d in specs:
      if d.mode == "save": continue                    # the step of a `j.cache.save` restores nothing
      let f = cacheFind(c, step, token, d.key, cachePatience)
      if not f.ok:
        result.notes.add "cache " & d.key & ": not restored (" & f.detail & ")"
        continue
      if not f.found:
        result.notes.add "cache " & d.key & ": miss"
        continue
      let tmp = tmpDir / ("cache-" & $step.seq & "-" & $step.attempt & "-" & $i & ".bin")
      let err = cacheFetch(c, step, token, f.key, f.size, tmp, cachePatience, f.directUrl, f.grant, f.directPath)
      if err.len > 0:
        result.notes.add "cache " & d.key & ": not restored (" & err & ")"
        removeFile(tmp)
        continue
      if fileSha256(tmp) != f.sha256:
        result.notes.add "cache " & d.key & ": not restored (the SHA-256 is not the one recorded when it was saved)"
        removeFile(tmp)
        continue
      createDir(workspace)
      let u = unpackCache(tmp, workspace)
      removeFile(tmp)
      if u.error.len > 0:
        result.notes.add "cache " & d.key & ": restored only in part (" & u.error & ")"
      else:
        result.notes.add "cache " & d.key & ": restored from " & f.key & " (" & $u.files & " files, " & $f.size & " bytes" & (if u.skipped > 0: ", " & $u.skipped & " entries left out" else: "") & ")"
      if u.error.len == 0: result.restored[i] = f.key
      if f.key == d.key and u.error.len == 0: result.hit.add d.key

  proc saveCaches(artifactAddr, certs: string; step: StepRef; token: string; specs: seq[CacheDecl]; hit: seq[string]; workspace, tmpDir: string): seq[string] =
    ## DAT-004: after a command that succeeded, each cache whose exact key was not restored is packed from the workspace and saved under its key. A key is immutable: one
    ## that is stored already (another run saved it meanwhile) is not an error.
    if artifactAddr.len == 0 or token.len == 0: return @["cache: not saved (the Pod was given no address of the core's artifact service, or no credential)"]
    let c = newArtifactClient(artifactAddr, certs)
    defer: c.close()
    for i, d in specs:
      if d.mode == "restore": continue                 # the step of a `j.cache.restore` saves nothing
      if d.key in hit:
        result.add "cache " & d.key & ": not saved (the key was restored, and a key is immutable)"
        continue
      let tmp = tmpDir / ("cache-save-" & $step.seq & "-" & $step.attempt & "-" & $i & ".bin")
      let st = packCache(workspace, d.paths, tmp)
      if st.error.len > 0:
        result.add "cache " & d.key & ": not saved (" & st.error & ")"
        removeFile(tmp)
        continue
      if st.files + st.dirs + st.links == 0:
        result.add "cache " & d.key & ": not saved (none of " & d.paths.join(", ") & " is in the workspace)"
        removeFile(tmp)
        continue
      let size = getFileSize(tmp)
      let r = putFile(c, step, token, d.key, tmp, size, fileSha256(tmp), cachePatience, cache = true)
      removeFile(tmp)
      if r.ok: result.add "cache " & d.key & ": saved (" & $st.files & " files, " & $size & " bytes)"
      elif r.code == "cache_exists": result.add "cache " & d.key & ": not saved (the key is stored already)"
      else: result.add "cache " & d.key & ": not saved (" & r.code & ": " & r.detail & ")"

  proc drainTool(args: seq[string]): int =
    ## `cicd-shim --drain ...`: the drain of a step that ended without having handed over its artifacts or its log (docs/artifacts.md). Run by a Pod the job controller makes
    ## on the run's volume when the core orders it: it reads the manifest of the artifacts and the log spool that the step's shim left there, and sends them to the core as that
    ## shim would have, with the step's credential, taking each file off the manifest and each block off the spool as the core has it. Exit 0: everything asked is delivered;
    ## 77: the core or the store did not answer in time (to be tried again); 78: it cannot be done (the file is not the one the shim recorded, the core refuses for good).
    var runId, workspace, manifestDir, spool, certs, collector, artifactAddr, token = ""
    var termLog = "/dev/termination-log"
    var stepSeq, stepAttempt = 0
    var wait = 120
    var doArtifacts, doLogs = false
    var i = 1
    while i < args.len:
      case args[i]
      of "--artifacts": doArtifacts = true
      of "--logs": doLogs = true
      of "--run-id": (inc i; runId = args[i])
      of "--step-seq": (inc i; stepSeq = parseInt(args[i]))
      of "--step-attempt": (inc i; stepAttempt = parseInt(args[i]))
      of "--workspace": (inc i; workspace = args[i])
      of "--manifest-dir": (inc i; manifestDir = args[i])
      of "--log-spool-dir": (inc i; spool = args[i])
      of "--certs-dir": (inc i; certs = args[i])
      of "--collector-addr": (inc i; collector = args[i])
      of "--artifact-addr": (inc i; artifactAddr = args[i])
      of "--step-token": (inc i; token = args[i])
      of "--termination-log": (inc i; termLog = args[i])
      of "--wait": (inc i; wait = parseInt(args[i]))
      else:
        stderr.writeLine "cicd-shim --drain: unknown argument " & args[i]
        return 2
      inc i
    proc finish(code: int; reason, detail: string): int =
      stderr.writeLine "cicd-shim --drain: " & reason & (if detail.len > 0: ": " & detail else: "")
      writeTermination(termLog, %*{"exit_code": code, "reason": reason, "detail": detail})
      code
    if runId.len == 0 or certs.len == 0 or token.len == 0: return finish(78, "failed", "the run, the certificates and the step's credential are needed")
    let step = StepRef(run_id: runId, seq: uint32(stepSeq), attempt: uint32(stepAttempt))
    if doArtifacts:
      let manifest = manifestDir / "artifacts.manifest"
      var files = readManifest(manifest)
      if files.len > 0:
        if artifactAddr.len == 0: return finish(78, "failed", "no address of the core's artifact service")
        let c = newArtifactClient(artifactAddr, certs)
        defer: c.close()
        let d = deliverFiles(manifest, files,
          proc (f: ManifestFile): tuple[ok, retry: bool; detail: string] =
            let abs = workspace / f.path
            # the workspace is the run's: a later step may have written over the file. What the shim recorded is what was meant, and the SHA-256 is how it is known.
            if not safeRel(f.path) or not fileExists(abs) or fileSha256(abs) != f.sha256:
              return (false, false, "the file is not the one the shim recorded (SHA-256), a later step changed it")
            let r = putFile(c, step, token, f.path, abs, f.size, f.sha256, wait)
            (r.ok, r.retry, r.code & ": " & r.detail),
          proc (f: ManifestFile) = echo "cicd-shim --drain: artifact ", f.path, " put (", f.size, " bytes)")
        if not d.ok: return finish(if d.retry: 77 else: 78, if d.retry: "retry" else: "failed", d.path & ": " & d.detail)
    if doLogs and spool.len > 0 and dirExists(spool):
      if collector.len == 0: return finish(78, "failed", "no address of the core's log service")
      let r = drainLogSpool(collector, certs, spool, step, wait)
      if not r.ok: return finish(77, "retry", "the log: " & r.detail)
    finish(0, "drained", "")

proc main(): int =
  block tools:
    let argv = commandLineParams()
    when defined(shimLogging):
      if argv.len > 0 and argv[0] == "--drain": return drainTool(argv)
    if argv.len > 0 and argv[0] == "--prepare-volume": return prepareVolume(argv)
  var runDir = ""
  var workspaceDir = ""                    # STO-002: the run's shared workspace (default: the parent of --run-dir, as before the run volume)
  var stateDir = ""                        # STO-002: the run's shared state (the env file of STO-003); default: --run-dir, file CICD_ENV
  var termLog = "/dev/termination-log"
  var secretsFile = ""
  var collectorAddr = ""
  var coreAddr = ""
  var certsDir = ""
  var spoolDir = "/cicd/spool"
  var manifestDir = ""                     # where the manifest of the artifacts to deliver is kept: on the run's volume when the Pod has one (a reader Pod can reach it after the
                                           # Pod has ended, docs/artifacts.md), else the spool directory
  var spoolBytes = 10 * 1024 * 1024        # log_spool_bytes (D-27), default 10 MiB
  var holdSeconds = 600                    # log_hold_timeout, default 10 min
  var runId = ""
  var stepSeq, stepAttempt = 0
  var buildNice = 10                       # the build runs at lower CPU priority than the shim (see lowerBuildPriority)
  var buildOomAdj = 500                    # ... and is the OOM killer's first choice; 0 / -1 switch each off
  var exitWait = -1                        # how long the shim asks core for permission to exit (-1: log_hold_timeout)
  var logMaxBytes = 0'i64                  # the profile's per-step log limit; 0 = unlimited (the log is cut there, with a marker)
  var fetchSecrets = false                 # the step has secrets: ask core for the values before the command starts (6.7)
  var secretsWait = 30                     # seconds the shim keeps asking when core does not answer
  var stepToken = ""                       # the step's own credential for that
  var optsJson = ""                        # the Lua step options: mask, metrics, timeout (docs/secrets-masking.md, metrics.md)
  var artifactAddr = ""                    # the core's ArtifactIngest (DAT-003)
  var artifactWait = -1                    # seconds the shim keeps asking when the core or the store does not answer (-1: log_hold_timeout, as for the log: a store that is down for
                                           # a while holds the step, it does not end it)
  var cacheSpecs: seq[CacheDecl]            # the Lua `cache` option (DAT-004)
  var artUpload, artDownload: seq[string]  # the Lua `artifacts` option: what to put into the object store after the command, what to fetch before it
  var timeoutSeconds = 0                   # the step's timeout (Lua `timeout`, StartStep.timeout_seconds); 0 = none
  var termGrace = 20                       # after SIGTERM / timeout: seconds the build gets to stop before SIGKILL
  var cmd: seq[string]
  var args = commandLineParams()
  var i = 0
  while i < args.len:
    case args[i]
    of "--run-dir":
      inc i
      runDir = args[i]
    of "--workspace":
      inc i
      workspaceDir = args[i]
    of "--state-dir":
      inc i
      stateDir = args[i]
    of "--termination-log":
      inc i
      termLog = args[i]
    of "--secrets-file":
      inc i
      secretsFile = args[i]
    of "--collector-addr":
      inc i
      collectorAddr = args[i]
    of "--core-addr":
      inc i
      coreAddr = args[i]
    of "--certs-dir":
      inc i
      certsDir = args[i]
    of "--log-spool-dir":
      inc i
      spoolDir = args[i]
    of "--manifest-dir":
      inc i
      manifestDir = args[i]
    of "--log-spool-bytes":
      inc i
      spoolBytes = parseInt(args[i])
    of "--log-hold-timeout":
      inc i
      holdSeconds = parseInt(args[i])
    of "--build-nice":
      inc i
      buildNice = parseInt(args[i])
    of "--build-oom-adj":
      inc i
      buildOomAdj = parseInt(args[i])
    of "--timeout":
      inc i
      timeoutSeconds = parseInt(args[i])
    of "--term-grace":
      inc i
      termGrace = parseInt(args[i])
    of "--exit-wait":
      inc i
      exitWait = parseInt(args[i])
    of "--log-max-bytes":
      inc i
      logMaxBytes = parseBiggestInt(args[i])
    of "--opts-json":
      inc i
      optsJson = args[i]
    of "--artifact-addr":
      inc i
      artifactAddr = args[i]
    of "--fetch-secrets":
      fetchSecrets = true
    of "--step-token":
      inc i
      stepToken = args[i]
    of "--secrets-wait":
      inc i
      secretsWait = parseInt(args[i])
    of "--run-id":
      inc i
      runId = args[i]
    of "--step-seq":
      inc i
      stepSeq = parseInt(args[i])
    of "--step-attempt":
      inc i
      stepAttempt = parseInt(args[i])
    of "--":
      cmd = args[i + 1 .. ^1]
      break
    else:
      stderr.writeLine "cicd-shim: unknown argument " & args[i]
      return 2
    inc i
  if cmd.len == 0 or runDir.len == 0:
    stderr.writeLine "usage: cicd-shim --run-dir DIR [--termination-log FILE] [--secrets-file FILE] " &
      "[--collector-addr ADDR --core-addr ADDR --certs-dir DIR --run-id ID --step-seq N --step-attempt N\n" &
      "[--log-spool-dir DIR --log-spool-bytes N --log-hold-timeout SECONDS]] " &
      "-- command args..."
    return 2
  var appDecl = none(Declaration)           # the application's own metrics endpoints (Lua `metrics`)
  var maskRuntime = true                   # honour $CICD_MASK (values the build registers while it runs)
  var maskVariants = true                  # base64 / URL-encoded / JSON-escaped forms of every secret
  var maskMinLen = defaultMinLen
  if optsJson.len > 0:
    try:
      let o = parseJson(optsJson)
      if o{"timeout"} != nil and timeoutSeconds == 0: timeoutSeconds = o["timeout"].getInt
      if o{"metrics"} != nil: appDecl = parseDeclaration($o["metrics"])
      cacheSpecs = cacheDecls(optsJson)
      if o{"artifacts"} != nil:
        let decl = declaredArtifacts(o)
        artUpload = decl.upload
        artDownload = decl.download
      if o{"mask"} != nil:
        maskRuntime = o["mask"]{"runtime"}.getBool(true)
        maskVariants = o["mask"]{"variants"}.getBool(true)
        maskMinLen = o["mask"]{"min_length"}.getInt(defaultMinLen)
    except CatchableError:
      stderr.writeLine "cicd-shim: unreadable --opts-json, defaults apply"
  let step = StepRef(run_id: runId, seq: uint32(stepSeq), attempt: uint32(stepAttempt))
  initShimLog(runId, stepSeq, stepAttempt)
  event(seStarted)
  signal(SIGTERM, onTerminate)
  signal(SIGINT, onTerminate)
  let wantLogging = collectorAddr.len > 0 and coreAddr.len > 0 and certsDir.len > 0
  when defined(shimLogging):
    let logging = wantLogging
  else:
    let logging = false
    if wantLogging:
      stderr.writeLine "cicd-shim: log streaming requested but this build has no ZeroMQ client (-d:shimLogging); running without it"
  var secrets: seq[string]
  if secretsFile.len > 0 and fileExists(secretsFile):
    for l in lines(secretsFile):
      if l.len > 0: secrets.add l
  # The step's secrets (6.7): the values come from core over the authenticated channel, with the step's own credential, and go to the environment of the
  # command only; the Pod's specification holds a placeholder per name. They join the masked values before anything is read from the command. If they cannot
  # be had the command is not started: a step must not run without the credentials it was written for.
  var fetched: seq[(string, string)]
  if fetchSecrets:
    var got: FetchedSecrets
    let until = epochTime() + secretsWait.float
    while true:
      got = fetchStepSecrets(coreAddr, certsDir, step, stepToken)
      if got.ok or not got.retry or epochTime() >= until: break
      sleep 1000
    if not got.ok:
      stderr.writeLine "cicd-shim: the step's secrets could not be fetched (" & got.code & "): " & got.detail
      writeTermination(termLog, %*{"exit_code": exitSecretsUnavailable, "reason": "secrets_unavailable", "detail": got.code & ": " & got.detail})
      return exitSecretsUnavailable
    fetched = got.values
    for (n, v) in fetched:
      if v.len == 0: continue
      secrets.add v
      if '\n' in v:
        for l in v.splitLines:
          if l.strip.len > 0: secrets.add l.strip

  # The artifacts the step asked for (DAT-003): fetched from the run's own earlier steps into the workspace, before the command. Without them the command is
  # not started, as with the secrets.
  let workspace = if workspaceDir.len > 0: workspaceDir else: parentDir(runDir)
  if artDownload.len > 0:
    var why = "this shim was built without the connection to core that artifacts need (-d:shimLogging)"
    when defined(shimLogging):
      why = if artifactAddr.len == 0: "the Pod was given no address of the core's artifact service" else: downloadArtifacts(artifactAddr, certsDir, step, stepToken, artDownload, workspace, secretsWait)
    else: discard
    if why.len > 0:
      stderr.writeLine "cicd-shim: the step's artifacts could not be fetched: " & why
      writeTermination(termLog, %*{"exit_code": exitArtifactsUnavailable, "reason": "artifacts_unavailable", "detail": why})
      return exitArtifactsUnavailable

  # The caches the step declared (DAT-004): restored into the workspace before the command; what is said about them goes to the step's log once it exists
  var cacheNotes: seq[string]
  var cacheHit: seq[string]
  # the archive is a file for a while: on the run's volume, which has the room, and not in the Pod's ephemeral storage, which is limited
  let cacheTmp = if stateDir.len > 0: stateDir / "tmp" else: runDir
  if cacheSpecs.len > 0: (try: createDir(cacheTmp) except CatchableError: discard)
  if cacheSpecs.len > 0:
    when defined(shimLogging):
      let restored = restoreCaches(artifactAddr, certsDir, step, stepToken, cacheSpecs, workspace, cacheTmp)
      cacheNotes = restored.notes
      cacheHit = restored.hit
      setCache(restored.restored)
    else:
      cacheNotes.add "cache: not restored (this shim was built without the connection to core that caches need)"

  let maskFile = runDir / "CICD_MASK"
  var maskOffset = 0
  var maskPartial = ""
  proc newMaskValues(): seq[string] =
    ## Values appended to $CICD_MASK since the last look: one value per line, a half-written last line waits. Checked before
    ## every chunk of output is processed - the build wrote its value *before* printing it, so the order holds.
    if not maskRuntime or not fileExists(maskFile): return
    try:
      let size = int(getFileSize(maskFile))
      if size <= maskOffset or maskOffset >= 64 * 1024: return            # nothing new / the file's budget is spent
      var f = open(maskFile, fmRead)
      defer: close(f)
      f.setFilePos(maskOffset)
      var data = newString(min(size - maskOffset, 64 * 1024 - maskOffset))
      let got = f.readChars(data)
      maskOffset += got
      maskPartial.add data[0 ..< got]
      var start = 0
      while true:
        let nl = maskPartial.find('\n', start)
        if nl < 0: break
        let v = maskPartial[start ..< nl].strip(leading = false, chars = {'\r'})
        if v.len > 0: result.add v
        start = nl + 1
      maskPartial = maskPartial[start .. ^1]
    except CatchableError: discard

  let envFile = if stateDir.len > 0: stateDir / "env" else: runDir / "CICD_ENV"     # shared by the steps of the run when the Pod mounts the run volume (STO-003)
  let outFile = runDir / "CICD_OUTPUT"
  # variables exported by previous steps of the job come in through the same validated parser
  var inherited: seq[EnvVar]
  try:
    if fileExists(envFile): inherited = parseEnvFile(readFile(envFile), secrets)
  except EnvError as e:
    writeTermination(termLog, %*{"exit_code": exitEnvRejected, "reason": e.code, "detail": "inherited CICD_ENV: " & e.msg})
    return exitEnvRejected
  createDir(runDir)
  if stateDir.len > 0: createDir(stateDir)
  writeFile(outFile, "")                    # this step starts with an empty output file
  if maskRuntime: writeFile(maskFile, "")   # ... and an empty mask file

  var childEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): childEnv[k] = v
  for e in inherited: childEnv[e.name] = e.value
  for (n, v) in envOf(optsJson, "step_env"): childEnv[n] = v      # the step's own `env`: above what the steps wrote to $CICD_ENV (VAR-004)
  for (n, v) in fetched: childEnv[n] = v          # after the inherited ones: a secret is not overridden by an earlier step's file
  childEnv.del variablesEnv                      # the core's list of variable names is for the header, not for the command
  childEnv["CICD_ENV"] = envFile
  childEnv["CICD_OUTPUT"] = outFile
  childEnv["CICD_RUN_DIR"] = runDir
  childEnv["CICD_WORKSPACE"] = workspace
  if maskRuntime: childEnv["CICD_MASK"] = maskFile
  # poStdErrToStdOut, not poParentStreams: the shim needs a pipe to read the child's bytes itself (to
  # tee them to LogIngest) - inheriting the parent's fds directly (the old behavior) gives the shim no
  # way to see them at all. stdout/stderr are merged into one stream; LogChunk.stream still carries
  # LOG_STREAM_STDOUT/STDERR, so splitting them later is a pure addition, not a wire-format change.
  let p = spawnBuild(cmd, childEnv, buildNice, buildOomAdj, (if dirExists(workspace): workspace else: ""))   # the command starts in the workspace, as the examples assume
  event(seCommandStarted)
  let startedAt = epochTime()
  var stopReason = ""                      # "" | "timeout" | "terminated": why the shim itself ended the build
  var stopAt = 0.0                         # when the build was asked to stop (SIGKILL follows after termGrace)
  var killed = false
  var scraper: Thread[ScrapeArgs]
  let scraping = appDecl.isSome and (appDecl.get.scrapes.len > 0 or appDecl.get.runtime in ["jvm", "auto"])
  if scraping:
    stopScraping.store(false)
    createThread(scraper, scrapeLoop, (appDecl.get, p.pid))
  var usage = Usage()                      # the container's resource use (cgroup), sampled about once a second
  var lastSample = 0.0
  proc sampleResources() =
    usage = maxed(sample(p.pid), usage)
    setResources(usage.cpuUsec.float / 1e6, usage.memPeakBytes, int(usage.oomKills), toMetrics(usage))
    lastSample = epochTime()
  var lp: LogPipeline
  when defined(shimLogging):
    if logging:
      lp = newLogPipeline(LogCfg(collectorAddr: collectorAddr, coreAddr: coreAddr, certs: certsDir, spoolDir: spoolDir,
                                 step: step, spoolCap: spoolBytes.int64, holdSeconds: holdSeconds, secrets: secrets,
                                 maskVariants: maskVariants, maskMinLen: maskMinLen, logMaxBytes: logMaxBytes))
  # VAR-005: the first step of a run starts its log with the values it was given and their digest (the core names the variables in CICD_VARIABLES for that step only)
  when defined(shimLogging):
    if logging and existsEnv(variablesEnv):
      var secretNames: seq[string]
      for (n, v) in fetched: secretNames.add n
      let header = buildHeader(getEnv(variablesEnv), proc (name: string): string = getEnv(name), secretNames)
      if header.len > 0: lp.write(header)
    if logging:
      for n in cacheNotes: lp.write("cicd-shim: " & n & "\n")
  # Read the child's output (stdout and stderr merged, D-27) straight from the pipe: poll with a short timeout so a
  # quiet step still gets its lines flushed, and do not read at all while the log spool is full - the child then blocks
  # on its own pipe, which is the backpressure (nothing is dropped).
  let fd = p.fd
  var buf = newString(16 * 1024)
  while true:
    # the step's timeout, and SIGTERM (the Pod is being deleted: drain, preemption, cancel): the build is asked to stop,
    # then killed after the grace period; the shim carries on to deliver what the build wrote and to report why it ended
    if stopReason.len == 0:
      if termSignal.load != 0:
        stopReason = "terminated"
      elif timeoutSeconds > 0 and epochTime() - startedAt >= timeoutSeconds.float:
        stopReason = "timeout"
      if stopReason.len > 0:
        stopAt = epochTime()
        event(seStopping, reason = stopReason)
        signalBuild(p.pid, SIGTERM)
    elif not killed and epochTime() - stopAt >= termGrace.float:
      killed = true
      event(seKilling)
      signalBuild(p.pid, SIGKILL)
    if epochTime() - lastSample >= 1.0: sampleResources()
    if logging and not lp.canAccept():
      sleep 50
      continue
    var pfd = TPollfd(fd: fd, events: POLLIN)
    let ready = poll(addr pfd, 1, 500)
    if ready < 0:
      if errno == EINTR: continue
      break
    if ready == 0:
      if logging: lp.tick()
      continue
    let n = read(fd, addr buf[0], buf.len)
    if n <= 0: break                       # EOF: the command (and everything it spawned holding the pipe) is done
    # The build's output goes to the log pipeline only (masked, spooled, delivered). The Pod's own log (`kubectl logs`) carries
    # nothing but the shim's CICD-SHIM events: no build output, so no secrets, no rotation of the build's lines, and a tail
    # of it is always the shim's latest state.
    let fresh = newMaskValues()
    if fresh.len > 0 and logging: lp.addSecrets fresh
    if logging:
      lp.write(buf[0 ..< n])
      lp.tick()
  discard close(fd)
  if scraping:
    stopScraping.store(true)
    joinThread(scraper)
  var status: cint
  while waitpid(Pid(p.pid), status, 0) < 0 and errno == EINTR: discard
  let code = if WIFEXITED(status): int(WEXITSTATUS(status)) elif WIFSIGNALED(status): 128 + int(WTERMSIG(status)) else: 1
  sampleResources()                         # the last reading, for the verdict
  event(seCommandExited, cmdExit = code)
  # The artifacts of a step that succeeded (DAT-003): put into the store before the log is finished, so that what happened is in the log. A command that
  # failed or was cut off leaves nothing behind.
  var artifactFailure = ""
  var artifactsUndelivered = false
  if artUpload.len > 0 and code == 0 and stopReason.len == 0:
    var tell: proc (line: string) {.closure.} = proc (line: string) = discard
    when defined(shimLogging):
      if logging: tell = proc (line: string) = lp.write(line & "\n")
      if artifactAddr.len == 0:
        artifactFailure = "the Pod was given no address of the core's artifact service"
      else:
        let up = uploadArtifacts(artifactAddr, certsDir, step, stepToken, artUpload, workspace, (if manifestDir.len > 0: manifestDir else: spoolDir) / "artifacts.manifest", (if artifactWait >= 0: artifactWait else: holdSeconds), tell)
        artifactFailure = up.failure
        artifactsUndelivered = up.undelivered
    else:
      artifactFailure = "this shim was built without the connection to core that artifacts need (-d:shimLogging)"
    if artifactFailure.len > 0:
      stderr.writeLine "cicd-shim: artifacts: " & artifactFailure
      when defined(shimLogging):
        if logging: lp.write("cicd-shim: artifacts: " & artifactFailure & "\n")
    # what became of them, in the Pod log, after the command's own result and before the log's: a core that was away reads the whole story from there (D-53)
    event(if artifactFailure.len == 0: seArtifactsDelivered elif artifactsUndelivered: seArtifactsUndelivered else: seArtifactsFailed)
  # The caches (DAT-004), after a command that succeeded; a failure here is a line in the log, never the step's
  if cacheSpecs.len > 0 and code == 0 and stopReason.len == 0:
    when defined(shimLogging):
      for n in saveCaches(artifactAddr, certsDir, step, stepToken, cacheSpecs, cacheHit, workspace, cacheTmp):
        stderr.writeLine "cicd-shim: " & n
        if logging: lp.write("cicd-shim: " & n & "\n")
  # The step is not finished until its log is: wait (up to log_hold_timeout) for delivery. The Pod stays Running meanwhile.
  # A Pod being deleted has only its termination grace period left, so then the wait is short.
  event(seLogsDelivering)
  let logsDelivered = if logging: lp.finish(if stopReason == "terminated": 15 else: 0) else: true
  event(if logsDelivered: seLogsDelivered else: seLogsUndelivered)

  proc done(reason: string; exitCode: int): int =
    event(seDone, reason = reason, exitCode = exitCode)
    exitCode

  proc release(exitCode: int; reason: string) =
    ## The completion handshake (D-29): tell core the result and wait for its permission to exit. The Pod stays Running
    ## meanwhile. Core unreachable for the whole wait: leave anyway - the termination message and the Pod's status carry the
    ## result (the fallback). A shim being deleted from outside has little time left, so it asks only briefly.
    if not logging: return
    let patience = if stopReason == "terminated": 5 elif exitWait >= 0: exitWait else: holdSeconds
    let until = epochTime() + patience.float
    while true:
      if sendStepReport(coreAddr, certsDir, step, exitCode, reason): return
      if epochTime() >= until:
        stderr.writeLine "cicd-shim: core did not confirm the result within " & $patience & " s, exiting on the termination message"
        return
      sleep 1000

  var outputs: seq[EnvVar]
  try:
    outputs = parseEnvFile(if fileExists(outFile): readFile(outFile) else: "", secrets)
    discard parseEnvFile(if fileExists(envFile): readFile(envFile) else: "", secrets)
  except EnvError as e:
    writeTermination(termLog, %*{"exit_code": exitEnvRejected, "reason": e.code, "detail": e.msg})
    result = done(e.code, exitEnvRejected)       # the last Pod-log line first, then the handshake carries the same final state
    release(exitEnvRejected, e.code)
    return
  var canon = ""
  for o in outputs: canon.add o.name & "=" & o.value & "\n"
  if not logsDelivered:
    # both are said: the log was not delivered, and what became of the artifacts (the reason is the log's, which comes first)
    writeTermination(termLog, %*{"exit_code": exitLogsUndelivered, "reason": "logs_undelivered", "command_exit_code": code,
                                 "result": currentState().result, "logs": "undelivered", "artifacts": $currentState().artifacts,
                                 "detail": "log not delivered within " & $holdSeconds & " s"})
    result = done("logs_undelivered", exitLogsUndelivered)
    release(exitLogsUndelivered, "logs_undelivered")
    return
  # why the build ended: its own exit, our timeout (the step's own failure) or a signal from outside (the cluster's doing:
  # the command was cut off, so what it left behind is unknown - never reported as the step's own failure)
  # a SIGKILL while the cgroup counted OOM kills is the memory limit, not something the step decided: say so
  let reason = if stopReason.len > 0: stopReason elif artifactsUndelivered: "artifacts_undelivered" elif artifactFailure.len > 0: "artifacts_failed" elif code == 0: "ok" elif code == 137 and usage.oomKills > 0: "oom_killed" else: "failed"
  let exitCode = if stopReason == "timeout": exitTimeout elif artifactsUndelivered: exitArtifactsUndelivered elif artifactFailure.len > 0: exitArtifactsFailed else: code
  writeTermination(termLog, %*{"exit_code": exitCode, "reason": reason, "command_exit_code": code,
                               "result": currentState().result, "logs": "delivered", "artifacts": $currentState().artifacts, "outputs": outputs.len, "digest": sha256hex(canon), "detail": artifactFailure})
  result = done(reason, exitCode)
  release(exitCode, reason)

proc safeMain(): int =
  try:
    main()
  except CatchableError as e:
    # a shim failure must reach Kubernetes as a message, not as a bare exit code 1
    var termLog = "/dev/termination-log"
    let a = commandLineParams()
    for i in 0 ..< a.len - 1:
      if a[i] == "--termination-log": termLog = a[i + 1]
    writeTermination(termLog, %*{"exit_code": 71, "reason": "shim_error", "detail": e.msg})
    71

# Nim's own `quit` clamps exit codes above 127 to 127, which would turn a command's 137 (OOM kill) or 143 (SIGTERM) into
# 127 in the Pod's container status; the C library's exit() passes the whole 0..255 range.
proc cExit(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}
let rc = safeMain()
stdout.flushFile()
cExit(cint(rc))
