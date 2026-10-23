## Starting the secrets store (core/secretvault.nim): which master key. The key is, in this order, a key service next to a token (`CINIM_KEYSERVICE_URL`, core/transitclient.nim), a key file
## (`CINIM_SECRETS_KEY_FILE`), or derived from the core's CURVE key. The key has to be there when the core starts: if the key service does not answer (it restarts, the token waits for a PIN) or
## refuses the core, nothing in the shard can open its secrets, so the core says why and exits, and Kubernetes shows CrashLoopBackOff and starts it again with a growing pause (`setupAtStart`).
## After the start, a key service that goes away is waited for (the shims get `secrets_unavailable` and ask again, the opened data keys are kept for CINIM_SECRETS_DEK_CACHE seconds).
import std/[os, strutils, times, atomics]
import kekprovider, secretvault, transitclient, orgprovision, components
import ../common/rqlite

proc exitImmediately(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
  ## `quit` runs the exit handlers of Nim while the other threads still work, and they crash (exit code 139 and a trace instead of the message); `_exit` does not

proc buildKekFrom*(servicePrefix, keyFileVar: string; certs: string; derivedIfNone: bool): tuple[ok, retry: bool, kek: KekProvider, error: string] =
  ## The master key from the environment under the names `<servicePrefix>_URL`, `_MOUNT`, `_KEY_NAME`, `_CA`, `_CERT`, `_KEY`, `_TOKEN_FILE`, `_PROXY`, `_TIMEOUT_MS`, else the file named by `keyFileVar`, else
  ## (`derivedIfNone`) the key derived from the core's CURVE key. The same function reads the key the core runs with (`CINIM_KEYSERVICE`, `CINIM_SECRETS_KEY_FILE`) and, for `/core rekey`
  ## (D-80), the key it moves to (`CINIM_NEW_KEYSERVICE`, `CINIM_NEW_SECRETS_KEY_FILE`).
  let url = getEnv(servicePrefix & "_URL")
  if url.len > 0:
    let timeout = try: parseInt(getEnv(servicePrefix & "_TIMEOUT_MS", "5000")) except ValueError: 5000
    return httpKek(TransitConfig(url: url, mount: getEnv(servicePrefix & "_MOUNT"), keyName: getEnv(servicePrefix & "_KEY_NAME", "cinim-shard"),
                                 ca: getEnv(servicePrefix & "_CA"), cert: getEnv(servicePrefix & "_CERT"), key: getEnv(servicePrefix & "_KEY"),
                                 tokenFile: getEnv(servicePrefix & "_TOKEN_FILE"), proxy: getEnv(servicePrefix & "_PROXY"), timeoutMs: timeout))
  let keyFile = getEnv(keyFileVar)
  if keyFile.len > 0:
    let k = fileKek(keyFile)
    if not k.ok: return (false, false, KekProvider(), "the key of the secrets: " & k.error)
    return (true, false, k.kek, "")
  if not derivedIfNone: return (false, false, KekProvider(), "no key is given: set " & servicePrefix & "_URL or " & keyFileVar)
  (true, false, derivedKek(coreSecret(certs)), "")

proc buildKek*(certs: string): tuple[ok, retry: bool, kek: KekProvider, error: string] =
  buildKekFrom("CINIM_KEYSERVICE", "CINIM_SECRETS_KEY_FILE", certs, derivedIfNone = true)

proc buildNewKek*(certs: string): tuple[ok, retry: bool, kek: KekProvider, error: string] =
  ## the key `/core rekey` moves to: given by `CINIM_NEW_KEYSERVICE_*` or `CINIM_NEW_SECRETS_KEY_FILE`; nothing given is an error (the key derived from the CURVE key is never moved to by accident)
  buildKekFrom("CINIM_NEW_KEYSERVICE", "CINIM_NEW_SECRETS_KEY_FILE", certs, derivedIfNone = false)

proc tryActivate*(rqliteUrl, certs: string): tuple[ready, retry: bool, error: string] =
  ## one attempt; a key that does not open what the database holds is not "retry": waiting will not make it the right key
  let b = buildKek(certs)
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

proc runVaultSetup*(args: tuple[rqliteUrl, certs: string, stop: ptr Atomic[bool]]) {.thread.} =
  {.cast(gcsafe).}:
    let remote = getEnv("CINIM_KEYSERVICE_URL").len > 0
    setDekCacheSeconds(try: parseFloat(getEnv("CINIM_SECRETS_DEK_CACHE", "600")) except ValueError: 600.0)
    if remote:
      kekReport = proc (up: bool) {.gcsafe.} =
        discard registrySet("keyservice", "master-key", (if up: csUp else: csDown), epochTime())
    setupAtStart(
      proc (): SetupAttempt {.gcsafe.} = {.cast(gcsafe).}: tryActivate(args.rqliteUrl, args.certs),
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
