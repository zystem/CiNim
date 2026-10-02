## Runner shim (RUN-010): wraps the step command inside the step Pod. It is the first process of the container and outlives the
## command; its priority is higher than the build's.
##   cicd-shim --run-dir DIR [--termination-log FILE] [--secrets-file FILE] [--collector-addr ADDR --core-addr ADDR --certs-dir DIR
##             --run-id ID --step-seq N --step-attempt N --log-spool-dir DIR ...] [--opts-json JSON] -- command args...
## What it does (D-27 – D-30, docs/):
##   - gives the command $CICD_ENV, $CICD_OUTPUT and $CICD_MASK, validates the files after it (STO-003, SEC-011);
##   - starts the command in its own process group, below its own CPU priority, and enforces the step's timeout and SIGTERM;
##   - turns the output into masked, numbered, compressed blocks in a spool on the Pod's ephemeral storage and delivers them to
##     core (logclient.nim); the Pod's own log carries only the shim's events (shimlog.nim);
##   - samples the container's resources, reads a JVM's counters and scrapes the application's endpoints (metrics);
##   - reports its state to core with every heartbeat and its result in StepReport, then waits for core's permission to exit; the
##     termination message (at most 4 KiB) and the Pod status stay the fallback;
##   - `--read-spool DIR` / `--ack-spool DIR` are the exec tools the job-controller uses to pull an undelivered spool out of a Pod.
## Exit code: the command's, 124 for a timeout, 70 for env_rejected, 72 for logs_undelivered, 71 for an internal error.
## The default build has no ZeroMQ (it runs in any image); the production build is -d:shimLogging, linked statically
## (tools/shim/build_static.sh).

import std/[os, osproc, json, strutils, strtabs, posix, times, atomics, options]
import checksums/sha2
import dotenv, shimlog, secretmask, appmetrics, resmetrics, appscrape
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

const
  exitTimeout = 124            ## the step ran past its timeout_seconds (the same code `timeout(1)` uses)
  exitEnvRejected = 70
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

proc spawnBuild(cmd: seq[string]; env: StringTableRef; nice, oomAdj: int): Build =
  ## Starts the build in its own process group, with its CPU priority lowered and its OOM score raised, *before* it
  ## execs - so there is no window in which it runs at the shim's priority, and every process it starts inherits all
  ## three. (osproc.startProcess cannot do this: setpgid after exec is refused.) Why the build is made less important
  ## rather than the shim more: the shim must outlive trouble in the build - under CPU contention it still has to read
  ## the pipe, report to core and deliver the log, and when the container runs out of memory the OOM killer should take
  ## the build, not the shim; an unprivileged process can only lower itself and its children. Why the group: a timeout or
  ## SIGTERM has to reach everything the build started, not only `sh`.
  ## Called while the shim is still single-threaded (the log sender starts later), which is what makes fork safe here.
  var fds, errFds: array[2, cint]
  if pipe(fds) != 0 or pipe(errFds) != 0: raise newException(OSError, "pipe failed")
  discard fcntl(errFds[1], F_SETFD, FD_CLOEXEC)       # closes by itself when the exec succeeds: the parent sees EOF
  var argv = allocCStringArray(cmd)
  var envp: seq[string]
  for k, v in env: envp.add k & "=" & v
  let envArr = allocCStringArray(envp)
  let oomPath = "/proc/self/oom_score_adj"
  let oomVal = $oomAdj
  let pid = fork()
  if pid < 0: raise newException(OSError, "fork failed")
  if pid == 0:
    # the child: only async-signal-safe calls from here to exec
    discard setpgid(Pid(0), Pid(0))
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

when defined(shimLogging):
  import logspool, ../common/spoolwire

  proc spoolTool(args: seq[string]): int =
    ## `cicd-shim --read-spool DIR [--after-seq N] [--max-bytes M]` writes the queued, undelivered blocks to stdout as frames
    ## (common/spoolwire.nim); `cicd-shim --ack-spool DIR --upto N` removes the blocks core now has. Both are run by the
    ## job-controller through the Kubernetes exec API when this shim cannot reach core itself (D-29). Read-only apart
    ## from the ack; they never touch the running shim's own bookkeeping, which is why the shim's sender may still be
    ## sending the same blocks: core takes each sequence number once.
    var dir = ""
    var afterSeq = 0'u64
    var maxBytes = 8 * 1024 * 1024
    var upto = 0'u64
    var paceMs = 2                               # pause between 4095-byte pieces (see below)
    var lingerMs = 700                           # how long to stay alive after the last byte (see below)
    var mode = ""
    var i = 0
    while i < args.len:
      case args[i]
      of "--read-spool", "--ack-spool":
        mode = args[i]
        inc i
        dir = args[i]
      of "--after-seq":
        inc i
        afterSeq = parseBiggestUInt(args[i])
      of "--max-bytes":
        inc i
        maxBytes = parseInt(args[i])
      of "--upto":
        inc i
        upto = parseBiggestUInt(args[i])
      of "--pace-ms":
        inc i
        paceMs = parseInt(args[i])
      of "--linger-ms":
        inc i
        lingerMs = parseInt(args[i])
      else:
        stderr.writeLine "cicd-shim: unknown argument " & args[i]
        return 2
      inc i
    if not dirExists(dir):
      stderr.writeLine "cicd-shim: no spool directory " & dir
      return 3
    if mode == "--read-spool":
      var sent = 0
      for q in peek(dir, maxBlocks = 1_000_000, maxBytes = maxBytes):
        if q.blk.seq <= afterSeq: continue
        let frame = encodeFrame(Frame(seq: q.blk.seq, firstLn: q.blk.firstLn, lines: q.blk.lines, encoding: q.blk.encoding,
                                      data: q.blk.data))
        if sent > 0 and sent + frame.len > maxBytes: break
        # Written in pieces of one websocket frame (4095 bytes of payload) with a short pause: the C client's WebSocket exec
        # loses frames when a producer streams at full speed (measured: half of 1 MB of zeros arrived), and is lossless when
        # paced. The checksum on every block catches whatever still goes wrong, and the reader asks again.
        var off = 0
        while off < frame.len:
          let n = min(4095, frame.len - off)
          stdout.write frame[off ..< off + n]
          stdout.flushFile()
          off += n
          if paceMs > 0: sleep paceMs
        sent += frame.len
      stdout.flushFile()
      # The exec stream is closed as soon as this process exits, and frames still in flight at that moment are lost (measured:
      # a short output was cut after ~3.6 KB). Staying alive a moment lets the client read everything first.
      sleep lingerMs
      return 0
    for f in walkFiles(dir / "*.blk"):           # --ack-spool
      let name = extractFilename(f)
      let seqNo = try: parseBiggestUInt(name.split('-')[0]) except ValueError: 0'u64
      if seqNo > 0 and seqNo <= upto: removeFile(f)
    0

proc main(): int =
  when defined(shimLogging):
    let argv = commandLineParams()
    if argv.len > 0 and argv[0] in ["--read-spool", "--ack-spool"]: return spoolTool(argv)
  var runDir = ""
  var termLog = "/dev/termination-log"
  var secretsFile = ""
  var collectorAddr = ""
  var coreAddr = ""
  var certsDir = ""
  var spoolDir = "/cicd/spool"
  var spoolBytes = 10 * 1024 * 1024        # log_spool_bytes (D-27), default 10 MiB
  var holdSeconds = 600                    # log_hold_timeout, default 10 min
  var runId = ""
  var stepSeq, stepAttempt = 0
  var buildNice = 10                       # the build runs at lower CPU priority than the shim (see lowerBuildPriority)
  var buildOomAdj = 500                    # ... and is the OOM killer's first choice; 0 / -1 switch each off
  var exitWait = -1                        # how long the shim asks core for permission to exit (-1: log_hold_timeout)
  var logMaxBytes = 0'i64                  # the profile's per-step log limit; 0 = unlimited (the log is cut there, with a marker)
  var optsJson = ""                        # the Lua step options: mask, metrics, timeout (docs/secrets-masking.md, metrics.md)
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

  let envFile = runDir / "CICD_ENV"
  let outFile = runDir / "CICD_OUTPUT"
  # variables exported by previous steps of the job come in through the same validated parser
  var inherited: seq[EnvVar]
  try:
    if fileExists(envFile): inherited = parseEnvFile(readFile(envFile), secrets)
  except EnvError as e:
    writeTermination(termLog, %*{"exit_code": exitEnvRejected, "reason": e.code, "detail": "inherited CICD_ENV: " & e.msg})
    return exitEnvRejected
  createDir(runDir)
  writeFile(outFile, "")                    # this step starts with an empty output file
  if maskRuntime: writeFile(maskFile, "")   # ... and an empty mask file

  var childEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): childEnv[k] = v
  for e in inherited: childEnv[e.name] = e.value
  childEnv["CICD_ENV"] = envFile
  childEnv["CICD_OUTPUT"] = outFile
  childEnv["CICD_RUN_DIR"] = runDir
  if maskRuntime: childEnv["CICD_MASK"] = maskFile
  # poStdErrToStdOut, not poParentStreams: the shim needs a pipe to read the child's bytes itself (to
  # tee them to LogIngest) - inheriting the parent's fds directly (the old behavior) gives the shim no
  # way to see them at all. stdout/stderr are merged into one stream; LogChunk.stream still carries
  # LOG_STREAM_STDOUT/STDERR, so splitting them later is a pure addition, not a wire-format change.
  let p = spawnBuild(cmd, childEnv, buildNice, buildOomAdj)
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
    writeTermination(termLog, %*{"exit_code": exitLogsUndelivered, "reason": "logs_undelivered",
                                 "command_exit_code": code, "detail": "log not delivered within " & $holdSeconds & " s"})
    result = done("logs_undelivered", exitLogsUndelivered)
    release(exitLogsUndelivered, "logs_undelivered")
    return
  # why the build ended: its own exit, our timeout (the step's own failure) or a signal from outside (the cluster's doing:
  # the command was cut off, so what it left behind is unknown - never reported as the step's own failure)
  # a SIGKILL while the cgroup counted OOM kills is the memory limit, not something the step decided: say so
  let reason = if stopReason.len > 0: stopReason elif code == 0: "ok" elif code == 137 and usage.oomKills > 0: "oom_killed" else: "failed"
  let exitCode = if stopReason == "timeout": exitTimeout else: code
  writeTermination(termLog, %*{"exit_code": exitCode, "reason": reason, "command_exit_code": code,
                               "outputs": outputs.len, "digest": sha256hex(canon)})
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
