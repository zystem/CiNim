## Runner shim (RUN-010, STO-003, SEC-011): runs the step command, then validates CICD_ENV and CICD_OUTPUT with the dotenv parser.
import std/[unittest, os, osproc, json, strutils, times, sequtils, streams]
import zippy
import common/spoolwire

let shimExe = getTempDir() / "cinim-shim-test"

proc runShim(dir: string; cmd: string; extraArgs: seq[string] = @[]): tuple[code: int, msg: JsonNode] =
  let tlog = dir / "termination-log"
  removeFile(tlog)
  let p = startProcess(shimExe, args = @["--run-dir", dir, "--termination-log", tlog] & extraArgs & @["--", "sh", "-c", cmd],
                       options = {poStdErrToStdout})
  result.code = p.waitForExit()
  p.close()
  result.msg = if fileExists(tlog): parseJson(readFile(tlog)) else: newJNull()

suite "RUN-010 runner shim":
  test "setup: compile the shim":
    check execCmd("nim c --hints:off --warnings:off -o:" & shimExe & " src/shim/shim.nim") == 0

  test "RUN-010 successful step: exit 0, termination message with outputs digest":
    let d = getTempDir() / "shim-t1"; createDir(d)
    let r = runShim(d, "echo VERSION=1.2 >> \"$CICD_OUTPUT\"; echo FOO=bar >> \"$CICD_ENV\"")
    check r.code == 0
    check r.msg["reason"].getStr == "ok" and r.msg["exit_code"].getInt == 0
    check r.msg["outputs"].getInt == 1 and r.msg["digest"].getStr.len == 64
    check ($r.msg).len <= 4096

  test "STO-003 variables from CICD_ENV of a previous step reach the next step":
    let d = getTempDir() / "shim-t2"; createDir(d)
    writeFile(d / "CICD_ENV", "FOO=bar\n")
    let r = runShim(d, "test \"$FOO\" = bar")
    check r.code == 0 and r.msg["reason"].getStr == "ok"

  test "RUN-010 the command's exit code is propagated and reported":
    let d = getTempDir() / "shim-t3"; createDir(d)
    let r = runShim(d, "exit 3")
    check r.code == 3
    check r.msg["reason"].getStr == "failed" and r.msg["exit_code"].getInt == 3

  test "SEC-011 a deny-listed name written to CICD_ENV ends the step with env_rejected":
    let d = getTempDir() / "shim-t4"; createDir(d)
    let r = runShim(d, "echo LD_PRELOAD=/tmp/x.so >> \"$CICD_ENV\"")
    check r.code == 70
    check r.msg["reason"].getStr == "env_rejected"
    check "LD_PRELOAD" in r.msg["detail"].getStr

  test "SEC-011 a malformed CICD_OUTPUT ends the step with env_rejected":
    let d = getTempDir() / "shim-t5"; createDir(d)
    let r = runShim(d, "echo 'not a pair' >> \"$CICD_OUTPUT\"")
    check r.code == 70 and r.msg["reason"].getStr == "env_rejected"

  test "STO-004 a known secret in an output gives secret_in_output":
    let d = getTempDir() / "shim-t6"; createDir(d)
    writeFile(d / "secrets", "hunter2\n")
    let r = runShim(d, "echo TOKEN=xx-hunter2-yy >> \"$CICD_OUTPUT\"", @["--secrets-file", d / "secrets"])
    check r.code == 70 and r.msg["reason"].getStr == "secret_in_output"
    check "hunter2" notin ($r.msg)          # the secret itself must not be echoed back

  test "SEC-011 the shim's own files are recreated for every step (no stale outputs)":
    let d = getTempDir() / "shim-t7"; createDir(d)
    writeFile(d / "CICD_OUTPUT", "OLD=1\n")
    let r = runShim(d, "true")
    check r.code == 0 and r.msg["outputs"].getInt == 0

  test "RUN-010 a missing run directory is created (first step on a clean volume)":
    let d = getTempDir() / "shim-t8" / "nested" / ".run"
    removeDir(getTempDir() / "shim-t8"); createDir(getTempDir() / "shim-t8")
    let r = runShim(getTempDir() / "shim-t8", "true", @[])   # run-dir below is given explicitly instead:
    check r.code == 0
    let p = startProcess(shimExe, args = @["--run-dir", d, "--termination-log", getTempDir() / "shim-t8" / "tlog", "--", "true"])
    check p.waitForExit() == 0
    p.close()
    check dirExists(d)

  test "RUN-010 an internal failure still yields a termination message (shim_error), not a bare crash":
    let d = getTempDir() / "shim-t9"; createDir(d)
    let r = runShim(d, "true", @["--secrets-file", "/nonexistent/dir/../"])   # unreadable path must not crash the shim
    check r.code in [0, 71]
    check r.msg.kind == JObject
    # a command that cannot be started
    let tlog = d / "tl2"
    let p = startProcess(shimExe, args = @["--run-dir", d, "--termination-log", tlog, "--", "/no/such/binary"])
    check p.waitForExit() == 71
    p.close()
    check parseJson(readFile(tlog))["reason"].getStr == "shim_error"

proc runShimLines(dir: string; cmd: string; extraArgs: seq[string]; signalAfterMs = 0): tuple[code: int, msg: JsonNode, stdoutText: string, secs: float] =
  ## like runShim, but keeps the output and can send SIGTERM to the shim after a while
  let tlog = dir / "termination-log"
  removeFile(tlog)
  let t0 = epochTime()
  let p = startProcess(shimExe, args = @["--run-dir", dir, "--termination-log", tlog] & extraArgs & @["--", "sh", "-c", cmd],
                       options = {poStdErrToStdout})
  if signalAfterMs > 0:
    sleep signalAfterMs
    discard execCmd("kill -TERM " & $p.processID)
  result.stdoutText = p.outputStream.readAll()
  result.code = p.waitForExit()
  p.close()
  result.secs = epochTime() - t0
  result.msg = if fileExists(tlog): parseJson(readFile(tlog)) else: newJNull()

proc events(output: string): seq[JsonNode] =
  for l in output.splitLines:
    if l.startsWith("CICD-SHIM "): result.add parseJson(l["CICD-SHIM ".len .. ^1])

suite "D-29: timeout, SIGTERM, exit codes, the Pod-log events":
  # The Pod log carries only the shim's events, never the build's output - so the tests watch the build through a file.
  proc obs(dir: string): string =
    if fileExists(dir / "obs"): readFile(dir / "obs") else: ""
  const note = " >> \"$CICD_RUN_DIR/obs\""

  test "exit codes above 127 reach the container status unclamped (137 = OOM kill, 143 = SIGTERM)":
    let d = getTempDir() / "shim-x1"; createDir(d)
    for c in [137, 143, 200, 255]:
      check runShim(d, "exit " & $c).code == c

  test "the step's timeout ends the build: reason timeout, exit 124, the whole process tree":
    let d = getTempDir() / "shim-x2"; removeDir(d); createDir(d)
    let r = runShimLines(d, "echo start" & note & "; sleep 60 & sleep 60; echo never" & note, @["--timeout", "2", "--term-grace", "2"])
    check r.code == 124
    check r.msg["reason"].getStr == "timeout" and r.msg["exit_code"].getInt == 124
    check r.secs < 15                                   # not 60: the background `sleep` died with its group
    check "never" notin obs(d) and "start" in obs(d)

  test "a build that ignores SIGTERM is killed after the grace period":
    let d = getTempDir() / "shim-x3"; createDir(d)
    let r = runShimLines(d, "trap '' TERM; sleep 60 & wait", @["--timeout", "1", "--term-grace", "1"])
    check r.code == 124 and r.secs < 15
    check r.msg["command_exit_code"].getInt == 137

  test "SIGTERM from outside (drain, preemption): forwarded to the build, reason terminated, the build's own exit code":
    let d = getTempDir() / "shim-x4"; removeDir(d); createDir(d)
    let r = runShimLines(d, "trap 'echo got-term" & note & "; exit 3' TERM; sleep 60 & wait", @["--term-grace", "5"], signalAfterMs = 1000)
    check r.code == 3
    check r.msg["reason"].getStr == "terminated" and r.msg["command_exit_code"].getInt == 3
    check "got-term" in obs(d) and r.secs < 15

  test "SIGTERM to a build that ignores it: killed after the grace period, still reported as terminated":
    let d = getTempDir() / "shim-x5"; createDir(d)
    let r = runShimLines(d, "trap '' TERM; sleep 60 & wait", @["--term-grace", "1"], signalAfterMs = 1000)
    check r.code == 137 and r.msg["reason"].getStr == "terminated" and r.secs < 15

  test "the build runs below the shim's priority, in its own process group":
    let d = getTempDir() / "shim-x6"; removeDir(d); createDir(d)
    discard runShimLines(d, "cat /proc/self/oom_score_adj" & note & "; ps -o ni=,pgid=,pid= -p $$" & note, @[])
    let lines = obs(d).splitLines.filterIt(it.strip.len > 0)
    check lines[0].strip == "500"
    let f = lines[1].splitWhitespace
    check f[0] == "10" and f[1] == f[2]                 # nice 10; pgid == pid: the build leads its own group

  test "every transition is a line in the Pod log; the last one is the verdict":
    let d = getTempDir() / "shim-x7"; createDir(d)
    let r = runShimLines(d, "echo hello; exit 4", @[])
    let ev = events(r.stdoutText)
    check ev.mapIt(it["ev"].getStr) == @["started", "command_started", "command_exited", "logs_delivering", "logs_delivered", "done"]
    check ev[^1]["reason"].getStr == "failed" and ev[^1]["exit"].getInt == 4 and ev[^1]["cmd"]["exit"].getInt == 4
    check ev[^1]["n"].getInt == 6                       # numbered: a gap shows that the head of the log was rotated away
    check r.stdoutText.splitLines.filterIt(it.len > 0)[^1].startsWith("CICD-SHIM ")      # the verdict is the very last line

  test "the Pod log carries only the shim's events - never the build's output, whatever it prints":
    let d = getTempDir() / "shim-x8"; createDir(d)
    let r = runShimLines(d, "echo hello; printf partial; echo secret-looking-value 1>&2", @[])
    for l in r.stdoutText.splitLines:
      if l.len > 0: check l.startsWith("CICD-SHIM ")
    check "hello" notin r.stdoutText and "partial" notin r.stdoutText and "secret-looking" notin r.stdoutText

suite "secret masking through the log pipeline (docs/secrets-masking.md)":
  # The logging build writes the masked records into its spool; with a core that cannot be reached they stay there, so the
  # test reads what *would* have been sent. Needs libzmq on the machine (the dlopen build) and the test CURVE keys.
  let logExe = getTempDir() / "cinim-shim-log-test"
  let certs = getCurrentDir() / "tests" / "certs"
  var available = false

  test "setup: compile the logging shim":
    available = execCmd("nim c --hints:off --warnings:off -d:shimLogging -o:" & logExe & " src/shim/shim.nim") == 0 and
                dirExists(certs / "curve")
    if not available: skip()

  proc spooled(dir: string; cmd: string; extra: seq[string] = @[]): string =
    ## run the logging shim against a core nobody listens on and return the text of the records it spooled
    let sp = dir / "spool"
    removeDir(dir); createDir(dir)
    let p = startProcess(logExe, args = @["--run-dir", dir, "--termination-log", dir / "tl", "--collector-addr", "tcp://127.0.0.1:1",
      "--core-addr", "tcp://127.0.0.1:1", "--certs-dir", certs, "--run-id", "s1_m", "--step-seq", "0", "--step-attempt", "1",
      "--log-spool-dir", sp, "--log-hold-timeout", "2"] & extra & @["--", "sh", "-c", cmd], options = {poStdErrToStdout})
    discard p.waitForExit(60000)
    p.close()
    for f in walkFiles(sp / "*.blk"): result.add uncompress(readFile(f))

  test "a known secret is masked in the records, raw and base64":
    if not available: skip()
    else:
      let d = getTempDir() / "shim-m1"; createDir(d)
      let sf = d / "secrets"
      writeFile(sf, "hunter2-secret-value\n")
      let text = spooled(getTempDir() / "shim-m1b", "echo raw hunter2-secret-value; echo b64 $(printf 'x:hunter2-secret-value' | base64)",
                         @["--secrets-file", sf])
      check "raw ***" in text
      check "hunter2-secret-value" notin text and "aHVudGVyMi1zZWNyZXQtdmFsdWU" notin text

  test "a step secret that arrives as an environment variable (--secret-env) is masked, and the build still sees it":
    if not available: skip()
    else:
      putEnv("CINIM_TEST_SECRET", "registry-pa55w0rd-value")
      putEnv("CINIM_TEST_KEY", "-----BEGIN KEY-----\nline-two-of-the-key\n-----END KEY-----")
      defer: delEnv("CINIM_TEST_SECRET"); delEnv("CINIM_TEST_KEY")
      let text = spooled(getTempDir() / "shim-m5", "echo pw $CINIM_TEST_SECRET; echo used-ok=$([ -n \"$CINIM_TEST_SECRET\" ] && echo yes); echo key $CINIM_TEST_KEY; echo b64 $(printf '%s' \"$CINIM_TEST_SECRET\" | base64)",
                         @["--secret-env", "CINIM_TEST_SECRET,CINIM_TEST_KEY,NOT_SET_ANYWHERE"])
      check "pw ***" in text and "used-ok=yes" in text
      check "registry-pa55w0rd-value" notin text and "line-two-of-the-key" notin text
      check "cmVnaXN0cnktcGE1NXcwcmQtdmFsdWU" notin text

  test "the build registers a value in $CICD_MASK and the lines after it are masked":
    if not available: skip()
    else:
      let text = spooled(getTempDir() / "shim-m2", "echo plain line; echo token-777777 >> \"$CICD_MASK\"; echo after token-777777 end")
      check "plain line" in text and "after *** end" in text and "token-777777" notin text

  test "mask = false: no $CICD_MASK, no variants":
    if not available: skip()
    else:
      let d = getTempDir() / "shim-m3"
      let text = spooled(d, "echo \"mask file: [$CICD_MASK]\"", @["--opts-json", """{"mask":{"min_length":4,"runtime":false,"variants":false}}"""])
      check "mask file: []" in text

suite "reading the spool through exec (the fallback for a shim that cannot reach core)":
  let logExe = getTempDir() / "cinim-shim-log-test"
  let certs = getCurrentDir() / "tests" / "certs"

  test "--read-spool gives whole checksummed blocks, --after-seq skips what core has, --ack-spool frees them":
    if not fileExists(logExe) or not dirExists(certs / "curve"): skip()
    else:
      let d = getTempDir() / "shim-spool-tool"
      removeDir d
      createDir d
      let sp = d / "spool"
      # a shim that cannot deliver (nobody listens): everything it read stays in the spool
      let p = startProcess(logExe, args = @["--run-dir", d, "--termination-log", d / "tl", "--collector-addr", "tcp://127.0.0.1:1",
        "--core-addr", "tcp://127.0.0.1:1", "--certs-dir", certs, "--run-id", "s1_m", "--step-seq", "0", "--step-attempt", "1",
        "--log-spool-dir", sp, "--log-hold-timeout", "2", "--", "sh", "-c", "seq 1 20000"], options = {poStdErrToStdout})
      discard p.waitForExit(60000)
      p.close()
      # (execCmdEx reads lines and would rewrite a "\r\n" inside a binary block: go through a file)
      proc readSpool(extra = ""): string =
        let f = d / "read.out"
        discard execCmd(logExe & " --read-spool " & sp & extra & " > " & f)
        readFile(f)
      let out1 = readSpool()
      let all = parseFrames(out1)
      check not all.damaged and all.frames.len >= 2
      check all.frames[0].seq == 1 and all.frames[0].encoding == "gzip"
      var total = 0'u32
      for f in all.frames:
        check uncompress(f.data).len > 0
        total += f.lines
      check total == 20000
      let out2 = readSpool(" --after-seq " & $all.frames[0].seq)
      check parseFrames(out2).frames.len == all.frames.len - 1
      let out3 = readSpool(" --max-bytes 1")
      check parseFrames(out3).frames.len == 1                   # at least one block, however small the budget
      check execCmd(logExe & " --ack-spool " & sp & " --upto " & $all.frames[0].seq) == 0
      check parseFrames(readSpool()).frames.len == all.frames.len - 1
      check execCmd(logExe & " --ack-spool " & sp & " --upto 999999") == 0
      check parseFrames(readSpool()).frames.len == 0
  test "a spool that cannot be written degrades the log, never the step":
    if not fileExists(logExe) or not dirExists(certs / "curve"): skip()
    else:
      let d = getTempDir() / "shim-spool-broken"
      removeDir d
      createDir d
      # /proc is not writable: the spool directory cannot even be created
      let p = startProcess(logExe, args = @["--run-dir", d, "--termination-log", d / "tl", "--collector-addr", "tcp://127.0.0.1:1",
        "--core-addr", "tcp://127.0.0.1:1", "--certs-dir", certs, "--run-id", "s1_m", "--step-seq", "0", "--step-attempt", "1",
        "--log-spool-dir", "/proc/nonexistent/spool", "--log-hold-timeout", "10", "--exit-wait", "1", "--", "sh", "-c", "seq 1 5000"],
        options = {poStdErrToStdout})
      let output = p.outputStream.readAll()
      check p.waitForExit(60000) == 0                         # the command's own result stands
      p.close()
      check parseJson(readFile(d / "tl"))["reason"].getStr == "ok"
      check "log spool unusable" in output
      var last: JsonNode
      for l in output.splitLines:
        if l.startsWith("CICD-SHIM "): last = parseJson(l["CICD-SHIM ".len .. ^1])
      check last["ev"].getStr == "done" and last["dropped"].getInt >= 1     # the loss is counted where the verdict is
  test "a missing spool directory is an error, not an empty answer":
    if not fileExists(logExe): skip()
    else: check execCmd(logExe & " --read-spool /nonexistent/spool 2>/dev/null") == 3 * 256 or execCmd(logExe & " --read-spool /nonexistent/spool 2>/dev/null") != 0

suite "step options in the shim":
  test "the step timeout can come in the options object":
    let d = getTempDir() / "shim-m4"; createDir(d)
    let r = runShimLines(d, "sleep 60", @["--opts-json", """{"timeout":1}""", "--term-grace", "1"])
    check r.code == 124 and r.secs < 15
