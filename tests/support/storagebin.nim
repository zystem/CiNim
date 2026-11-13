## The program the process tests of the storage service run: blobgate (github.com/zystem/blobgate), named by BLOBGATE_BIN. The test image has it (tools/image/Dockerfile.test copies it from the published
## image of blobgate and sets the variable); on a machine without it these tests are skipped. For a try by hand: `docker create --name bg ghcr.io/zystem/blobgate:<version>` and
## `docker cp bg:/blobgate <dir>/blobgate`, or build it from a tag of its repository (`CGO_ENABLED=0 go build -o <dir>/blobgate ./cmd/blobgate`).
import std/os

proc blobgateBin*(): string =
  ## the path of the program, "" when the tests are to be skipped
  let b = getEnv("BLOBGATE_BIN")
  if b.len > 0 and fileExists(b): absolutePath(b) else: ""
