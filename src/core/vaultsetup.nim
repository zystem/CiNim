## Starting the secrets store (core/secretvault.nim): which master key, and waiting for it. The key is, in this order, a key service next to a token
## (`CINIM_KEYSERVICE_URL`, core/transitclient.nim), a key file (`CINIM_SECRETS_KEY_FILE`), or derived from the core's CURVE key. A key that lives on another machine may not be
## there when the core starts (the machine restarts with it, the token waits for a PIN), so the core does not wait for it: a thread asks every `retryEvery`
## seconds until it answers, and the API says `secrets_unavailable` meanwhile (the shims wait and ask again, and a step that does not need secrets is not held up).
import std/[os, strutils, times, atomics]
import kekprovider, secretvault, transitclient, orgprovision, components
import ../common/rqlite

const retryEvery = 15

proc buildKek*(certs: string): tuple[ok, retry: bool, kek: KekProvider, error: string] =
  let url = getEnv("CINIM_KEYSERVICE_URL")
  if url.len > 0:
    let timeout = try: parseInt(getEnv("CINIM_KEYSERVICE_TIMEOUT_MS", "5000")) except ValueError: 5000
    return httpKek(TransitConfig(url: url, mount: getEnv("CINIM_KEYSERVICE_MOUNT"), keyName: getEnv("CINIM_KEYSERVICE_KEY_NAME", "cinim-shard"),
                                 ca: getEnv("CINIM_KEYSERVICE_CA"), cert: getEnv("CINIM_KEYSERVICE_CERT"), key: getEnv("CINIM_KEYSERVICE_KEY"),
                                 tokenFile: getEnv("CINIM_KEYSERVICE_TOKEN_FILE"), timeoutMs: timeout))
  let keyFile = getEnv("CINIM_SECRETS_KEY_FILE")
  if keyFile.len > 0:
    let k = fileKek(keyFile)
    if not k.ok: return (false, false, KekProvider(), "the key of the secrets: " & k.error)
    return (true, false, k.kek, "")
  (true, false, derivedKek(coreSecret(certs)), "")

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

proc runVaultSetup*(args: tuple[rqliteUrl, certs: string, stop: ptr Atomic[bool]]) {.thread.} =
  {.cast(gcsafe).}:
    let remote = getEnv("CINIM_KEYSERVICE_URL").len > 0
    setDekCacheSeconds(try: parseFloat(getEnv("CINIM_SECRETS_DEK_CACHE", "600")) except ValueError: 600.0)
    if remote:
      kekReport = proc (up: bool) {.gcsafe.} =
        discard registrySet("keyservice", "master-key", (if up: csUp else: csDown), epochTime())
    while not args.stop[].load:
      let r = try: tryActivate(args.rqliteUrl, args.certs) except CatchableError as e: (false, true, "the secrets store could not start: " & e.msg)
      if r.ready:
        if remote: discard registrySet("keyservice", "master-key", csUp, epochTime())
        setVaultError("")
        return
      setVaultError(r.error)
      stderr.writeLine "core: " & r.error & (if r.retry: " (asking again in " & $retryEvery & " s)" else: "")
      if remote and r.retry: discard registrySet("keyservice", "master-key", csDown, epochTime())
      if not r.retry: return               # a different key, a damaged setting: waiting does not help, a person must look
      for _ in 0 ..< retryEvery * 10:
        if args.stop[].load: return
        sleep 100
