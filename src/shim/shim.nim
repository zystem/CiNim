## Runner shim (RUN-010): wraps the step command inside the step Pod.
##   cicd-shim --run-dir DIR [--termination-log FILE] [--secrets-file FILE] -- command args...
## It gives the command $CICD_ENV and $CICD_OUTPUT, runs it, validates both files (STO-003, SEC-011)
## and writes a termination message of at most 4 KiB. Exit code: the command's, or 70 for env_rejected.
## Log streaming to the collector over NNG and the job token are the next slice.

import std/[os, osproc, json, strutils, strtabs]
import checksums/sha2
import dotenv

const
  exitEnvRejected = 70
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

proc main(): int =
  var runDir = ""
  var termLog = "/dev/termination-log"
  var secretsFile = ""
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
    of "--":
      cmd = args[i + 1 .. ^1]
      break
    else:
      stderr.writeLine "cicd-shim: unknown argument " & args[i]
      return 2
    inc i
  if cmd.len == 0 or runDir.len == 0:
    stderr.writeLine "usage: cicd-shim --run-dir DIR [--termination-log FILE] [--secrets-file FILE] -- command args..."
    return 2
  var secrets: seq[string]
  if secretsFile.len > 0 and fileExists(secretsFile):
    for l in lines(secretsFile):
      if l.len > 0: secrets.add l

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

  var childEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): childEnv[k] = v
  for e in inherited: childEnv[e.name] = e.value
  childEnv["CICD_ENV"] = envFile
  childEnv["CICD_OUTPUT"] = outFile
  childEnv["CICD_RUN_DIR"] = runDir
  let p = startProcess(cmd[0], args = cmd[1 .. ^1], env = childEnv, options = {poUsePath, poParentStreams})
  let code = p.waitForExit()
  p.close()

  var outputs: seq[EnvVar]
  try:
    outputs = parseEnvFile(if fileExists(outFile): readFile(outFile) else: "", secrets)
    discard parseEnvFile(if fileExists(envFile): readFile(envFile) else: "", secrets)
  except EnvError as e:
    writeTermination(termLog, %*{"exit_code": exitEnvRejected, "reason": e.code, "detail": e.msg})
    return exitEnvRejected
  var canon = ""
  for o in outputs: canon.add o.name & "=" & o.value & "\n"
  writeTermination(termLog, %*{"exit_code": code, "reason": (if code == 0: "ok" else: "failed"),
                               "outputs": outputs.len, "digest": sha256hex(canon)})
  code

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

quit safeMain()
