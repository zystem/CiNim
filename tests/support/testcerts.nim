## Keys of the shim's and the push channel's mutual TLS for a test (tools/grpc/gen_tls.sh), made once per process into a temporary directory that is removed at the end.
## `<dir>/tls/{ca.pem,core.pem,core.key,client.pem,client.key,master.key}`. An empty string means the keys could not be made (no openssl): the test skips.
import std/[os, osproc]

var made = false
var dir = ""
var dirAtExit: cstring = nil     # a copy that nothing frees: the quit procedure runs after the module's globals are destroyed (a read of the freed `dir`, AddressSanitizer)

proc removeCerts() {.noconv.} =
  if dirAtExit != nil: removeDir $dirAtExit

proc testCerts*(): string =
  if not made:
    made = true
    let d = getTempDir() / ("cinim-test-tls-" & $getCurrentProcessId())
    createDir d
    if execCmd("sh " & quoteShell(getCurrentDir() / "tools" / "grpc" / "gen_tls.sh") & " " & quoteShell(d) & " 2 >/dev/null 2>&1") == 0:
      dir = d
      dirAtExit = cast[cstring](allocShared0(d.len + 1))
      copyMem(dirAtExit, d.cstring, d.len)
      addQuitProc(removeCerts)
    else:
      removeDir d
  dir
