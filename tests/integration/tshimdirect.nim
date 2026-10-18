## D-61, end to end: a shim's client (shim/logclient.nim `putFile`, `fetchTo`) against the core's real ArtifactIngest (ZeroMQ with CURVE, on a thread), the storage module as a process (build/storage)
## and two real Caddy nodes. The bytes of a file go from the client to the module and never to the core, and the core completes the upload because the digests the client reported over
## ZeroMQ are those the module made; there is no other way: a module that cannot be reached fails the upload, and a shard without the port for shims refuses it; a part changed on its way is refused. Needs CINIM_RQLITE_URL,
## build/caddy-store (made by tools/store/build-caddy.sh when Docker is there), tests/certs, and makes build/storage.
import std/[unittest, json, os, osproc, strutils, strtabs, times, net, httpclient, tables, sequtils, atomics]
import checksums/sha2
import common/[rqlite, ctrlauth, zmqcurve]
import core/[schema, loggate, logcircuit, objectstore, storageclient]
from core/scheduler import Core, createRun, stopServers, unenrolledControllers
from core/artifactingest import serveArtifactIngest
import shim/[logclient, artifacts, directclient]
import storage/storeauth

const
  modulePort = 29884
  shimPort = 29885
  port1 = 29886
  port2 = 29887
  ingestPort = 29890
  secret1 = "the-secret-of-shard-001-direct-test"
  adminTok = "an-admin-token-for-the-direct-test"
  nodeToken = "the-token-of-the-two-nodes-direct"
let url = getEnv("CINIM_RQLITE_URL")
unenrolledControllers = true

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

func shaOf(s: string): string =
  for c in secureHash(Sha_256, s): result.add toHex(ord(c), 2).toLowerAscii

proc admin(meth: HttpMethod; path: string; body = ""): int =
  let client = newHttpClient(timeout = 60000, headers = newHttpHeaders({"Authorization": "Bearer " & adminTok}))
  try: client.request("http://127.0.0.1:" & $modulePort & path, httpMethod = meth, body = body).code.int
  finally: client.close()

proc runIngest(a: tuple[url, certs: string, port: int]) {.thread.} = serveArtifactIngest(a.url, a.certs, a.port)

suite "D-61 the shim sends its bytes straight to the storage module":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  elif not fileExists("build/caddy-store") and execCmd("tools/store/build-caddy.sh") != 0:
    echo "  skipped: no build/caddy-store and it could not be made (it needs Docker and the network)"
  elif execCmd("nim c --hints:off --warnings:off -d:ssl -p:src --outdir:build -o:build/storage src/storage/main.nim") != 0:
    echo "  FAILED to build build/storage"
    check false
  else:
    let caddy = getCurrentDir() / "build" / "caddy-store"
    let certs = getCurrentDir() / "tests" / "certs"
    let base = getTempDir() / ("tshimdirect-" & $getCurrentProcessId())
    removeDir(base)
    createDir(base)
    for port in [modulePort, shimPort, port1, port2, ingestPort]:
      if listening(port): quit "something listens on " & $port & " already (a process of an earlier run?)"
    var c = newRq(url)
    for t in ["storage_stores", "storage_objects", "storage_repair", "storage_lease", "storage_parts"]: discard c.execute(%*[["DROP TABLE IF EXISTS " & t]])
    migrate(c)

    proc startModule(): Process =
      let env = newStringTable()
      for k, v in envPairs(): env[k] = v
      env["CINIM_RQLITE_URL"] = url
      env["CINIM_STORAGE_PORT"] = $modulePort
      env["CINIM_STORAGE_SHIM_PORT"] = $shimPort
      env["CINIM_STORAGE_SHARDS"] = "001=" & secret1
      env["CINIM_STORAGE_ADMIN_TOKEN"] = adminTok
      env["CINIM_STORAGE_SEAL_KEY"] = "a-seal-key-for-the-direct-test"
      result = startProcess("/bin/sh", args = ["-c", "exec " & getCurrentDir() / "build" / "storage" & " > " & base / "storage.log" & " 2>&1"], env = env)
      for _ in 0 ..< 100:
        if listening(modulePort) and listening(shimPort): return
        sleep 100
      quit "the module did not start; see " & base / "storage.log"
    proc startNode(root: string; port: int): Process =
      createDir(root)
      let file = base / ("Caddyfile-" & $port)
      writeFile(file, "{\n\torder webdav before file_server\n\tauto_https off\n\tadmin off\n}\n:" & $port & " {\n\tforward_auth 127.0.0.1:" & $modulePort & " {\n\t\turi " & authPath &
        "?node=127.0.0.1:" & $port & "\n\t}\n\twebdav {\n\t\troot " & root & "\n\t\tatomic_put\n\t\tcreate_dirs\n\t}\n}\n")
      let env = newStringTable()
      for k, v in envPairs(): env[k] = v
      env["XDG_DATA_HOME"] = base / "xdg"
      env["XDG_CONFIG_HOME"] = base / "xdgc"
      result = startProcess("/bin/sh", args = ["-c", "exec " & caddy & " run --config " & file & " --adapter caddyfile > " & base / ("caddy-" & $port & ".log") & " 2>&1"], env = env)
      for _ in 0 ..< 100:
        if listening(port): return
        sleep 100
      quit "the node on " & $port & " did not start"

    let module = startModule()
    let n1 = startNode(base / "n1", port1)
    let n2 = startNode(base / "n2", port2)
    let nodes = $ %*["http://127.0.0.1:" & $port1, "http://127.0.0.1:" & $port2]
    check admin(HttpPut, "/v1/admin/stores/caddy-main", """{"kind":"dav","nodes":""" & nodes & ""","token":"""" & nodeToken & """"}""") == 200

    # the core's side: rows for a run with a step that declared artifacts and a cache, the choice of store, the module's address
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let org = c.addOrganization("sd-" & sfx, "SD")
    let ns = "cinim-001-sd-" & sfx
    let prof = c.ensureOrganizationProfile(org, ns)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let master = coreSecretKey(certs)
    let runId = co.createRun("return 1", org, prof)
    let jobId = newId()
    discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, 'job-1', 'RUNNING', ?)", jobId, runId, prof]])
    discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at, attempt, claimed_at) " &
      "VALUES (?, ?, ?, 0, 'sh', 'RUNNING', ?, 'alpine', 'true', ?, '1', 1, ?)", newId(), runId, jobId, prof,
      """{"artifacts":{"upload":["dist/**","big/**","bad/**"],"download":["dist","big"]},"cache":[{"key":"deps-1","paths":["node_modules"]}]}""", getTime().toUnix()]])
    discard c.execute(%*[["INSERT OR REPLACE INTO org_storage (tenant_id, purpose, store_name, updated_by, updated_at) VALUES (?, 'artifacts', 'caddy-main', 'test', 1)", org]])
    discard c.execute(%*[["INSERT OR REPLACE INTO org_storage (tenant_id, purpose, store_name, updated_by, updated_at) VALUES (?, 'caches', 'caddy-main', 'test', 1)", org]])
    configureStorage("http://127.0.0.1:" & $modulePort, secret1, "001", "http://127.0.0.1:" & $shimPort)
    forgetStoreList()
    var ingest: Thread[tuple[url, certs: string, port: int]]
    stopServers.store(false)
    createThread(ingest, runIngest, (url, certs, ingestPort))
    sleep 500

    let step = StepRef(run_id: runId, seq: 0, attempt: 1)
    let token = stepToken(master, runId, 0, 1)
    let work = base / "work"
    createDir(work)
    proc blob(n: int; seed: int): string =
      result = newString(n)
      for i in 0 ..< n: result[i] = char((i * 31 + seed * 7 + i div 251) mod 256)
    proc client(): ArtifactClient = newArtifactClient("tcp://127.0.0.1:" & $ingestPort, certs)
    proc put(path, data: string; cache = false; patience = 30): ArtifactReply =
      let f = work / path.replace('/', '_')
      writeFile(f, data)
      let cl = client()
      defer: cl.close()
      cl.putFile(step, token, path, f, int64(data.len), shaOf(data), patience, cache)
    proc fetch(path: string; size: int): tuple[err, sha: string] =
      let cl = client()
      defer: cl.close()
      let list = ask(cl, step, token, ArtifactRequest(op: "get_list", names: @[path.split('/')[0]], direct: true), 30)
      for f in list.ack.files:
        if f.path == path:
          let dest = work / ("got_" & path.replace('/', '_'))
          let err = cl.fetchTo(step, token, f.path, f.size, dest, 30, directUrl = list.ack.direct_url, grant = f.grant, directPath = f.direct_path)
          return (err, (if err.len == 0: fileSha256(dest) else: ""))
      ("not listed", "")

    test "D-61 a file of three parts goes straight to the module, the core completes it by the digests, and it is read back straight from the module":
      let data = blob(2 * artifacts.partSize + 12345, 1)
      let r = put("big/a.bin", data)
      check r.ok and r.viaDirect
      check c.query(%*[["SELECT count(*) FROM artifacts WHERE run_id = ? AND path = 'big/a.bin' AND state = 'stored'", runId]])["results"][0]{"values"}[0][0].getInt == 1
      for root in ["n1", "n2"]:
        check dirExists(base / root / "001" / org / runId / "big" / "a.bin~obj")
      let got = fetch("big/a.bin", data.len)
      check got.err == "" and got.sha == shaOf(data)
    test "D-61 a small file and a cache entry go the same way":
      let small = blob(1500, 2)
      check put("dist/small.txt", small).viaDirect
      check fetch("dist/small.txt", small.len) == ("", shaOf(small))
      let entry = blob(artifacts.partSize + 77, 3)
      let r = put("deps-1", entry, cache = true)
      check r.ok and r.viaDirect
      let cl = client()
      let f = cacheFind(cl, step, token, "deps-1", 30)
      check f.found and f.sha256 == shaOf(entry) and f.grant.len > 0
      check cacheFetch(cl, step, token, f.key, f.size, work / "got_cache", 30, f.directUrl, f.grant, f.directPath) == ""
      check fileSha256(work / "got_cache") == shaOf(entry)
      cl.close()
    test "D-61 a part changed on its way is refused by the module, a digest the shim reports falsely by the core, and nothing is stored":
      let cl = client()
      defer: cl.close()
      let data = blob(3000, 4)
      let began = ask(cl, step, token, ArtifactRequest(op: "put_begin", path: "bad/x.bin", size: uint64(data.len), sha256: shaOf(data), direct: true), 30)
      check began.ok and began.ack.grant.len > 0
      let d = newDirectClient(began.ack.direct_url)
      # the bytes are not the ones whose digest was sent: the module's own check
      let wrong = d.putPart(began.ack.direct_path, began.ack.grant, began.ack.upload_id, 1, data, shaOf("another"), 5)
      check not wrong.ok and "sha256_mismatch" in wrong.detail
      # the right part, and a shim that reports another digest at the end
      let ok = d.putPart(began.ack.direct_path, began.ack.grant, began.ack.upload_id, 1, data, shaOf(data), 5)
      check ok.ok
      let end1 = ask(cl, step, token, ArtifactRequest(op: "put_end", path: "bad/x.bin", upload_id: began.ack.upload_id, parts: @[ArtifactPart(part: 1, etag: ok.etag, sha256: shaOf("changed"))]), 30)
      check not end1.ok and end1.code == "digest_mismatch"
      check c.query(%*[["SELECT count(*) FROM artifacts WHERE run_id = ? AND path = 'bad/x.bin'", runId]])["results"][0]{"values"}[0][0].getInt == 0
      # a grant for another key opens nothing
      let other = d.putPart("/s/caddy-main/" & "elsewhere%2Fx.bin", began.ack.grant, began.ack.upload_id, 1, data, shaOf(data), 5)
      check not other.ok and other.code in [401, 403, 404]
    test "D-61 there is no other way: a module that cannot be reached from the Pod fails the upload after the patience, a shard without the port for shims refuses it, and the bytes never come to the core":
      let a = blob(70_000, 5)
      let stored = put("dist/there.bin", a)
      check stored.ok and stored.viaDirect
      configureStorage("http://127.0.0.1:" & $modulePort, secret1, "001", "http://127.0.0.1:1")        # nothing listens there
      let t0 = epochTime()
      let r = put("dist/fallback.bin", a, patience = 4)
      check not r.ok and r.retry
      check epochTime() - t0 >= 3.0                                                                      # it waited for the module, as for a core that is away, and then gave up
      check c.query(%*[["SELECT count(*) FROM artifacts WHERE run_id = ? AND path = 'dist/fallback.bin' AND state = 'stored'", runId]])["results"][0]{"values"}[0][0].getInt == 0
      let got = fetch("dist/there.bin", a.len)                                                           # the read is offered a grant too, and fails the same way
      check got.err.len > 0
      configureStorage("http://127.0.0.1:" & $modulePort, secret1, "001", "")                              # the shard has no port for shims
      let r2 = put("big/b.bin", blob(2 * artifacts.partSize + 5, 6))
      check not r2.ok and r2.code == "direct_required"
      let r3 = put("dist/empty.txt", "")                                                                   # a file of no bytes needs none to be sent
      check r3.ok and not r3.viaDirect
      check fetch("dist/there.bin", a.len).err.len > 0
      configureStorage("http://127.0.0.1:" & $modulePort, secret1, "001", "http://127.0.0.1:" & $shimPort)
      check fetch("dist/there.bin", a.len) == ("", shaOf(a))
      check fetch("dist/empty.txt", 0) == ("", shaOf(""))                                                 # a file of no bytes is read with no bytes asked of the module
      # the sweep deletes the object of every artifact; there is none for a file of no bytes, and the module takes the delete of what it never had
      check newStoreSet().resolve("caddy-main").be.deleteObject(objectKey(org, runId, "dist/empty.txt")).ok

    stopServers.store(true)
    joinThread(ingest)
    n1.stop()
    n2.stop()
    module.stop()
    removeDir(base)
