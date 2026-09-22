## Runner shim (RUN-010, STO-003, SEC-011): runs the step command, then validates CICD_ENV and CICD_OUTPUT with the dotenv parser.
import std/[unittest, os, osproc, json, strutils]

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
