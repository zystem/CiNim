## The emulator of the key service (src/kekd/emulator.nim) as a program, for developing the core without a card.
##   kekd-emu [--port 8443] [--key-file FILE | --key-secret NAME [--namespace NS]]
##     FILE: 64 hexadecimal digits. NAME: a Kubernetes Secret in the namespace of the Pod (or NS) whose key `key` holds them; it is made at the first start and read at every
##     later one, so that a restart of the Pod does not change the key (the ServiceAccount needs get and create on secrets). Without either a new key is made at every start.
## Then, for example:  CINIM_KEKD_URL=http://127.0.0.1:8443  and
##   curl -X POST localhost:8443/emu/fault -d '{"mode":"fDown"}'      (fNone, fDown, fLocked, fSlow with "delay_ms", fThrottle)
##   curl -X POST localhost:8443/emu/rekey                           (as if another card had been put in)
## It is not secure: it holds the key in plain memory and speaks plain HTTP. Never use it for anything that matters.
import std/[os, strutils, posix, atomics]
import ../../src/kekd/[emulator, keysecret]
import ../../src/core/kubeapi
import ../../src/common/sodiumaead

var port = 8443
var keyFile = ""
var secretName = ""
var namespace = ""
var i = 1
while i <= paramCount():
  case paramStr(i)
  of "--port":
    inc i
    port = parseInt(paramStr(i))
  of "--key-file":
    inc i
    keyFile = paramStr(i)
  of "--key-secret":
    inc i
    secretName = paramStr(i)
  of "--namespace":
    inc i
    namespace = paramStr(i)
  else:
    stderr.writeLine "usage: kekd-emu [--port N] [--key-file FILE | --key-secret NAME [--namespace NS]]"
    quit 2
  inc i

var key: seq[byte]
if keyFile.len > 0:
  let text = readFile(keyFile).strip
  if text.len != 64:
    stderr.writeLine "kekd-emu: " & keyFile & " must hold 64 hexadecimal digits"
    quit 2
  for k in 0 ..< 32: key.add byte(parseHexInt(text[2 * k .. 2 * k + 1]))
if secretName.len > 0:
  let r = keyFromSecret(inCluster(), (if namespace.len > 0: namespace else: ownNamespace()), secretName, proc (): seq[byte] = randomBytes(32))
  if r.error.len > 0:
    stderr.writeLine "kekd-emu: " & r.error
    quit 2
  key = r.key
  echo "kekd-emu: the key is in the Secret ", secretName, (if r.made: " (made now)" else: "")
startEmulator(port, key)
echo "kekd-emu: listening on ", port, " (an emulator: not secure, for development only)"
var stopFlag: Atomic[bool]
proc onSignal(sig: cint) {.noconv.} = stopFlag.store(true)
signal(SIGINT, onSignal)
signal(SIGTERM, onSignal)
while not stopFlag.load: sleep 200
stopEmulator()
