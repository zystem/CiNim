## AWS Signature Version 4 for S3, query-string form (a presigned URL): the core signs, and whoever holds the URL can do that one thing (put, get, head or
## delete one object) until it expires, with no key of its own (DAT-003). The payload is not signed (`UNSIGNED-PAYLOAD`), so a URL does not depend on the
## content it carries. Path-style addressing (`http://host:port/bucket/key`), which is what Garage, MinIO and a store without wildcard DNS want.
import std/[strutils, times, algorithm]
import crunchy

func hex(a: openArray[uint8]): string =
  const digits = "0123456789abcdef"
  for b in a:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

func uriEncode*(s: string; keepSlash = false): string =
  ## RFC 3986 unreserved characters stay, everything else is %XX in capitals; `/` stays in a path
  const unreserved = {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_', '.', '~'}
  for ch in s:
    if ch in unreserved or (keepSlash and ch == '/'): result.add ch
    else: result.add '%' & toHex(ord(ch), 2)

proc amzDate*(unix: int64): string = fromUnix(unix).utc.format("yyyyMMdd'T'HHmmss'Z'")

proc signingKey(secret, date, region: string): string =
  proc raw(k, m: string): string =
    let h = hmacSha256(k, m)
    result = newString(32)
    for i in 0 ..< 32: result[i] = char(h[i])
  raw(raw(raw(raw("AWS4" & secret, date), region), "s3"), "aws4_request")

proc presignQuery*(httpMethod, host, path, region, keyId, secret, stamp: string; expires: int; extra: openArray[(string, string)] = []): string =
  ## the query string of a presigned request, signature last. `host` is as the client will send it (with the port when it is not the default one),
  ## `path` is not encoded yet. `stamp` is `yyyyMMddTHHmmssZ`.
  let date = stamp[0 ..< 8]
  let scope = date & "/" & region & "/s3/aws4_request"
  # the canonical query: the parameters sorted by name, each name and value encoded (the `/` of the credential too)
  var params = @[("X-Amz-Algorithm", "AWS4-HMAC-SHA256"), ("X-Amz-Credential", keyId & "/" & scope), ("X-Amz-Date", stamp),
                 ("X-Amz-Expires", $expires), ("X-Amz-SignedHeaders", "host")]
  for e in extra: params.add e                       # the request's own parameters (`uploads`, `partNumber`, `uploadId`) are signed with the rest
  params.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  var q = ""
  for (k, v) in params:
    if q.len > 0: q.add '&'
    q.add uriEncode(k) & "=" & uriEncode(v)
  let canonical = httpMethod & "\n" & uriEncode(path, keepSlash = true) & "\n" & q & "\nhost:" & host & "\n\nhost\nUNSIGNED-PAYLOAD"
  let toSign = "AWS4-HMAC-SHA256\n" & stamp & "\n" & scope & "\n" & hex(sha256(canonical))
  q & "&X-Amz-Signature=" & hex(hmacSha256(signingKey(secret, date, region), toSign))

proc splitEndpoint*(endpoint: string): tuple[ok: bool, scheme, host: string] =
  ## `http://garage:3900` -> (http, garage:3900); no path, no query
  let sep = endpoint.find("://")
  if sep < 1: return
  let scheme = endpoint[0 ..< sep]
  let host = endpoint[sep + 3 .. ^1].strip(chars = {'/'})
  if scheme notin ["http", "https"] or host.len == 0 or '/' in host or '?' in host or ' ' in host: return
  (true, scheme, host)

proc presignObject*(httpMethod, endpoint, bucket, key, region, keyId, secret: string; now: int64; expires: int; extra: openArray[(string, string)] = []): string =
  ## the URL of one object, path-style
  let e = splitEndpoint(endpoint)
  doAssert e.ok, "bad endpoint"
  let path = "/" & bucket & "/" & key
  e.scheme & "://" & e.host & uriEncode(path, keepSlash = true) & "?" & presignQuery(httpMethod, e.host, path, region, keyId, secret, amzDate(now), expires, extra)
