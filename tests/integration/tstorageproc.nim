## D-60 (docs/storage-module.md), end to end: the storage service as a process (blobgate, `BLOBGATE_BIN`), a mirror of two directories (rclone `local` nodes), the core's own client
## (`RemoteBackend`, core/storageclient.nim) with its signed calls, and the organisation's choice of store. An object goes core -> service -> both nodes with the shard in front of its key; another
## shard does not see it; a node that is away misses a write, and the service's repair pass gives it back; the service is killed and started again and holds nothing but what is in rqlite.
## Needs CINIM_RQLITE_URL and BLOBGATE_BIN (the test image has both; elsewhere the test is skipped).
import std/[unittest, json, os, osproc, strutils, strtabs, sequtils, times, net, httpclient]
import common/[rqlite, storagebackend]
import core/[schema, objectstore, storageclient]
import ../support/[freeport, storagebin]

const
  modulePort = 29880
  port1 = 29881
  port2 = 29882
  secret1 = "the-secret-of-shard-001-end-to-end"
  secret2 = "the-secret-of-shard-002-end-to-end"
  adminTok = "an-admin-token-for-the-end-to-end"
  nodeToken = "the-token-of-the-two-nodes"
requireFreePorts("tstorageproc", [modulePort, port1, port2])      # a port that something holds is another process: stop, do not talk to it (tests/support/freeport.nim)
let url = getEnv("CINIM_RQLITE_URL")

proc listening(port: int): bool =
  try:
    let s = newSocket()
    s.connect("127.0.0.1", Port(port), 200)
    s.close()
    true
  except OSError: false

proc stop(p: Process) =
  p.terminate()
  discard p.waitForExit(5000)
  p.close()

proc admin(meth: HttpMethod; path: string; body = ""): tuple[code: int, body: string] =
  let client = newHttpClient(timeout = 60000, headers = newHttpHeaders({"Authorization": "Bearer " & adminTok}))
  try:
    let r = client.request("http://127.0.0.1:" & $modulePort & path, httpMethod = meth, body = body)
    (r.code.int, r.body)
  finally: client.close()

suite "D-60 the storage module as a process":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  elif blobgateBin().len == 0:
    echo "  skipped: BLOBGATE_BIN is not set (the test image has it; elsewhere build github.com/zystem/blobgate and name the program)"
  else:
    let base = getTempDir() / ("tstorageproc-" & $getCurrentProcessId())
    removeDir(base)
    createDir(base)
    for port in [modulePort, port1, port2]:
      if listening(port): quit "something listens on " & $port & " already (a process of an earlier run?)"
    var c = newRq(url)
    for t in ["storage_stores", "storage_objects", "storage_repair", "storage_lease"]: discard c.execute(%*[["DROP TABLE IF EXISTS " & t]])
    migrate(c)

    proc startModule(): Process =
      let env = newStringTable()
      for k, v in envPairs(): env[k] = v
      env["CINIM_RQLITE_URL"] = url
      env["CINIM_STORAGE_PORT"] = $modulePort
      env["CINIM_STORAGE_SHARDS"] = "001=" & secret1 & ";002=" & secret2
      env["CINIM_STORAGE_ADMIN_TOKEN"] = adminTok
      env["CINIM_STORAGE_SEAL_KEY"] = "a-seal-key-for-the-end-to-end-test"
      env["CINIM_STORAGE_REPAIR_SECONDS"] = "1"
      env["CINIM_STORAGE_REPAIR_RETRY_SECONDS"] = "1"          # a repair tried while a node is still down is tried again in a second, not in half a minute: the test does not depend on which side of its restart the tick falls
      result = startProcess("/bin/sh", args = ["-c", "exec " & quoteShell(blobgateBin()) & " > " & base / "storage.log" & " 2>&1"], env = env)
      for _ in 0 ..< 100:
        if listening(modulePort): return
        sleep 100
      quit "the module did not start; see " & base / "storage.log"

    # a node is a directory (rclone `local`); a node that is away is a file where the directory was (a chmod does not keep root out, and the test image runs as root)
    proc nodeAway(root: string) =
      moveDir(root, root & ".away")
      writeFile(root, "")
    proc nodeBack(root: string) =
      if dirExists(root & ".away"):
        removeFile(root)
        moveDir(root & ".away", root)
    proc nodeHolds(root, name: string): bool =
      for f in walkDirRec(root):
        if name in f: return true

    var module = startModule()
    createDir(base / "n1")
    createDir(base / "n2")
    let nodes = $ %*[{"remote": ":local:" & base / "n1"}, {"remote": ":local:" & base / "n2"}]
    configureStorage("http://127.0.0.1:" & $modulePort, secret1, "001")

    test "D-60 no store yet: the core is told so, and a store is made with the admin token only":
      check moduleStores().ok and moduleStores().stores.len == 0
      check RemoteBackend(store: "").putObject("a/b", "x").retry == false
      check RemoteBackend(store: "").putObject("a/b", "x").ok == false
      check admin(HttpPut, "/v1/admin/stores/caddy-main", """{"kind":"mirror","nodes":""" & nodes & ""","min_acks":5}""").code == 400
      let made = admin(HttpPut, "/v1/admin/stores/caddy-main", """{"kind":"mirror","nodes":""" & nodes & """}""")
      check made.code == 200
      forgetStoreList()
      let list = moduleStores()
      check list.ok and list.stores.len == 1 and list.defaultName == "caddy-main" and list.stores[0].kind == "mirror"
      forgetStoreList()
      check admin(HttpPut, "/v1/admin/stores/caddy-degraded", """{"kind":"mirror","nodes":""" & nodes & ""","min_acks":1}""").code == 200

    test "D-60 an object goes through the module to both nodes, with the shard in front of its key, and comes back":
      let be = RemoteBackend(store: "caddy-main")
      check roundTrip(be) == ""
      check be.putObject("acme/s1_run/dist/app one.txt", "hello through the module").ok
      check be.objectSize("acme/s1_run/dist/app one.txt").size == 24
      check be.readRange("acme/s1_run/dist/app one.txt", 6, 7).data == "through"
      check nodeHolds(base / "n1", "app%20one.txt~") and nodeHolds(base / "n2", "app%20one.txt~")
      check RemoteBackend(store: "").objectSize("acme/s1_run/dist/app one.txt").size == 24          # "" is the default store
      # a multipart upload of two parts, the first of the size the nodes want
      var big = newString(partSize + 100)
      for i in 0 ..< big.len: big[i] = char(i * 13 mod 251)
      let up = be.createMultipart("acme/s1_run/big.bin")
      check up.res.ok
      let p1 = be.uploadPart("acme/s1_run/big.bin", up.uploadId, 1, big[0 ..< partSize])
      let p2 = be.uploadPart("acme/s1_run/big.bin", up.uploadId, 2, big[partSize .. ^1])
      check p1.res.ok and p2.res.ok
      check be.completeMultipart("acme/s1_run/big.bin", up.uploadId, @[(1, p1.etag), (2, p2.etag)]).ok
      check be.objectSize("acme/s1_run/big.bin").size == big.len
      check be.readRange("acme/s1_run/big.bin", partSize - 5, 10).data == big[partSize - 5 ..< partSize + 5]
      let aborted = be.createMultipart("acme/s1_run/never")
      check be.abortMultipart("acme/s1_run/never", aborted.uploadId).ok
      check be.deleteObject("acme/s1_run/big.bin").ok
      check not be.objectSize("acme/s1_run/big.bin").res.ok
      let inv = c.query(%*[["SELECT count(*) FROM storage_objects WHERE store = 'caddy-main'"]])["results"][0]{"values"}[0][0].getInt
      check inv == 1

    test "D-60 the module streams: several blocks at once, and its memory stays small (the peak is read from /proc)":
      let be = RemoteBackend(store: "caddy-main")
      var blocks = newSeq[string](6)
      for i in 0 ..< blocks.len:
        blocks[i] = newString(partSize)
        for j in 0 ..< blocks[i].len: blocks[i][j] = char((j * 31 + i * 7) mod 251)
      var threads = newSeq[Thread[(int, string)]](blocks.len)
      proc up(a: (int, string)) {.thread.} =
        {.cast(gcsafe).}:
          let b = RemoteBackend(store: "caddy-main")
          discard b.putObject("acme/s1_run/stream-" & $a[0], a[1])
      for i in 0 ..< blocks.len: createThread(threads[i], up, (i, blocks[i]))
      for t in threads.mitems: joinThread(t)
      for i in 0 ..< blocks.len:
        check be.objectSize("acme/s1_run/stream-" & $i).size == partSize
        check be.readRange("acme/s1_run/stream-" & $i, 1000, 5000).data == blocks[i][1000 ..< 6000]
        check be.readRange("acme/s1_run/stream-" & $i, 0, partSize).data == blocks[i]                          # a whole block, streamed by the module
        check be.deleteObject("acme/s1_run/stream-" & $i).ok
      var peak = 0
      for line in lines("/proc/" & $module.processID & "/status"):
        if line.startsWith("VmHWM:"): peak = parseInt(line.splitWhitespace()[1]) div 1024
      echo "  (the module's peak resident memory: ", peak, " MiB)"
      check peak > 0 and peak < 100                           # 16 threads with a 10 MiB buffer each, as before the streaming, were 170 MiB at rest; reads are streamed too

    test "D-60 another shard does not see the object, and a core with a wrong secret is refused":
      configureStorage("http://127.0.0.1:" & $modulePort, secret2, "002")
      let other = RemoteBackend(store: "caddy-main")
      let gone = other.objectSize("acme/s1_run/dist/app one.txt")
      check not gone.res.ok and "no such object" in gone.res.error
      check other.putObject("acme/s1_run/dist/app one.txt", "of shard two").ok
      check other.readRange("acme/s1_run/dist/app one.txt", 0, 100).data == "of shard two"
      configureStorage("http://127.0.0.1:" & $modulePort, secret1, "001")
      check RemoteBackend(store: "caddy-main").readRange("acme/s1_run/dist/app one.txt", 0, 100).data == "hello through the module"
      configureStorage("http://127.0.0.1:" & $modulePort, secret2, "001")                      # shard 001 with the secret of 002
      let refused = RemoteBackend(store: "caddy-main").objectSize("acme/s1_run/dist/app one.txt")
      check not refused.res.ok and not refused.res.retry and "401" in refused.res.error
      configureStorage("http://127.0.0.1:" & $modulePort, secret1, "001")
      check RemoteBackend(store: "nostore").objectSize("k").res.error == "no such store"

    test "D-60 the organisation's choice is checked against the module's stores and decides where its objects go":
      var core = newRq(url)
      core.migrate()
      let org = "org-" & $getCurrentProcessId()
      discard core.execute(%*[["DELETE FROM org_storage WHERE tenant_id = ?", org]])
      check core.storeFor(org, "artifacts") == "caddy-main"                                    # the module's default
      check core.setOrgStorage(org, "artifacts", "nostore", "test", 1).contains("no such store")
      check core.setOrgStorage(org, "nonsense", "caddy-main", "test", 1).contains("purpose")
      check core.setOrgStorage(org, "caches", "caddy-degraded", "test", 1) == ""
      check core.storeFor(org, "caches") == "caddy-degraded" and core.storeFor(org, "artifacts") == "caddy-main"
      check core.orgStorage(org) == @[("caches", "caddy-degraded")]
      check core.setOrgStorage(org, "caches", "", "test", 2) == ""
      check core.storeFor(org, "caches") == "caddy-main"
      let ss = newStoreSet()
      check ss.resolve("caddy-main").be != nil

    test "D-60 a write that a node missed is repaired by the module, and the module's restart loses nothing":
      let be = RemoteBackend(store: "caddy-degraded")                                          # min_acks 1: one node is enough
      nodeAway(base / "n2")
      check be.putObject("acme/s1_run/degraded.txt", "written while node two was away").ok
      check not nodeHolds(base / "n2", "degraded.txt~")
      nodeBack(base / "n2")
      var repaired = false
      for _ in 0 ..< 60:
        if nodeHolds(base / "n2", "degraded.txt~"):
          repaired = true
          break
        sleep 500
      check repaired
      # the module is killed and started again: stores, the default, the secrets and the inventory are in rqlite
      module.stop()
      module = startModule()
      check moduleStores().ok and moduleStores().stores.len == 2 and moduleStores().defaultName == "caddy-main"
      nodeAway(base / "n1")                                                                      # now only node two can answer
      check RemoteBackend(store: "caddy-degraded").readRange("acme/s1_run/degraded.txt", 0, 100).data == "written while node two was away"
      nodeBack(base / "n1")
      check admin(HttpGet, "/v1/admin/stores").body.contains("caddy-degraded")
      check "token" notin admin(HttpGet, "/v1/admin/stores").body.replace("access_key_id", "")

    nodeBack(base / "n1")
    nodeBack(base / "n2")
    module.stop()
    removeDir(base)
