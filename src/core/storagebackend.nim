## The seam of the storage module (DAT-003, D-46): what the core asks of an object store, whatever it is and wherever it runs.
##
## The steps never see the store. A shim moves the bytes of an artifact to and from the core over the authenticated channel, like its log (core/artifactingest.nim),
## and the core does what is written here with them, in blocks. So the store can change without touching a step or a shim, and the module that talks to it can
## move out of the core: `ObjectBackend` is the whole of that module's contract, in these eight operations, none of which holds state between calls (a multipart
## upload is named by the store's own upload id and the parts' ETags, which the caller keeps). Built: `S3Backend` (core/s3backend.nim), in the core's process.
## To run the storage module as a separate service, implement the same eight operations as requests and answers over ZeroMQ with CURVE and write a backend that
## sends them (`RemoteBackend`): the core still decides everything (the settings and the key are the core's, sealed in its database, and are sent to the service
## with each request or when it connects; the service keeps nothing), and `ArtifactIngest` may then be served by that service as well, with the shims pointed to
## it by `--artifact-addr`. docs/artifacts.md, "Moving the storage module out of the core".
type
  Outcome* = object
    ok*: bool
    retry*: bool             ## the store did not answer or asked to wait: the same call may work later; not ok and not retry is final
    error*: string

  ObjectBackend* = ref object of RootObj

const
  partSize* = 8 * 1024 * 1024      ## a block of a multipart upload (S3 wants at least 5 MiB for every part but the last)
  readSize* = 4 * 1024 * 1024      ## a block of a read
  maxParts* = 10000                ## the limit of S3

proc fail*(error: string; retry = false): Outcome = Outcome(ok: false, retry: retry, error: error)
proc done*(): Outcome = Outcome(ok: true)

method putObject*(b: ObjectBackend; key, data: string): Outcome {.base.} = fail("not implemented")
  ## a whole object in one call (up to `partSize` bytes)
method createMultipart*(b: ObjectBackend; key: string): tuple[res: Outcome, uploadId: string] {.base.} = (fail("not implemented"), "")
method uploadPart*(b: ObjectBackend; key, uploadId: string; part: int; data: string): tuple[res: Outcome, etag: string] {.base.} = (fail("not implemented"), "")
  ## parts are numbered from 1; the same number again replaces the part (a retry is safe)
method completeMultipart*(b: ObjectBackend; key, uploadId: string; parts: seq[(int, string)]): Outcome {.base.} = fail("not implemented")
method abortMultipart*(b: ObjectBackend; key, uploadId: string): Outcome {.base.} = fail("not implemented")
method readRange*(b: ObjectBackend; key: string; offset, length: int64): tuple[res: Outcome, data: string] {.base.} = (fail("not implemented"), "")
method objectSize*(b: ObjectBackend; key: string): tuple[res: Outcome, size: int64] {.base.} = (fail("not implemented"), -1'i64)
  ## `res.ok` and a size, or `res.ok` false and `res.error` "no such object" when it is not there
method deleteObject*(b: ObjectBackend; key: string): Outcome {.base.} = fail("not implemented")

proc roundTrip*(b: ObjectBackend): string =
  ## "" if an object can be put, read back and deleted, and a multipart upload can be started and cancelled; else what failed. The check of `PUT /api/v1/storage`.
  let key = "_check/probe"
  let body = "cinim object store check"
  let put = b.putObject(key, body)
  if not put.ok: return "put: " & put.error
  let got = b.readRange(key, 0, body.len)
  if not got.res.ok or got.data != body: return "get: " & (if got.res.ok: "another content came back" else: got.res.error)
  let del = b.deleteObject(key)
  if not del.ok: return "delete: " & del.error
  let mp = b.createMultipart(key & "-multipart")
  if not mp.res.ok: return "multipart: " & mp.res.error
  discard b.abortMultipart(key & "-multipart", mp.uploadId)
  ""
