## Keys of the shim's and the push channel's mutual TLS for a test (tools/grpc/gen_tls.sh), made once per process into a temporary directory that is removed at the end.
## `<dir>/tls/{ca.pem,core.pem,core.key,client.pem,client.key,master.key}`. An empty string means the keys could not be made (no openssl): the test skips.
import std/[os, osproc]

var made = false
var dir = ""

proc removeCerts() {.noconv.} =
  if dir.len > 0: removeDir dir

proc testCerts*(): string =
  if not made:
    made = true
    let d = getTempDir() / ("cinim-test-tls-" & $getCurrentProcessId())
    createDir d
    if execCmd("sh " & quoteShell(getCurrentDir() / "tools" / "grpc" / "gen_tls.sh") & " " & quoteShell(d) & " 2 >/dev/null 2>&1") == 0:
      dir = d
      addQuitProc(removeCerts)
    else:
      removeDir d
  dir
