## `ObjectBackend` over the S3 API (core/storagebackend.nim): Garage, MinIO, or S3 itself, path-style, with presigned URLs made by the core for its own calls
## (common/sigv4.nim), one HTTP request per operation. Nothing is kept between calls.
import std/[strutils, httpclient, times]
import ../common/sigv4
import storagebackend

type S3Backend* = ref object of ObjectBackend
  endpoint*, region*, bucket*, keyId*, secret*: string

const callExpires = 300

func completeXml*(parts: seq[(int, string)]): string =
  ## the body of CompleteMultipartUpload; the parts in ascending order, as S3 insists
  result = "<CompleteMultipartUpload>"
  for (n, etag) in parts:
    let tag = if etag.startsWith("\""): etag else: "\"" & etag & "\""
    result.add "<Part><PartNumber>" & $n & "</PartNumber><ETag>" & tag.replace("&", "&amp;").replace("<", "&lt;") & "</ETag></Part>"
  result.add "</CompleteMultipartUpload>"

func tagText*(xml, tag: string): string =
  ## the text of the first `<tag>…</tag>`, "" if there is none; the answers of S3 are flat enough for this
  let open = "<" & tag & ">"
  let a = xml.find(open)
  if a < 0: return ""
  let b = xml.find("</" & tag & ">", a)
  if b < 0: "" else: xml[a + open.len ..< b]

func s3Error*(status: int; body: string): string =
  ## what the store said, in a line
  let code = tagText(body, "Code")
  let msg = tagText(body, "Message")
  "the store answered " & $status & (if code.len > 0: " " & code else: "") & (if msg.len > 0: ": " & msg[0 ..< min(msg.len, 200)] else: "")

proc call(b: S3Backend; meth: HttpMethod; key: string; extra: openArray[(string, string)] = []; body = ""; headers: HttpHeaders = nil;
          timeout = 120000): tuple[res: Outcome, code: int, body: string, headers: HttpHeaders] =
  let m = case meth
          of HttpPut: "PUT"
          of HttpPost: "POST"
          of HttpDelete: "DELETE"
          of HttpHead: "HEAD"
          else: "GET"
  let url = presignObject(m, b.endpoint, b.bucket, key, b.region, b.keyId, b.secret, getTime().toUnix(), callExpires, extra)
  let cl = newHttpClient(timeout = timeout)
  defer: cl.close()
  try:
    let r = cl.request(url, httpMethod = meth, body = body, headers = headers)
    result.code = r.code.int
    result.body = r.body
    result.headers = r.headers
    result.res = if result.code div 100 == 2: done() else: fail(s3Error(result.code, r.body), retry = result.code in [429, 500, 502, 503, 504])
  except CatchableError as e:
    result.res = fail("the store did not answer: " & e.msg, retry = true)

method putObject*(b: S3Backend; key, data: string): Outcome = b.call(HttpPut, key, body = data).res

method createMultipart*(b: S3Backend; key: string): tuple[res: Outcome, uploadId: string] =
  let r = b.call(HttpPost, key, [("uploads", "")])
  if not r.res.ok: return (r.res, "")
  let id = tagText(r.body, "UploadId")
  if id.len == 0: return (fail("the store did not name the upload"), "")
  (done(), id)

method uploadPart*(b: S3Backend; key, uploadId: string; part: int; data: string): tuple[res: Outcome, etag: string] =
  let r = b.call(HttpPut, key, [("partNumber", $part), ("uploadId", uploadId)], body = data)
  if not r.res.ok: return (r.res, "")
  let etag = r.headers.getOrDefault("etag")
  if etag.len == 0: return (fail("the store gave no ETag for the part"), "")
  (done(), etag)

method completeMultipart*(b: S3Backend; key, uploadId: string; parts: seq[(int, string)]): Outcome =
  let r = b.call(HttpPost, key, [("uploadId", uploadId)], body = completeXml(parts))
  # S3 may answer 200 and put an error into the body
  if r.res.ok and "<Error>" in r.body: return fail(s3Error(r.code, r.body))
  r.res

method abortMultipart*(b: S3Backend; key, uploadId: string): Outcome = b.call(HttpDelete, key, [("uploadId", uploadId)]).res

method readRange*(b: S3Backend; key: string; offset, length: int64): tuple[res: Outcome, data: string] =
  # the Range header is not among the signed ones, the signature covers the host only
  let r = b.call(HttpGet, key, headers = newHttpHeaders({"Range": "bytes=" & $offset & "-" & $(offset + length - 1)}))
  if not r.res.ok: return (r.res, "")
  (done(), r.body)

method objectSize*(b: S3Backend; key: string): tuple[res: Outcome, size: int64] =
  let r = b.call(HttpHead, key, timeout = 20000)
  if r.code == 404: return (fail("no such object"), -1'i64)
  if not r.res.ok: return (r.res, -1'i64)
  let size = try: parseBiggestInt(r.headers.getOrDefault("content-length")) except ValueError: -1
  if size < 0: (fail("the store gave no size"), -1'i64) else: (done(), size)

method deleteObject*(b: S3Backend; key: string): Outcome = b.call(HttpDelete, key).res
