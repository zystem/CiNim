## ArtifactIngest (DAT-003): the REP server where the artifacts of steps arrive and from which they are read, the same way as the log of a step reaches the
## core: a ZeroMQ channel with CURVE, requests in blocks, each one answered (proto/cicd/internal/v1/step.proto). The core alone knows the store; what it asks of
## it is `ObjectBackend` (core/storagebackend.nim), so the module that talks to the store can leave the core without a step or a shim noticing.
##
## A step may only do what its own options declared (`artifacts = {upload = {...}, download = {...}}`), in its own run, and only while its attempt is running,
## with its own credential (the same HMAC as for its secrets). The sender is the shim, or the job controller on its behalf when it drains the Pod through
## `exec` after the shim could not reach the core (the spool fallback of D-33): the requests are the same, the token is the one core gave in StartStep.
##
## The bytes never come to the core (D-61): a file is put to the storage module by the shim itself, `put_begin` answers with the store's upload id, a grant and the path, the shim puts
## the parts to the module's port for shims and `put_end` lists them with their digests, which the core compares with what the module received before it completes the upload. A file of
## no bytes is one request, `put_object`, without data. Nothing is kept in the core between the requests but the row of the artifact (state `uploading`, the upload id), so a core that restarts
## in the middle loses nothing; the shim sends the part again. An artifact is `stored` only when the store itself says that the object is there with the size announced. A shard without the
## module's port for shims (`storage.directUrl`) stores no artifact and no cache: the request is refused (`direct_required`).
import std/[json, strutils, times, tables, sequtils, atomics]
import protobuf_serialization
import protobuf_serialization/files/type_generator
import crunchy
import ../common/[zmqcurve, rqlite, states, ctrlauth]
import schema, objectstore, scheduler, drains, cachestore

import_proto3 "../../build/nimproto/all.proto"

func hexOf(a: openArray[uint8]): string =
  const digits = "0123456789abcdef"
  for b in a:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

func toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

func coveredBy*(names: seq[string]; path: string): bool =
  ## a path the step may read: one of its download names, or something under one that is a directory
  for n in names:
    if path == n or path.startsWith(n & "/"): return true

proc ack(ok = true): ArtifactAck = ArtifactAck(header: Header(protocol: 1), accepted: ok)

proc refuse(code, detail: string): ArtifactAck =
  ArtifactAck(header: Header(protocol: 1), accepted: false, failure: Failure(code: code, detail: detail))

proc fromOutcome(o: Outcome): ArtifactAck =
  refuse(if o.retry: "store_unavailable" else: "store_error", o.error)

proc backendFor(ss: StoreSet; name: string): tuple[be: ObjectBackend, refusal: ArtifactAck] =
  ## the backend of the store `name` (D-59), or the answer that refuses the request because it cannot be had
  let rb = ss.resolve(name)
  if rb.be != nil: return (rb.be, ArtifactAck())
  case rb.error
  of "not_configured": (nil, refuse("store_not_configured", "the shard has no storage module (CINIM_STORAGE_URL, docs/storage-module.md)"))
  of "no_such_store": (nil, refuse("store_not_configured", "the store " & name & " is not there any more"))
  else: (nil, refuse("store_unavailable", "the object store's key cannot be read now: " & rb.error))


# ------------------------------------------------------------------ the direct transfer of a shim (D-61, docs/storage-module.md)

proc offerDirect(a: var ArtifactAck; store, key, upload: string) =
  ## a grant for this upload and the path to put the parts to
  let g = grantFor(store, key, upload, "w")
  if g.len == 0: return
  a.grant = g
  a.direct_url = directUrl()
  a.direct_path = directPath(store, key)

proc offerRead(f: var ArtifactFile; store, key: string) =
  let g = grantFor(store, key, "", "r")
  if g.len == 0: return
  f.grant = g
  f.direct_path = directPath(store, key)

proc directRefusal(req: ArtifactRequest): ArtifactAck =
  ## The bytes go straight between the shim and the storage module (D-61); this request cannot be served otherwise. An accepted ack when it can.
  if not req.direct: return refuse("direct_required", "the bytes go straight between the shim and the storage module; this shim does not say it can (an old shim: build it again)")
  if directUrl().len == 0: return refuse("direct_required", "this shard has no port for shims on the storage module (storage.directUrl), so it stores no artifacts and no caches")
  ack()

type DirectCheck = enum dcNotDirect, dcAgree, dcDiffer, dcLater, dcBad

proc checkDirectParts(be: ObjectBackend; key, uploadId: string; parts: seq[ArtifactPart]): tuple[verdict: DirectCheck, detail: string, outcome: Outcome] =
  ## The digests the shim reported over its own channel against those the module made of the bytes it received (D-61). `dcNotDirect`: the parts came through the core.
  let given = parts.countIt(it.sha256.len > 0)
  if given == 0: return (dcNotDirect, "", done())
  if given != parts.len: return (dcBad, "put_end names the digest of some parts and not of others", done())
  for p in parts:
    if p.sha256.len != 64 or p.sha256.anyIt(it notin "0123456789abcdef"): return (dcBad, "the digest of part " & $p.part & " is not 64 lower-case hex digits", done())
  let got = be.uploadedParts(key, uploadId)
  if not got.res.ok: return (dcLater, "", got.res)
  if not got.known: return (dcBad, "this store keeps no record of parts sent directly", done())
  if got.parts.len != parts.len: return (dcDiffer, "the shim sent " & $parts.len & " parts, the module received " & $got.parts.len, done())
  for i, p in parts:
    if int(p.part) != got.parts[i].part or p.sha256 != got.parts[i].sha256:
      return (dcDiffer, "part " & $p.part & " is not what the module received", done())
  (dcAgree, "", done())

proc handleCache*(c: var RqClient; req: ArtifactRequest; tenant, scope: string; ds: seq[CacheDecl]; ss: StoreSet; now: int64): ArtifactAck =
  ## DAT-004: the step's cache, by the same channel and blocks as its artifacts. `path` is the cache key. A step may find or read only what it declared (its key, or what one of its
  ## restore keys names) and save only the key it declared; a key that is stored is immutable (`cache_exists`: the saver gives way); room is made by dropping the entries that were
  ## used least long ago (cachestore.makeRoom).
  let key = req.path
  case req.op
  of "cache_find":
    let d = ds.filterIt(it.key == key)
    if d.len == 0: return refuse("not_declared", key & " is not a cache key this step declared")
    let found = c.findEntry(tenant, scope, key, d[0].restoreKeys, now)
    result = ack()
    if found.found:
      let need = directRefusal(req)
      if not need.accepted: return need
      var f = ArtifactFile(path: found.key, size: uint64(found.size), sha256: found.sha256)
      f.offerRead(found.store, found.s3Key)
      if f.grant.len == 0: return refuse("direct_required", "no grant can be made to read " & key & " (the store of the entry has no name)")
      result.files.add f
      result.direct_url = directUrl()
  of "put_begin", "put_end", "put_abort":
    if not ds.maySave(key): return refuse("not_declared", key & " is not a cache key this step declared")
    case req.op
    of "put_begin":
      let need = directRefusal(req)
      if not need.accepted: return need
      if req.size == 0: return refuse("bad_request", "a cache entry has bytes")
      if req.size > uint64(maxEntryBytes): return refuse("too_big", "a cache entry is at most " & $maxEntryBytes & " bytes")
      if req.sha256.len != 64 or req.sha256.anyIt(it notin HexDigits): return refuse("bad_request", "sha256 is not 64 hex digits")
      let sha = req.sha256.toLowerAscii
      let s3 = objectKeyOf(tenant, scope, key)
      if c.storedEntry(tenant, scope, key).found or c.uploadingEntry(tenant, scope, key).found: return refuse("cache_exists", "the cache key " & key & " is stored already; a key is immutable")
      let sname = c.storeFor(tenant, "caches")             # D-59: the store the organisation chose for caches, now; the row remembers it
      let rb = ss.backendFor(sname)
      if rb.be == nil: return rb.refusal
      let be = rb.be
      let room = c.makeRoom(ss, tenant, scope, int64(req.size), cacheQuotaFromEnv())
      if not room.ok: return refuse("quota_exceeded", room.why)
      if not c.beginEntry(schema.newId(), tenant, scope, key, s3, int64(req.size), sha, "uploading", "", now, sname): return refuse("cache_exists", "the cache key " & key & " is being saved by another step")
      let mp = be.createMultipart(s3)
      if not mp.res.ok:
        c.forgetEntry(tenant, scope, key)
        return fromOutcome(mp.res)
      c.setEntryUpload(tenant, scope, key, mp.uploadId)
      result = ack()
      result.upload_id = mp.uploadId
      result.offerDirect(sname, s3, mp.uploadId)
    of "put_end":
      let row = c.uploadingEntry(tenant, scope, key)
      if not row.found or row.uploadId != req.upload_id: return refuse("not_uploading", key & " has no upload under way with this id")
      let rb = ss.backendFor(row.store)
      if rb.be == nil: return rb.refusal
      let dg = checkDirectParts(rb.be, row.s3Key, row.uploadId, req.parts)
      case dg.verdict
      of dcLater: return fromOutcome(dg.outcome)
      of dcBad: return refuse("bad_request", dg.detail)
      of dcNotDirect: return refuse("bad_request", "put_end names the digest of no part: the parts go to the storage module and their digests to the core")
      of dcDiffer:
        discard rb.be.abortMultipart(row.s3Key, row.uploadId)
        c.forgetEntry(tenant, scope, key)
        return refuse("digest_mismatch", key & ": " & dg.detail)
      of dcAgree: discard
      let fin = rb.be.completeMultipart(row.s3Key, row.uploadId, req.parts.mapIt((int(it.part), it.etag)))
      if not fin.ok: return fromOutcome(fin)
      let sz = rb.be.objectSize(row.s3Key)
      if not sz.res.ok or sz.size != row.size:
        discard rb.be.deleteObject(row.s3Key)
        c.forgetEntry(tenant, scope, key)
        return refuse("size_mismatch", key & ": the store holds " & $sz.size & " bytes, " & $row.size & " were announced")
      discard c.markEntryStored(tenant, scope, key)
      result = ack()
    else:       # put_abort
      let row = c.uploadingEntry(tenant, scope, key)
      if row.found:
        let rb = ss.backendFor(row.store)
        if rb.be != nil: discard rb.be.abortMultipart(row.s3Key, row.uploadId)
        c.forgetEntry(tenant, scope, key)
      result = ack()
  else:
    return refuse("bad_request", "the op of a cache request is cache_find, put_begin, put_end or put_abort")

proc handleArtifact*(c: var RqClient; req: ArtifactRequest; master: string; ss: StoreSet): ArtifactAck =
  if req.job_token.len == 0 or not constantTimeEqual(req.job_token, stepToken(master, req.step.run_id, int(req.step.seq), int(req.step.attempt))):
    return refuse("bad_token", "the step's credential is not right")
  let r = c.query(%*[["SELECT s.state, s.opts, ru.tenant_id, ru.group_id FROM steps s JOIN runs ru ON ru.id = s.run_id " &
                      "WHERE s.run_id = ? AND s.ordinal = ? AND s.attempt = ?", req.step.run_id, int(req.step.seq), int(req.step.attempt)]])
  let v = r["results"][0]{"values"}
  # while the step runs; and after it, while its artifacts are being drained from the run's volume for it (core/drains.nim): the shim could not hand them over
  if v == nil or v.len == 0 or (v[0][0].getStr notin [protoName(ssStarting), protoName(ssRunning)] and not c.isDraining(req.step.run_id, int(req.step.seq), int(req.step.attempt))):
    return refuse("not_current", "this attempt of the step is not running")
  let decl = artifactDecl(v[0][1].getStr)
  let tenant = v[0][2].getStr
  let scope = v[0][3].getStr
  let now = getTime().toUnix()
  if req.cache: return handleCache(c, req, tenant, scope, cacheDecls(v[0][1].getStr), ss, now)
  let runId = req.step.run_id
  case req.op
  of "get_list":
    if decl.download.len == 0: return refuse("not_declared", "the step declared no artifacts to download")
    result = ack()
    for name in req.names:
      if name notin decl.download: return refuse("not_declared", name & " is not in the step's download list")
      let found = c.storedUnder(runId, name)
      if found.len == 0: return refuse("artifact_missing", "this run has no artifact " & name)
      for f in found:
        var af = ArtifactFile(path: f.path, size: uint64(f.size), sha256: f.sha256)
        if f.size > 0:               # a file of no bytes is nowhere in the store and needs no grant
          let need = directRefusal(req)
          if not need.accepted: return need
          af.offerRead(f.store, f.key)
          if af.grant.len == 0: return refuse("direct_required", "no grant can be made to read " & f.path & " (the store of the artifact has no name)")
          result.direct_url = directUrl()
        result.files.add af
  of "put_object", "put_begin", "put_end", "put_abort":
    if decl.upload.len == 0: return refuse("not_declared", "the step declared no artifacts to upload")
    let path = cleanPath(req.path)
    if path.len == 0: return refuse("bad_path", "the path " & req.path & " is not a path inside the workspace")
    let key = objectKey(tenant, runId, path)
    case req.op
    of "put_object", "put_begin":
      if req.op == "put_object" and req.size != 0: return refuse("bad_request", "put_object is for a file of no bytes; the bytes of any other go straight to the storage module")
      if req.op == "put_begin":
        let need = directRefusal(req)
        if not need.accepted: return need
        if req.size == 0: return refuse("bad_request", "a file of no bytes is put with put_object")
      if req.size > uint64(maxObjectBytes): return refuse("too_big", path & " is bigger than " & $maxObjectBytes & " bytes")
      if c.runBytes(runId, path) + int64(req.size) > maxRunBytes: return refuse("too_big", "the artifacts of this run would pass " & $maxRunBytes & " bytes")
      # DAT-006: the quota of the organisation (a setting of its profile; 0 is no limit): what it holds already, without the file this one replaces
      let quota = c.orgQuota(runId)
      if quota > 0 and c.orgBytes(tenant, runId, path) + int64(req.size) > quota:
        return refuse("quota_exceeded", "the artifacts of this organisation would pass its quota of " & $quota & " bytes")
      if req.sha256.len != 64 or req.sha256.anyIt(it notin HexDigits): return refuse("bad_request", "sha256 of " & path & " is not 64 hex digits")
      let sha = req.sha256.toLowerAscii
      let sname = c.storeFor(tenant, "artifacts")          # D-59: the store the organisation chose for artifacts, now; the row remembers it
      let rb = ss.backendFor(sname)
      if rb.be == nil: return rb.refusal
      let be = rb.be
      if req.op == "put_object":
        if hexOf(sha256("")) != sha: return refuse("bad_request", "the content of " & path & " is not the SHA-256 that was announced")
        # nothing is put in the store: the module keeps no object of no bytes, and the row says all there is to say of it
        c.recordArtifact(schema.newId(), tenant, runId, int(req.step.seq), path, key, int64(req.size), sha, "stored", "", now, sname)
        result = ack()
      else:
        let mp = be.createMultipart(key)
        if not mp.res.ok: return fromOutcome(mp.res)
        c.recordArtifact(schema.newId(), tenant, runId, int(req.step.seq), path, key, int64(req.size), sha, "uploading", mp.uploadId, now, sname)
        result = ack()
        result.upload_id = mp.uploadId
        result.offerDirect(sname, key, mp.uploadId)
    of "put_end":
      let row = c.uploadingRow(runId, path)
      if not row.found or row.uploadId != req.upload_id: return refuse("not_uploading", path & " has no upload under way with this id")
      let parts = req.parts.mapIt((int(it.part), it.etag))
      let rb = ss.backendFor(row.store)
      if rb.be == nil: return rb.refusal
      let dg = checkDirectParts(rb.be, row.key, row.uploadId, req.parts)
      case dg.verdict
      of dcLater: return fromOutcome(dg.outcome)
      of dcBad: return refuse("bad_request", dg.detail)
      of dcDiffer:
        discard rb.be.abortMultipart(row.key, row.uploadId)
        c.forgetArtifact(runId, path)
        return refuse("digest_mismatch", path & ": " & dg.detail)
      of dcNotDirect: return refuse("bad_request", "put_end names the digest of no part: the parts go to the storage module and their digests to the core")
      of dcAgree: discard
      let fin = rb.be.completeMultipart(row.key, row.uploadId, parts)
      if not fin.ok: return fromOutcome(fin)
      # the store says that the object is there, with the size that was announced; only then it is the run's artifact
      let sz = rb.be.objectSize(row.key)
      if not sz.res.ok or sz.size != row.size:
        discard rb.be.deleteObject(row.key)
        c.forgetArtifact(runId, path)
        return refuse("size_mismatch", path & ": the store holds " & $sz.size & " bytes, " & $row.size & " were announced")
      discard c.markStored(runId, path)
      result = ack()
    else:       # put_abort
      let row = c.uploadingRow(runId, path)
      if row.found:
        let rb = ss.backendFor(row.store)
        if rb.be != nil: discard rb.be.abortMultipart(row.key, row.uploadId)
        c.forgetArtifact(runId, path)
      result = ack()
  else:
    return refuse("bad_request", "the op is put_object (a file of no bytes), put_begin, put_end, put_abort or get_list")

proc serveArtifactIngest*(rqliteUrl, certs: string; port: int) {.thread.} =
  {.cast(gcsafe).}:
    var c = newRq(rqliteUrl)
    let master = coreSecretKey(certs)
    let (_, secretKey) = loadKeypair(certs, "core")
    let conn = listenRep(port, secretKey)
    while not stopServers.load:
      let body = conn.receive()
      if body.len == 0: continue
      # an error in one request is the answer to that request; it does not end the core, and a REP socket needs its answer to go on
      let resp = try: handleArtifact(c, Protobuf.decode(cast[seq[byte]](body), ArtifactRequest), master, newStoreSet())
                 except CatchableError as e:
                   stderr.writeLine "core: artifact ingest: " & e.msg
                   refuse("internal", e.msg)
      let outb = Protobuf.encode(resp)
      var s = newString(outb.len)
      if outb.len > 0: copyMem(addr s[0], unsafeAddr outb[0], outb.len)
      conn.send(s)
    conn.close()
