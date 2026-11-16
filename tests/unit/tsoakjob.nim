## NFR-013: the 72 h soak as one step of a pipeline (`.woodpecker/soak.yaml`): `tools/soak/verdict.sh` says whether the soak that wrote a directory passed
## (the release run ended with `SOAK OK`, every ASan hour ended with exit 0 and the hours were all run), and `tools/soak/job.sh` runs the soak into a new
## directory of its own (so that the runs of the weeks do not mix on the volume), prints the summary, keeps the newest runs only, and ends with the verdict
## as its exit code (a pipeline that failed is what shows a bad soak). Run with a stand-in for `run72.sh`: no hour is waited for.
import std/[unittest, os, osproc, strutils, algorithm, sequtils]

let root = currentSourcePath().parentDir.parentDir.parentDir

proc sh(cmd: string; env = ""): tuple[output: string, code: int] =
  let (o, c) = execCmdEx(env & " sh " & cmd, workingDir = root)
  (o, c)

proc outDir(name: string): string =
  result = getTempDir() / ("tsoakjob-" & name & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc fixture(d: string; release: string; hours: seq[int]; finished = true) =
  ## what run72.sh leaves: release.out (its last line is the result), release.csv, san-summary.txt
  writeFile(d / "release.out", "starting\n" & release & "\n")
  writeFile(d / "release.csv", "t,rss\n1,13400\n2,13410\n")
  var s = ""
  for i, code in hours: s.add "hour " & $(i + 1) & " exit=" & $code & "\n"
  if finished: s.add "finished\n"
  writeFile(d / "san-summary.txt", s)

suite "NFR-013 the verdict of a soak":
  test "NFR-013 a release run that ended SOAK OK and ASan hours that all ended well pass":
    let d = outDir("pass")
    fixture(d, "SOAK OK growth 0.09%", @[0, 0, 0])
    let (o, c) = sh("tools/soak/verdict.sh " & d & " 3")
    check c == 0
    check "SOAK OK" in o
    removeDir(d)

  test "NFR-013 a release run that did not end with SOAK OK fails":
    let d = outDir("relfail")
    fixture(d, "SOAK FAIL growth 4.1%", @[0, 0, 0])
    let (o, c) = sh("tools/soak/verdict.sh " & d & " 3")
    check c == 1
    check "did not end with SOAK OK" in o
    removeDir(d)

  test "NFR-013 an ASan hour that did not end with exit 0 fails":
    let d = outDir("sanfail")
    fixture(d, "SOAK OK", @[0, 1, 0])
    let (o, c) = sh("tools/soak/verdict.sh " & d & " 3")
    check c == 1
    check "ASan hours did not end well" in o
    removeDir(d)

  test "NFR-013 ASan hours that did not all run fail, and so does a launcher that never said finished":
    let d = outDir("short")
    fixture(d, "SOAK OK", @[0, 0])
    let (o, c) = sh("tools/soak/verdict.sh " & d & " 3")
    check c == 1
    check "2 of 3" in o
    let d2 = outDir("unfinished")
    fixture(d2, "SOAK OK", @[0, 0, 0], finished = false)
    let (o2, c2) = sh("tools/soak/verdict.sh " & d2 & " 3")
    check c2 == 1
    check "did not finish" in o2
    removeDir(d); removeDir(d2)

  test "NFR-013 a directory with no release.out is an error of its own (exit 2)":
    let d = outDir("empty")
    let (_, c) = sh("tools/soak/verdict.sh " & d)
    check c == 2
    removeDir(d)

suite "NFR-013 the soak as one run of a CronJob":
  setup:
    let base = outDir("job")
    # a stand-in for run72.sh: it writes what a good (or, with FAKE_RELEASE, a bad) soak writes, at once
    writeFile(base / "fake72.sh", """#!/bin/sh
OUT="$1"; HOURS="$2"
echo "args: $OUT $HOURS" > "$OUT/args.txt"
echo "starting" > "$OUT/release.out"; echo "${FAKE_RELEASE:-SOAK OK}" >> "$OUT/release.out"
printf 't,rss\n1,13400\n' > "$OUT/release.csv"
: > "$OUT/san-summary.txt"
i=1; while [ "$i" -le "$HOURS" ]; do echo "hour $i exit=0" >> "$OUT/san-summary.txt"; i=$((i+1)); done
echo finished >> "$OUT/san-summary.txt"
""")
    setFilePermissions(base / "fake72.sh", {fpUserRead, fpUserWrite, fpUserExec})

  teardown:
    removeDir(base)

  test "NFR-013 a run is made in a directory of its own named by the time, with the hours given":
    let (o, c) = sh("tools/soak/job.sh " & base / "out 2", "SOAK_RUN72=" & base / "fake72.sh")
    check c == 0
    let runs = toSeq(walkDirRec(base / "out", yieldFilter = {pcDir}, relative = true)).sorted
    check runs.len == 1
    check runs[0].len == 16          # 20261114T180000Z
    check readFile(base / "out" / runs[0] / "args.txt").strip == "args: " & base / "out" / runs[0] & " 2"
    check "release run" in o
    check "SOAK OK" in o

  test "NFR-013 the exit code is the verdict: a bad release run makes the Job fail":
    let (o, c) = sh("tools/soak/job.sh " & base / "out 2", "FAKE_RELEASE='SOAK FAIL' SOAK_RUN72=" & base / "fake72.sh")
    check c != 0
    check "did not end with SOAK OK" in o

  test "NFR-013 only the newest runs are kept (SOAK_KEEP_RUNS), the older ones of the volume are removed":
    createDir(base / "out")
    for n in ["20260101T000000Z", "20260102T000000Z", "20260103T000000Z", "20260104T000000Z"]:
      createDir(base / "out" / n)
      writeFile(base / "out" / n / "release.out", "SOAK OK\n")
    createDir(base / "out" / "notes")           # what is not a run is not touched
    let (_, c) = sh("tools/soak/job.sh " & base / "out 1", "SOAK_KEEP_RUNS=2 SOAK_RUN72=" & base / "fake72.sh")
    check c == 0
    let left = toSeq(walkDirRec(base / "out", yieldFilter = {pcDir}, relative = true)).filterIt("/" notin it).sorted
    check left.len == 3                          # two runs and `notes`
    check "notes" in left
    check "20260101T000000Z" notin left
    check "20260102T000000Z" notin left
