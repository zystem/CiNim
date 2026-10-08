## ArtifactIngest (DAT-003): the REP server where the artifacts of steps arrive and from which they are read, the same way as the log of a step reaches the
## core: a ZeroMQ channel with CURVE, requests in blocks, each one answered (proto/cicd/internal/v1/step.proto). The core alone knows the store; what it asks of
## it is `ObjectBackend` (core/storagebackend.nim), so the module that talks to the store can leave the core without a step or a shim noticing.
##
## A step may only do what its own options declared (`artifacts = {upload = {...}, download = {...}}`), in its own run, and only while its attempt is running,
## with its own credential (the same HMAC as for its secrets). The sender is the shim, or the job controller on its behalf when it drains the Pod through
## `exec` after the shim could not reach the core (the spool fallback of D-33): the requests are the same, the token is the one core gave in StartStep.
##
## A file of at most one block goes in one request (`put_object`); a bigger one is a multipart upload of the store: `put_begin` answers with the store's upload id,
## `put_part` sends a block and gets its ETag, `put_end` lists the ETags in order. Nothing is kept in the core between the requests but the row of the artifact
## (state `uploading`, the upload id), so a core that restarts in the middle loses nothing; the sender sends the block again. An artifact is `stored` only when
## the store itself says that the object is there with the size announced.
import std/[json, strutils, times, tables, sequtils, atomics]
import protobuf_serialization
import protobuf_serialization/files/type_generator
import crunchy
import ../common/[zmqcurve, rqlite, states, ctrlauth]
import schema, objectstore, scheduler

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

proc handleArtifact*(c: var RqClient; req: ArtifactRequest; master: string): ArtifactAck =
  if req.job_token.len == 0 or not constantTimeEqual(req.job_token, stepToken(master, req.step.run_id, int(req.step.seq), int(req.step.attempt))):
    return refuse("bad_token", "the step's credential is not right")
  let r = c.query(%*[["SELECT s.state, s.opts, ru.tenant_id FROM steps s JOIN runs ru ON ru.id = s.run_id " &
                      "WHERE s.run_id = ? AND s.ordinal = ? AND s.attempt = ?", req.step.run_id, int(req.step.seq), int(req.step.attempt)]])
  let v = r["results"][0]{"values"}
  if v == nil or v.len == 0 or v[0][0].getStr notin [protoName(ssStarting), protoName(ssRunning)]:
    return refuse("not_current", "this attempt of the step is not running")
  let decl = artifactDecl(v[0][1].getStr)
  let tenant = v[0][2].getStr
  let store = c.loadStore()
  if not store.ok:
    return refuse(if store.error == "not_configured": "store_not_configured" else: "store_unavailable",
                  if store.error == "not_configured": "the shard has no object store (PUT /api/v1/storage)" else: "the object store's key cannot be read now: " & store.error)
  let be = store.backend()
  let now = getTime().toUnix()
  let runId = req.step.run_id
  case req.op
  of "get_list":
    if decl.download.len == 0: return refuse("not_declared", "the step declared no artifacts to download")
    result = ack()
    for name in req.names:
      if name notin decl.download: return refuse("not_declared", name & " is not in the step's download list")
      let found = c.storedUnder(runId, name)
      if found.len == 0: return refuse("artifact_missing", "this run has no artifact " & name)
      for f in found: result.files.add ArtifactFile(path: f.path, size: uint64(f.size), sha256: f.sha256)
  of "get_block":
    let art = c.storedArtifact(runId, req.path)
    if not art.found or not decl.download.coveredBy(req.path): return refuse("not_declared", req.path & " is not an artifact this step may read")
    if req.length == 0 or int(req.length) > readSize or int64(req.offset) >= art.size: return refuse("bad_request", "a block is 1.." & $readSize & " bytes inside the file")
    let got = be.readRange(art.key, int64(req.offset), min(int64(req.length), art.size - int64(req.offset)))
    if not got.res.ok: return fromOutcome(got.res)
    result = ack()
    result.data = cast[seq[byte]](got.data)
  of "put_object", "put_begin", "put_part", "put_end", "put_abort":
    if decl.upload.len == 0: return refuse("not_declared", "the step declared no artifacts to upload")
    let path = cleanPath(req.path)
    if path.len == 0: return refuse("bad_path", "the path " & req.path & " is not a path inside the workspace")
    let key = objectKey(tenant, runId, path)
    case req.op
    of "put_object", "put_begin":
      if req.size > uint64(maxObjectBytes): return refuse("too_big", path & " is bigger than " & $maxObjectBytes & " bytes")
      if c.runBytes(runId, path) + int64(req.size) > maxRunBytes: return refuse("too_big", "the artifacts of this run would pass " & $maxRunBytes & " bytes")
      if req.sha256.len != 64 or req.sha256.anyIt(it notin HexDigits): return refuse("bad_request", "sha256 of " & path & " is not 64 hex digits")
      let sha = req.sha256.toLowerAscii
      if req.op == "put_object":
        let data = toStr(req.data)
        if uint64(data.len) != req.size or data.len > partSize: return refuse("bad_request", "put_object holds the whole file, at most " & $partSize & " bytes")
        if hexOf(sha256(data)) != sha: return refuse("bad_request", "the content of " & path & " is not the SHA-256 that was announced")
        let put = be.putObject(key, data)
        if not put.ok: return fromOutcome(put)
        c.recordArtifact(schema.newId(), tenant, runId, int(req.step.seq), path, key, int64(req.size), sha, "stored", "", now)
        result = ack()
      else:
        let mp = be.createMultipart(key)
        if not mp.res.ok: return fromOutcome(mp.res)
        c.recordArtifact(schema.newId(), tenant, runId, int(req.step.seq), path, key, int64(req.size), sha, "uploading", mp.uploadId, now)
        result = ack()
        result.upload_id = mp.uploadId
    of "put_part":
      let row = c.uploadingRow(runId, path)
      if not row.found or row.uploadId != req.upload_id: return refuse("not_uploading", path & " has no upload under way with this id")
      if req.part == 0 or int(req.part) > maxParts or req.data.len == 0 or req.data.len > partSize: return refuse("bad_request", "a part is 1.." & $maxParts & ", 1.." & $partSize & " bytes")
      let up = be.uploadPart(row.key, row.uploadId, int(req.part), toStr(req.data))
      if not up.res.ok: return fromOutcome(up.res)
      result = ack()
      result.etag = up.etag
    of "put_end":
      let row = c.uploadingRow(runId, path)
      if not row.found or row.uploadId != req.upload_id: return refuse("not_uploading", path & " has no upload under way with this id")
      let parts = req.parts.mapIt((int(it.part), it.etag))
      let fin = be.completeMultipart(row.key, row.uploadId, parts)
      if not fin.ok: return fromOutcome(fin)
      # the store says that the object is there, with the size that was announced; only then it is the run's artifact
      let sz = be.objectSize(row.key)
      if not sz.res.ok or sz.size != row.size:
        discard be.deleteObject(row.key)
        c.forgetArtifact(runId, path)
        return refuse("size_mismatch", path & ": the store holds " & $sz.size & " bytes, " & $row.size & " were announced")
      discard c.markStored(runId, path)
      result = ack()
    else:       # put_abort
      let row = c.uploadingRow(runId, path)
      if row.found:
        discard be.abortMultipart(row.key, row.uploadId)
        c.forgetArtifact(runId, path)
      result = ack()
  else:
    return refuse("bad_request", "the op is put_object, put_begin, put_part, put_end, put_abort, get_list or get_block")

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
      let resp = try: handleArtifact(c, Protobuf.decode(cast[seq[byte]](body), ArtifactRequest), master)
                 except CatchableError as e:
                   stderr.writeLine "core: artifact ingest: " & e.msg
                   refuse("internal", e.msg)
      let outb = Protobuf.encode(resp)
      var s = newString(outb.len)
      if outb.len > 0: copyMem(addr s[0], unsafeAddr outb[0], outb.len)
      conn.send(s)
    conn.close()
