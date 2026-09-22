## Protocol compatibility N/N-1 (7.1, section 18): `buf breaking` against the image of the previous release (proto/compat/baseline.binpb).
## A change that only adds must pass, every removal, renumbering or retyping must be caught.
import std/[unittest, os, osproc, strutils]

let buf = getEnv("BUF", getHomeDir() / "go" / "bin" / "buf")
let protoDir = getCurrentDir() / "proto"

proc breaking(mutate: proc (dir: string)): int =
  ## copies proto/ to a temp dir, applies the mutation and returns buf's exit code against the baseline
  let tmp = getTempDir() / "cinim-proto-compat"
  removeDir(tmp); createDir(tmp)
  copyDir(protoDir / "cicd", tmp / "cicd")
  copyFile(protoDir / "buf.yaml", tmp / "buf.yaml")
  mutate(tmp)
  result = execCmd(buf & " breaking " & tmp & " --against " & protoDir / "compat" / "baseline.binpb" & " > /dev/null 2>&1")

proc edit(dir, file, before, after: string) =
  let p = dir / "cicd" / file
  let s = readFile(p)
  doAssert before in s, "mutation target not found: " & before
  writeFile(p, s.replace(before, after))

suite "N/N-1: buf breaking against the previous release":
  test "the unchanged tree is compatible with itself":
    check breaking(proc (d: string) = discard) == 0

  test "adding a field, a message and an enum value is allowed":
    check breaking(proc (d: string) =
      edit(d, "internal/v1/step.proto", "string reason = 5;", "string reason = 5;\n  string extra = 9;")
      edit(d, "internal/v1/common.proto", "STEP_STATE_LOST = 8;", "STEP_STATE_LOST = 8;\n  STEP_STATE_PREEMPTED = 9;")
      writeFile(d / "cicd" / "internal" / "v1" / "new.proto", "syntax = \"proto3\";\npackage cicd.internal.v1;\nmessage Extra { string a = 1; }\n")) == 0

  test "removing a field is caught":
    check breaking(proc (d: string) = edit(d, "internal/v1/step.proto", "  int32 exit_code = 4;\n", "")) != 0

  test "changing a field type is caught":
    check breaking(proc (d: string) = edit(d, "internal/v1/step.proto", "int32 exit_code = 4;", "int64 exit_code = 4;")) != 0

  test "renumbering a field is caught":
    check breaking(proc (d: string) = edit(d, "internal/v1/step.proto", "string reason = 5;", "string reason = 15;")) != 0

  test "removing an enum value is caught":
    check breaking(proc (d: string) = edit(d, "internal/v1/common.proto", "  STEP_STATE_LOST = 8;\n", "")) != 0

  test "deleting a message is caught":
    check breaking(proc (d: string) = removeFile(d / "cicd" / "internal" / "v1" / "directory.proto")) != 0

  test "adding a member to an existing oneof is allowed":
    check breaking(proc (d: string) = edit(d, "internal/v1/executor.proto", "    string finish_run_id = 4;", "    string finish_run_id = 4;\n    string oops = 5;")) == 0   # adding a oneof member is compatible
