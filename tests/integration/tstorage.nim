## D-60 (docs/storage-module.md, phase 2): the storage module as a service, without a socket (`dispatch`), over a real rqlite and stores that are test doubles in memory. The calls of the core are
## signed per request for a shard and a target; the shard is put in front of every key and the tokens of one shard are no good for another; the stores are the operator's (the admin token), their
## secrets are sealed in the database; the inventory follows every put, completed upload and delete; the repair copies what a node missed, from the inventory, and only one replica holds the lease.
## Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, tables, locks, times, uri, sequtils]
import checksums/sha2
import common/[rqlite, storagebackend]
import storage/[schema, seal, registry, repair, replicas, service, storeauth, httpstore]

let url = getEnv("CINIM_RQLITE_URL")

# ------------------------------------------------------------------ doubles
var memLock: Lock
initLock(memLock)
var memObjects: Table[string, string]                         # "<store>|<key>" -> data
var memUploads: Table[string, tuple[key: string, parts: Table[int, string]]]
var nodeObjects: array[2, Table[string, string]]              # the two nodes of the mirror double: "<store>|<key>"
var nodeDown: array[2, bool]
var missedLog: seq[(string, string, string)]
var nextUpload = 0

type
  MemStore = ref object of ObjectBackend
    store: string
  MemMirror = ref object of ReplicaBackend
    store: string
    onMissed: MissedProc

func slot(store, key: string): string = store & "|" & key

method putObject(b: MemStore; key, data: string): Outcome =
  withLock memLock: memObjects[slot(b.store, key)] = data
  done()
method createMultipart(b: MemStore; key: string): tuple[res: Outcome, uploadId: string] =
  withLock memLock:
    inc nextUpload
    let id = "up" & $nextUpload
    memUploads[id] = (key, initTable[int, string]())
    return (done(), id)
method uploadPart(b: MemStore; key, uploadId: string; part: int; data: string): tuple[res: Outcome, etag: string] =
  withLock memLock:
    if uploadId notin memUploads: return (fail("no such upload"), "")
    memUploads[uploadId].parts[part] = data
  (done(), "etag" & $part)
method completeMultipart(b: MemStore; key, uploadId: string; parts: seq[(int, string)]): Outcome =
  withLock memLock:
    if uploadId notin memUploads: return fail("no such upload")
    var all = ""
    for (n, _) in parts: all.add memUploads[uploadId].parts[n]
    memObjects[slot(b.store, key)] = all
    memUploads.del uploadId
  done()
method abortMultipart(b: MemStore; key, uploadId: string): Outcome =
  withLock memLock: memUploads.del uploadId
  done()
method readRange(b: MemStore; key: string; offset, length: int64): tuple[res: Outcome, data: string] =
  withLock memLock:
    let k = slot(b.store, key)
    if k notin memObjects: return (fail("no such object"), "")
    return (done(), memObjects[k][int(offset) ..< int(min(offset + length, memObjects[k].len))])
method objectSize(b: MemStore; key: string): tuple[res: Outcome, size: int64] =
  withLock memLock:
    let k = slot(b.store, key)
    if k notin memObjects: return (fail("no such object"), -1'i64)
    return (done(), int64(memObjects[k].len))
method deleteObject(b: MemStore; key: string): Outcome =
  withLock memLock:
    let k = slot(b.store, key)
    if k notin memObjects: return fail("no such object")
    memObjects.del k
  done()

method nodeNames(b: MemMirror): seq[string] = @["n0", "n1"]
method putObject(b: MemMirror; key, data: string): Outcome =
  withLock memLock:
    for i in 0 .. 1:
      if nodeDown[i]: missedLog.add (key, "n" & $i, "copy")
      else: nodeObjects[i][slot(b.store, key)] = data
  for i in 0 .. 1:
    if nodeDown[i] and b.onMissed != nil: b.onMissed(key, "n" & $i, "copy")
  done()
method createMultipart(b: MemMirror; key: string): tuple[res: Outcome, uploadId: string] = (done(), "mirror-up")
method abortMultipart(b: MemMirror; key, uploadId: string): Outcome = done()
method readRange(b: MemMirror; key: string; offset, length: int64): tuple[res: Outcome, data: string] =
  withLock memLock:
    for i in 0 .. 1:
      let k = slot(b.store, key)
      if not nodeDown[i] and k in nodeObjects[i]: return (done(), nodeObjects[i][k][int(offset) ..< int(min(offset + length, nodeObjects[i][k].len))])
  (fail("no such object"), "")
method objectSize(b: MemMirror; key: string): tuple[res: Outcome, size: int64] =
  withLock memLock:
    for i in 0 .. 1:
      let k = slot(b.store, key)
      if not nodeDown[i] and k in nodeObjects[i]: return (done(), int64(nodeObjects[i][k].len))
  (fail("no such object"), -1'i64)
method deleteObject(b: MemMirror; key: string): Outcome =
  withLock memLock:
    for i in 0 .. 1: nodeObjects[i].del slot(b.store, key)
  done()
method sizeOn(b: MemMirror; node: int; key: string): Probe =
  withLock memLock:
    let k = slot(b.store, key)
    if nodeDown[node]: return Probe(retry: true, error: "node is away")
    if k in nodeObjects[node]: return Probe(ok: true, size: int64(nodeObjects[node][k].len))
  Probe(notFound: true, error: "no such object")
method deleteOn(b: MemMirror; node: int; key: string): Outcome =
  withLock memLock: nodeObjects[node].del slot(b.store, key)
  done()
method copyBetween(b: MemMirror; src, dst: int; key: string): Outcome =
  withLock memLock:
    let k = slot(b.store, key)
    if nodeDown[dst]: return fail("node is away", retry = true)
    if k notin nodeObjects[src]: return fail("no such object")
    nodeObjects[dst][k] = nodeObjects[src][k]
  done()

proc makeDouble(l: Loaded; onMissed: MissedProc): ObjectBackend {.gcsafe, nimcall.} =
  if l.cfg.kind == "dav": MemMirror(store: l.name, onMissed: onMissed) else: MemStore(store: l.name)

# ------------------------------------------------------------------ helpers
func shaOf(s: string): string =
  for c in secureHash(Sha_256, s): result.add toHex(ord(c), 2).toLowerAscii

const
  secret1 = "the-secret-of-shard-001-for-the-tests"
  secret2 = "the-secret-of-shard-002-for-the-tests"
  adminTok = "an-admin-token-for-the-tests"

proc target(uri: string): string =
  let q = uri.find('?')
  decodeUrl(if q >= 0: uri[0 ..< q] else: uri, decodePlus = false) & (if q >= 0: uri[q ..< uri.len] else: "")

proc raw(meth, uri: string; headers: seq[(string, string)]): string =
  result = meth & " " & uri & " HTTP/1.1\r\nHost: storage\r\n"
  for (k, v) in headers: result.add k & ": " & v & "\r\n"
  result.add "\r\n"

proc coreCall(meth, uri: string; body = ""; shard = "001"; secret = secret1; extra: seq[(string, string)] = @[]; signedAt = 0'i64): Reply =
  let now = getTime().toUnix()
  let token = signTarget(secret, shard, meth, target(uri), if signedAt > 0: signedAt else: now)
  var more = extra                                   # a PUT of an object or a part names the digest of its body (the module streams it and the stores check it)
  if meth == "PUT" and body.len > 0 and extra.allIt(it[0].toLowerAscii != "x-content-sha256"): more.add ("X-Content-SHA256", shaOf(body))
  dispatch(meth, uri, raw(meth, uri, @[("Authorization", "Bearer " & token), ("X-Cinim-Shard", shard)] & more), body, now)

proc adminCall(meth, uri: string; body = ""; token = adminTok): Reply =
  dispatch(meth, uri, raw(meth, uri, @[("Authorization", "Bearer " & token)]), body, getTime().toUnix())

proc objUri(store, key: string; query = ""): string =
  "/v1/stores/" & store & "/objects/" & encodePath(key) & (if query.len > 0: "?" & query else: "")

proc js(r: Reply): JsonNode = parseJson(r.body)

suite "D-60 the storage module's API":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    for t in ["storage_stores", "storage_objects", "storage_repair", "storage_lease"]: discard c.execute(%*[["DELETE FROM " & t]])
    cfg = ServiceConfig(rqliteUrl: url, shardSecrets: {"001": secret1, "002": secret2}.toTable, adminToken: adminTok, key: sealKey("a-seal-key-for-the-storage-tests"), replicaId: "r1", makeBackend: makeDouble)
    let garage = "garage-main"
    let caddy = "caddy-main"

    test "D-60 the operator makes stores with the admin token; the first is the default; the secret is sealed in the database":
      check adminCall("GET", "/v1/admin/stores", token = "wrong-token-of-enough-length").code == 401
      check adminCall("GET", "/v1/admin/stores").js["stores"].len == 0
      let r = adminCall("PUT", "/v1/admin/stores/" & garage, $ %*{"endpoint": "http://garage.test:3900", "region": "garage", "bucket": "cinim-artifacts", "access_key_id": "GKabc", "secret_access_key": "s3cret-of-garage"})
      check r.code == 200
      let r2 = adminCall("PUT", "/v1/admin/stores/" & caddy, $ %*{"kind": "dav", "nodes": ["http://c0.test:8080", "http://c1.test:8080"], "token": "token-of-the-nodes"})
      check r2.code == 200
      let list = adminCall("GET", "/v1/admin/stores").js["stores"]
      check list.len == 2 and list[0]["name"].getStr == caddy and list[1]["default"].getBool and not list[0]["default"].getBool
      check "s3cret-of-garage" notin $list and "token-of-the-nodes" notin $list
      let row = c.query(%*[["SELECT secret FROM storage_stores WHERE name = ?", garage]])["results"][0]{"values"}[0][0].getStr
      check row.startsWith("v1.") and "s3cret" notin row
      # a sealed value copied to another store's row does not open
      check not unseal(cfg.key, caddy, row).ok and unseal(cfg.key, garage, row).plain == "s3cret-of-garage"
      check adminCall("PUT", "/v1/admin/stores/Bad_Name", "{}").code == 400
      check adminCall("POST", "/v1/admin/stores/via-post", $ %*{"endpoint": "http://garage.test:3900", "region": "garage", "bucket": "cinim-artifacts", "access_key_id": "GKabc", "secret_access_key": "x"}).code == 200      # for a script that cannot PUT
      check adminCall("DELETE", "/v1/admin/stores/via-post").code == 200
      check adminCall("PUT", "/v1/admin/stores/x1", $ %*{"endpoint": "ftp://nowhere", "bucket": "cinim", "access_key_id": "k", "secret_access_key": "s"}).code == 400

    test "D-60 a store saved without being marked becomes the default when there is none (a registration cut off after its row)":
      let key = sealKey("a-seal-key-for-the-storage-tests")
      var c2 = newRq(url)
      check c2.defaultStoreName() == garage
      discard c2.execute(%*[["UPDATE storage_stores SET is_default = 0"]])
      check c2.defaultStoreName() == ""
      check c2.saveStore(key, garage, StoreConfig(kind: "s3", endpoint: "http://garage.test:3900", region: "garage", bucket: "cinim-artifacts", keyId: "GKabc"), "s3cret-of-garage", false, 1) == ""
      check c2.defaultStoreName() == garage

    test "D-60 a call of the core needs a token made for its shard, method and target":
      check coreCall("GET", "/v1/stores").code == 200
      let list = coreCall("GET", "/v1/stores").js
      check list["default"].getStr == garage and list["stores"].len == 2 and "secret" notin $list
      let u = objUri(garage, "r1/a.txt")
      check dispatch("GET", "/v1/stores", raw("GET", "/v1/stores", @[("X-Cinim-Shard", "001")]), "", getTime().toUnix()).code == 401        # no token
      check coreCall("GET", "/v1/stores", secret = secret2).code == 401                                                                   # another shard's secret
      check coreCall("GET", "/v1/stores", shard = "003", secret = secret1).code == 401                                                    # a shard the module does not serve
      let at = getTime().toUnix()
      let tok = signTarget(secret1, "001", "GET", target(u & "?stat"), at)
      check dispatch("GET", u, raw("GET", u, @[("Authorization", "Bearer " & tok), ("X-Cinim-Shard", "001")]), "", at).code == 401        # token for another target (the query differs)
      let tok2 = signTarget(secret1, "001", "GET", "/v1/stores", at)
      check dispatch("GET", "/v1/stores", raw("GET", "/v1/stores", @[("Authorization", "Bearer " & tok2), ("X-Cinim-Shard", "002")]), "", at).code == 401   # the header names another shard
      check coreCall("GET", "/v1/stores", signedAt = getTime().toUnix() - 400).code == 401                                                      # expired

    test "D-60 an object is put, sized, read by range and deleted; the shard is in front of its key; the inventory follows":
      let u = objUri(garage, "acme/s1_run/dist/app one.txt")
      let body = "hello, storage module"
      let put = coreCall("PUT", u, body, extra = @[("X-Content-SHA256", shaOf(body))])
      check put.code == 200 and put.js["size"].getInt == body.len
      check memObjects.hasKey(slot(garage, "001/acme/s1_run/dist/app one.txt"))
      check c.query(%*[["SELECT size FROM storage_objects WHERE store = ? AND key = ?", garage, "001/acme/s1_run/dist/app one.txt"]])["results"][0]{"values"}[0][0].getInt == body.len
      check coreCall("GET", u & "?stat").js["size"].getInt == body.len
      let part = coreCall("GET", u, extra = @[("Range", "bytes=7-13")])
      check part.code == 206 and part.body == "storage"
      check coreCall("GET", u).code == 400                                                       # a read names a range
      check coreCall("PUT", u, body, extra = @[("X-Content-SHA256", shaOf("another"))]).code == 400
      check not memObjects.hasKey(slot(garage, "001/acme/s1_run/dist/app one.txt"))      # a body that is not the one named is taken back (a store that checks nothing had already kept it)
      check coreCall("PUT", u, body).code == 200
      # another shard does not see it, whatever the key
      check coreCall("GET", u & "?stat", shard = "002", secret = secret2).code == 404
      check coreCall("PUT", u, "of shard two", shard = "002", secret = secret2).code == 200
      check memObjects[slot(garage, "002/acme/s1_run/dist/app one.txt")] == "of shard two"
      check coreCall("GET", u, extra = @[("Range", "bytes=0-4")]).body == "hello"
      check coreCall("DELETE", u).code == 200
      check coreCall("GET", u & "?stat").code == 404
      check c.query(%*[["SELECT count(*) FROM storage_objects WHERE store = ? AND key = ?", garage, "001/acme/s1_run/dist/app one.txt"]])["results"][0]{"values"}[0][0].getInt == 0
      check coreCall("DELETE", u).code == 200                                                    # deleting what is not there is fine
      discard coreCall("DELETE", u, shard = "002", secret = secret2)

    test "D-60 a PUT is a stream: it needs the digest first, takes a body in small pieces, and a sender that breaks off leaves nothing":
      let u = objUri(garage, "acme/s1_run/streamed.bin")
      let body = "0123456789abcdefghij".repeat(1000)
      let at = getTime().toUnix()
      proc put(src: BodySource; len: int; withSha = true; sha = ""): Reply =
        let tok = signTarget(secret1, "001", "PUT", target(u), at)
        var h = @[("Authorization", "Bearer " & tok), ("X-Cinim-Shard", "001")]
        if withSha: h.add ("X-Content-SHA256", (if sha.len > 0: sha else: shaOf(body)))
        dispatch("PUT", u, raw("PUT", u, h), src, int64(len), at)
      check put(bodyOf(body), body.len, withSha = false).code == 400                       # no digest: refused before a byte is read
      check put(bodyOf(body, piece = 7), body.len).code == 200                              # seven bytes at a time
      check memObjects[slot(garage, "001/acme/s1_run/streamed.bin")] == body
      check put(bodyOf(body, piece = 4096), body.len, sha = shaOf("not it")).code == 400
      check not memObjects.hasKey(slot(garage, "001/acme/s1_run/streamed.bin"))               # the store was told to forget what did not match
      let broken: BodySource = proc (sink: proc (chunk: string): bool {.closure.}): bool {.closure.} =
        discard sink(body[0 ..< 100])
        false
      check put(broken, body.len).code == 503                                                # the sender broke off: try again
      check put(bodyOf(body), 9 * 1024 * 1024).code == 413
      check coreCall("DELETE", u).code == 200

    test "D-60 keys that are not keys, a store that is not there, the default by `_default`":
      check coreCall("PUT", "/v1/stores/" & garage & "/objects/a/../b", "x").code == 400
      check coreCall("PUT", "/v1/stores/" & garage & "/objects/a//b", "x").code == 400
      check coreCall("PUT", objUri("nostore", "k"), "x").code == 404
      check coreCall("PUT", objUri("_default", "d/k"), "to the default").code == 200
      check memObjects.hasKey(slot(garage, "001/d/k"))
      check coreCall("DELETE", objUri("_default", "d/k")).code == 200

    test "D-60 a multipart upload: parts, complete (the size is recorded), abort":
      let u = objUri(garage, "acme/s1_run/big.bin")
      let id = coreCall("POST", u & "?uploads").js["upload_id"].getStr
      check id.len > 0
      let e1 = coreCall("PUT", u & "?upload=" & id & "&part=1", "aaaa").js["etag"].getStr
      let e2 = coreCall("PUT", u & "?upload=" & id & "&part=2", "bbbbbb").js["etag"].getStr
      check coreCall("PUT", u & "?upload=" & id & "&part=0", "x").code == 400
      let done = coreCall("POST", u & "?upload=" & id, $ %*{"parts": [[1, e1], [2, e2]]})
      check done.code == 200 and done.js["size"].getInt == 10
      check memObjects[slot(garage, "001/acme/s1_run/big.bin")] == "aaaabbbbbb"
      check c.query(%*[["SELECT size FROM storage_objects WHERE store = ? AND key = ?", garage, "001/acme/s1_run/big.bin"]])["results"][0]{"values"}[0][0].getInt == 10
      let id2 = coreCall("POST", u & "-2?uploads").js["upload_id"].getStr
      check coreCall("DELETE", u & "-2?upload=" & id2).code == 200
      check coreCall("POST", u & "?upload=" & id, "not json").code == 400
      check coreCall("DELETE", u).code == 200

    test "D-60 a mirror: a write a node missed goes to the repair queue, the pass copies it from the inventory, the check finds a lost node":
      let u = objUri(caddy, "acme/s1_run/m.txt")
      nodeDown[1] = true
      check coreCall("PUT", u, "mirrored").code == 200
      nodeDown[1] = false
      check c.pendingRepairs(caddy) == 1
      let l = c.loadStore(cfg.key, caddy)
      let mir = ReplicaBackend(makeDouble(l, nil))
      let rep = c.repairPass(caddy, mir, getTime().toUnix())
      check rep.copied == 1 and c.pendingRepairs(caddy) == 0
      check nodeObjects[1][slot(caddy, "001/acme/s1_run/m.txt")] == "mirrored"
      # a node that lost its disk: the check queues the copy, the pass restores it
      withLock memLock: nodeObjects[1].clear()
      var cursor = ""
      check c.checkNodes(caddy, mir, cursor, getTime().toUnix()) == 1
      check c.repairPass(caddy, mir, getTime().toUnix()).copied == 1
      check nodeObjects[1].len == 1
      # a delete that left the queue stale: the copy of an object that is gone is dropped
      c.noteMissed(caddy, "001/acme/gone", "n1", "copy", getTime().toUnix())
      check c.repairPass(caddy, mir, getTime().toUnix()).dropped == 1
      check coreCall("DELETE", u).code == 200

    test "D-60 a store in use is not forgotten without force; the default is not forgotten while another is there":
      check coreCall("PUT", objUri(garage, "keep/me"), "x").code == 200
      check adminCall("DELETE", "/v1/admin/stores/" & garage).code == 409
      check adminCall("POST", "/v1/admin/stores/" & caddy & ":default").code == 200
      check coreCall("GET", "/v1/stores").js["default"].getStr == caddy
      check adminCall("DELETE", "/v1/admin/stores/" & caddy).code == 409                                 # the default
      check adminCall("POST", "/v1/admin/stores/" & garage & ":check").code == 200
      check adminCall("DELETE", "/v1/admin/stores/" & garage & "?force=1").code == 200
      check c.query(%*[["SELECT count(*) FROM storage_objects WHERE store = ?", garage]])["results"][0]{"values"}[0][0].getInt == 0
      check coreCall("GET", objUri(garage, "keep/me") & "&stat".replace("&", "?")).code == 404         # the module forgot the store
      check adminCall("DELETE", "/v1/admin/stores/" & caddy).code == 200
      check coreCall("PUT", objUri("_default", "k"), "x").code == 409                                    # no store at all

    test "D-60 one replica holds the lease at a time and takes it over when the hold ends":
      discard c.execute(%*[["DELETE FROM storage_lease"]])
      let t = getTime().toUnix()
      check c.tryLease("repair", "a", t)
      check not c.tryLease("repair", "b", t + 10)
      check c.tryLease("repair", "a", t + 60)                    # renewed
      check not c.tryLease("repair", "b", t + 60 + leaseSeconds - 1)
      check c.tryLease("repair", "b", t + 60 + leaseSeconds + 1)  # a stopped renewing
      check not c.tryLease("repair", "a", t + 60 + leaseSeconds + 2)

    test "D-60 the node's forward_auth is answered with the tokens of the dav stores":
      check adminCall("PUT", "/v1/admin/stores/" & caddy, $ %*{"kind": "dav", "nodes": ["http://c0.test:8080"], "token": "token-of-the-nodes"}).code == 200
      let now = getTime().toUnix()
      let tok = signRequest("token-of-the-nodes", "c0.test:8080", "GET", "/x/y", now)
      let uri = "/v1/internal/node-auth?node=c0.test:8080"
      let good = raw("GET", uri, @[("Authorization", "Bearer " & tok), ("X-Forwarded-Method", "GET"), ("X-Forwarded-Uri", "/x/y")])
      check dispatch("GET", uri, good, "", now).code == 200
      let other = raw("GET", uri, @[("Authorization", "Bearer " & tok), ("X-Forwarded-Method", "GET"), ("X-Forwarded-Uri", "/x/z")])
      check dispatch("GET", uri, other, "", now).code == 401
