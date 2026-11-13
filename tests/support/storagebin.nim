## The program the process tests of the storage service run: blobgate (github.com/zystem/blobgate), named by BLOBGATE_BIN. The test image has it (tools/image/Dockerfile.test builds the tag
## BLOBGATE_REF and sets the variable); on a machine without it these tests are skipped. For a try by hand: `git archive v0.1.0 | tar -x -C <dir>` in a clone of blobgate and
## `CGO_ENABLED=0 go build -o <dir>/blobgate ./cmd/blobgate`.
import std/os

proc blobgateBin*(): string =
  ## the path of the program, "" when the tests are to be skipped
  let b = getEnv("BLOBGATE_BIN")
  if b.len > 0 and fileExists(b): absolutePath(b) else: ""
