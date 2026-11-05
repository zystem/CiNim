## Starting the secrets store (core/secretvault.nim): which master key. The key is a key service next to a token (`CINIM_KEYSERVICE_URL`, core/transitclient.nim: hsmgate, Vault or OpenBao) and nothing
## else: there is no key in a file and none derived from a file (D-106). The key has to be there when the core starts: if the key service does not answer (it restarts, the token waits for a PIN) or
## refuses the core, nothing in the shard can open its secrets, so the core says why and exits, and Kubernetes shows CrashLoopBackOff and starts it again with a growing pause (`setupAtStart`).
## After the start, a key service that goes away is waited for (the shims get `secrets_unavailable` and ask again, the opened data keys are kept for CINIM_SECRETS_DEK_CACHE seconds).
import std/[os, strutils, times, atomics]
import kekprovider, secretvault, transitclient, orgprovision, components
import ../common/[rqlite, ctrlauth]

proc exitImmediately(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
  ## `quit` runs the exit handlers of Nim while the other threads still work, and they crash (exit code 139 and a trace instead of the message); `_exit` does not

proc buildKekFrom*(servicePrefix: string): tuple[ok, retry: bool, kek: KekProvider, error: string] =
  ## The master key from the environment under the names `<servicePrefix>_URL`, `_MOUNT`, `_KEY_NAME`, `_CA`, `_CERT`, `_KEY`, `_TOKEN_FILE`, `_PROXY`, `_TIMEOUT_MS`. The same function reads the key the
  ## core runs with (`CINIM_KEYSERVICE`) and, for `/core rekey` (D-80), the key it moves to (`CINIM_NEW_KEYSERVICE`).
  let url = getEnv(servicePrefix & "_URL")
  if url.len == 0:
    return (false, false, KekProvider(), "no key is given: set " & servicePrefix & "_URL (hsmgate, Vault or OpenBao; the chart's hsmgate does)")
  let timeout = try: parseInt(getEnv(servicePrefix & "_TIMEOUT_MS", "5000")) except ValueError: 5000
  httpKek(TransitConfig(url: url, mount: getEnv(servicePrefix & "_MOUNT"), keyName: getEnv(servicePrefix & "_KEY_NAME", "cinim-shard"),
                        ca: getEnv(servicePrefix & "_CA"), cert: getEnv(servicePrefix & "_CERT"), key: getEnv(servicePrefix & "_KEY"),
                        tokenFile: getEnv(servicePrefix & "_TOKEN_FILE"), proxy: getEnv(servicePrefix & "_PROXY"), timeoutMs: timeout))

proc buildKek*(): tuple[ok, retry: bool, kek: KekProvider, error: string] =
  buildKekFrom("CINIM_KEYSERVICE")

proc buildNewKek*(): tuple[ok, retry: bool, kek: KekProvider, error: string] =
  ## the key `/core rekey` moves to: given by `CINIM_NEW_KEYSERVICE_*`; nothing given is an error
  buildKekFrom("CINIM_NEW_KEYSERVICE")

proc keyGiven*(): bool =
  ## a key service is given for the secrets; there is no mode without one (D-106)
  getEnv("CINIM_KEYSERVICE_URL").len > 0

const noKeyText* = "no key is given for the secrets: set CINIM_KEYSERVICE_URL (hsmgate, Vault or OpenBao; the chart's hsmgate does it)"

proc resolveMasterSecret*(rqliteUrl: string): tuple[ok, retry: bool, error: string] =
  ## The core's own secret (common/ctrlauth.nim), before any thread that uses it starts; nobody supplies it: a new shard's core makes it, and a restored database holds it. It is in the database,
  ## sealed by the key of the secrets (`ensureMasterSecret`; a key service, there is no mode without one). Nothing is read from a file and nothing is brought in.
  if not keyGiven(): return (false, false, noKeyText)
  let b = buildKek()
  if not b.ok: return (false, b.retry, b.error)
  var c = newRq(rqliteUrl)
  let binding = verifyContextBinding(b.kek)           # first: a key that ignores the context is refused before anything is sealed with it
  if not binding.ok: return (false, binding.retry, binding.error)
  let chk = c.ensureKeyCheck(b.kek)
  if not chk.ok: return (false, chk.retry, chk.error)
  let m = c.ensureMasterSecret(b.kek)
  if not m.ok: return (false, m.retry, m.error)
  setMasterSecret(m.secret)
  stderr.writeLine "core: the master secret is kept in the database, sealed by the key " & b.kek.id      # not stdout: the commands of the core print their answer there
  (true, false, "")

proc tryActivate*(rqliteUrl: string): tuple[ready, retry: bool, error: string] =
  ## one attempt; a key that does not open what the database holds is not "retry": waiting will not make it the right key
  let b = buildKek()
  if not b.ok: return (false, b.retry, b.error)
  var c = newRq(rqliteUrl)
  let chk = c.ensureKeyCheck(b.kek)
  if not chk.ok: return (false, chk.retry, chk.error)
  activateVault(b.kek)
  echo "core: the secrets are sealed with the key ", b.kek.id
  (true, false, "")

type SetupAttempt* = tuple[ready, retry: bool, error: string]

proc setupAtStart*(attempt: proc (): SetupAttempt {.gcsafe.}; onReady: proc () {.gcsafe.}; onFatal: proc (error: string; mayPass: bool) {.gcsafe.}) =
  ## One try, at the start of the core. The master key has to be there: if it is not, nothing in the shard can open its secrets and all of it is unusable, so `onFatal` ends the process (the real
  ## one), and Kubernetes shows CrashLoopBackOff, which is the way to tell a person, and starts the core again with a growing pause, which is the retry. `mayPass` is only for the words: the key
  ## service may be back in a moment, or a person has to look.
  let r = try: attempt() except CatchableError as e: (false, true, "the secrets store could not start: " & e.msg)
  if r.ready: onReady() else: onFatal(r.error, r.retry)

proc runVaultSetup*(args: tuple[rqliteUrl: string, stop: ptr Atomic[bool]]) {.thread.} =
  {.cast(gcsafe).}:
    let remote = getEnv("CINIM_KEYSERVICE_URL").len > 0
    setDekCacheSeconds(try: parseFloat(getEnv("CINIM_SECRETS_DEK_CACHE", "600")) except ValueError: 600.0)
    if remote:
      kekReport = proc (up: bool) {.gcsafe.} =
        discard registrySet("keyservice", "master-key", (if up: csUp else: csDown), epochTime())
    setupAtStart(
      proc (): SetupAttempt {.gcsafe.} = {.cast(gcsafe).}: tryActivate(args.rqliteUrl),
      proc () {.gcsafe.} =
        {.cast(gcsafe).}:
          if remote: discard registrySet("keyservice", "master-key", csUp, epochTime())
          setVaultError(""),
      proc (error: string; mayPass: bool) {.gcsafe.} =
        {.cast(gcsafe).}:
          setVaultError(error)
          if remote: discard registrySet("keyservice", "master-key", csDown, epochTime())
          stderr.writeLine "core: FATAL: the secrets store cannot start: " & error
          stderr.writeLine (if mayPass: "core: exiting; the key service may be back in a moment: Kubernetes starts the core again (CrashLoopBackOff, a growing pause)"
                            else: "core: exiting; waiting will not help, a person must look: the key service, its policy for this core, or the key that sealed this database (Kubernetes shows CrashLoopBackOff)")
          flushFile(stderr)
          exitImmediately(1))
