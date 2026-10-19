## `kekd`: the key service of the card (docs/hardware-key.md sections 9 and 10).
##   kekd --key-id HEX --pin-file FILE [--port 8443] [--module /usr/lib/x86_64-linux-gnu/opensc-pkcs11.so] [--token-label cinim]
##        [--public-key-file FILE.der] [--disable-file FILE] [--audit-file FILE] [--client-header x-client] [--per-minute 60] [--per-day 5000]
##   --key-id          the CKA_ID of the master key pair on the card, in hex (what `pkcs11-tool --list-objects` prints as ID)
##   --pin-file        the user PIN, read once at the start (a systemd credential, or a file only the service's user reads); the PIN is tried ONCE: a refusal leaves the service
##                     `locked` until it is started again with the right one (the card blocks after three wrong tries)
##   --transit-key     NAME (repeatable): offer the Transit face to the seal `transit` of OpenBao under this key name; without it the face is off. OpenBao's `mount_path` is --transit-mount (default transit).
##                     Its token is not looked at: who may call is decided by the TLS front's client certificates, as for the core.
##   --public-key-file the master public key (DER SubjectPublicKeyInfo, `pkcs11-tool --read-object --type pubkey`): with it the service starts and wraps with the card out, and
##                     when the card is in its key must be the same one (a different card is refused at the start rather than wrapping for a key nobody holds)
## It listens on every address, in plain HTTP: put it behind the TLS front with the client certificates and close the port to everything else.
import std/[os, strutils, posix, atomics]
import ossl, ecies, pkcs11, service

proc die(msg: string) =
  stderr.writeLine "kekd: " & msg
  quit 2

var
  port = 8443
  module = "/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so"
  tokenLabel = "cinim"
  keyId, pinFile, publicFile, disableFile, auditFile, clientHeader = ""
  transitKeys: seq[string]
  transitMount = ""
  perMinute = 60
  perDay = 5000
  i = 1
proc value(): string =
  inc i
  if i > paramCount(): die "an option without a value: " & paramStr(i - 1)
  paramStr(i)
while i <= paramCount():
  case paramStr(i)
  of "--port": port = parseInt(value())
  of "--module": module = value()
  of "--token-label": tokenLabel = value()
  of "--key-id": keyId = value().toLowerAscii
  of "--pin-file": pinFile = value()
  of "--public-key-file": publicFile = value()
  of "--disable-file": disableFile = value()
  of "--audit-file": auditFile = value()
  of "--client-header": clientHeader = value()
  of "--transit-key": transitKeys.add value()
  of "--transit-mount": transitMount = value()
  of "--per-minute": perMinute = parseInt(value())
  of "--per-day": perDay = parseInt(value())
  else:
    die "usage: kekd --key-id HEX --pin-file FILE [--port N] [--module PATH] [--token-label L] [--public-key-file DER] [--disable-file F] [--audit-file F] [--client-header H] [--transit-key NAME]... [--transit-mount M] [--per-minute N] [--per-day N]"
  inc i
if keyId.len == 0: die "--key-id is needed"
if pinFile.len == 0: die "--pin-file is needed"

var pin = ""
try:
  pin = readFile(pinFile).strip(chars = {'\n', '\r'})
  if (getFilePermissions(pinFile) * {fpGroupRead, fpGroupWrite, fpOthersRead, fpOthersWrite}).len > 0:
    stderr.writeLine "kekd: warning: " & pinFile & " can be read by others than its owner"
except CatchableError as e:
  die "cannot read the PIN file: " & e.msg
if pin.len == 0: die "the PIN file is empty"

var fromFile = ""
if publicFile.len > 0:
  try: fromFile = readFile(publicFile)
  except CatchableError as e: die "cannot read the public key file: " & e.msg
  if fromFile.len != spkiPrefix.len + pointBytes or not fromFile.startsWith(spkiPrefix): die publicFile & " is not a DER public key of P-256"
  fromFile = fromFile[spkiPrefix.len .. ^1]
  if not pointIsValid(fromFile): die publicFile & " does not hold a point of the curve"

let opened = p11Open(P11Config(module: module, tokenLabel: tokenLabel, keyId: keyId, pin: pin))
if not opened.ok: die opened.error
pin = ""
var masterPoint = fromFile
let onCard = p11MasterPoint()
if onCard.ok:
  if fromFile.len > 0 and onCard.value != fromFile: die "the key on the card is not the one in " & publicFile & " (" & fingerprint(onCard.value) & " against " & fingerprint(fromFile) & "): wrong card"
  masterPoint = onCard.value
elif fromFile.len == 0:
  die "the master public key cannot be read from the card (" & onCard.error & ") and there is no --public-key-file"
else:
  stderr.writeLine "kekd: the card is not there now (" & onCard.error & "): wrapping only, until it is"
if not pointIsValid(masterPoint): die "the master public key is not a point of the curve"

configure(ServiceConfig(
  masterPoint: masterPoint,
  derive: proc (peer: string): DeriveResult {.gcsafe.} =
    {.cast(gcsafe).}:                 # the card's state is behind its own lock
      let r = p11Derive(peer)
      result = (r.ok, r.retry, r.error, r.value),
  tokenState: proc (): string {.gcsafe.} =
    {.cast(gcsafe).}:
      result = if p11Locked(): "locked" elif p11MasterPoint().ok: "ready" else: "absent",
  transitKeys: transitKeys, transitMount: transitMount, perMinute: perMinute, perDay: perDay, disableFile: disableFile, auditFile: auditFile, clientHeader: clientHeader))
startService(port)
echo "kekd: the key ", fingerprint(masterPoint), " listening on ", port
var stopFlag: Atomic[bool]
proc onSignal(sig: cint) {.noconv.} = stopFlag.store(true)
signal(SIGINT, onSignal)
signal(SIGTERM, onSignal)
while not stopFlag.load: sleep 200
stopService()
p11Close()
