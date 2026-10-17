## cinim-storage: the storage module as a program (docs/storage-module.md, D-60). A Deployment with no volume: every setting is in rqlite and in the environment.
##   CINIM_RQLITE_URL          the rqlite it keeps its tables (`storage_*`) in; the shard's own, or one of its own for a module that serves several shards
##   CINIM_STORAGE_PORT        the port of the API (default 18090)
##   CINIM_STORAGE_SHARDS      `<shard>=<secret>;<shard>=<secret>`: the shards it serves and the secret of each (the core of that shard signs its calls with it)
##                             (or, for one shard: CINIM_STORAGE_TOKEN, and CINIM_SHARD, default 001)
##   CINIM_STORAGE_ADMIN_TOKEN the operator's token for /v1/admin/... (at least 16 characters)
##   CINIM_STORAGE_SHIM_PORT, CINIM_STORAGE_SHIM_THREADS  the port for shims (18091, 0: none) and its threads (8): the direct transfer of D-61
##   CINIM_STORAGE_THREADS     the threads of the HTTP server (16); each holds a receive buffer of 10 MiB, so memory is about 20 MiB a thread at the busiest
##   CINIM_STORAGE_REPAIR_SECONDS, CINIM_STORAGE_CHECK_SECONDS  how often the repair queue is worked (60) and a slice of the inventory is checked against the nodes (600)
##   CINIM_STORAGE_SEAL_KEY    the key the stores' secrets are sealed under in the database (at least 16 characters; keep it apart from the database)
import std/[os, strutils, tables, atomics, posix, times, json, sequtils]
import ../common/[rqlite, httpsrv]
import schema, seal, service

proc fatal(msg: string) =
  stderr.writeLine "storage: " & msg
  quit 2

proc main() =
  let url = getEnv("CINIM_RQLITE_URL")
  if url.len == 0: fatal("CINIM_RQLITE_URL is not set")
  var secrets = initTable[string, string]()
  for pair in getEnv("CINIM_STORAGE_SHARDS").split(';'):
    if pair.strip.len == 0: continue
    let eq = pair.find('=')
    if eq < 1: fatal("CINIM_STORAGE_SHARDS is <shard>=<secret>;<shard>=<secret>")
    secrets[pair[0 ..< eq].strip] = pair[eq + 1 .. ^1].strip
  if secrets.len == 0 and getEnv("CINIM_STORAGE_TOKEN").len > 0: secrets[getEnv("CINIM_SHARD", "001")] = getEnv("CINIM_STORAGE_TOKEN")
  if secrets.len == 0: fatal("no shard is served: set CINIM_STORAGE_SHARDS or CINIM_STORAGE_TOKEN")
  for shard, sec in secrets:
    if not shard.allIt(it in {'0' .. '9'}) or shard.len == 0: fatal("a shard is made of digits only (SHD-001): " & shard)
    if sec.len < 16: fatal("the secret of shard " & shard & " is shorter than 16 characters")
  let admin = getEnv("CINIM_STORAGE_ADMIN_TOKEN")
  if admin.len < 16: fatal("CINIM_STORAGE_ADMIN_TOKEN is shorter than 16 characters")
  let sealText = getEnv("CINIM_STORAGE_SEAL_KEY")
  if sealText.len < 16: fatal("CINIM_STORAGE_SEAL_KEY is shorter than 16 characters")
  cfg = ServiceConfig(rqliteUrl: url, shardSecrets: secrets, adminToken: admin, key: sealKey(sealText), replicaId: getEnv("HOSTNAME", "storage") & "-" & $getCurrentProcessId(),
                      repairEvery: parseInt(getEnv("CINIM_STORAGE_REPAIR_SECONDS", "60")), checkEvery: parseInt(getEnv("CINIM_STORAGE_CHECK_SECONDS", "600")))
  # the tables: the database may come up after the module does
  var c = newRq(url)
  var tries = 0
  while true:
    try:
      c.migrate()
      break
    except CatchableError as e:
      inc tries
      if tries > 60: fatal("rqlite does not answer: " & e.msg)
      sleep 2000
  let port = parseInt(getEnv("CINIM_STORAGE_PORT", "18090"))
  discard startServer(port, parseInt(getEnv("CINIM_STORAGE_THREADS", "16")))
  let shimPort = parseInt(getEnv("CINIM_STORAGE_SHIM_PORT", "18091"))       # D-61: the port for shims (0: none)
  if shimPort > 0: discard startShimServer(shimPort, parseInt(getEnv("CINIM_STORAGE_SHIM_THREADS", "8")))
  var repair: Thread[void]
  createThread(repair, repairLoop)
  echo "storage: serving shards ", toSeq(secrets.keys).join(","), " on port ", port
  proc onSignal(sig: cint) {.noconv.} = stopRepair.store(true)
  signal(SIGTERM, onSignal)
  signal(SIGINT, onSignal)
  while not stopRepair.load: sleep 100
  shutdown()
  joinThread(repair)

main()
