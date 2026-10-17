## The shim's side of the direct transfer (D-61, docs/storage-module.md, "Direct transfer from the shim"): the bytes of an artifact or a cache entry go to the storage module over plain
## HTTP, on its port for shims, with the grant that the core gave over the authenticated channel; the shim reports the digest of every part to the core over that channel, and the core
## completes the upload only when the module received what the shim reported. No TLS (the bytes are trusted by their digests, not by the wire); a plain `std/httpclient`, which keeps the
## connection between requests. Pure: no ZeroMQ, so it is tested against the real module (tests/integration/tshimdirect.nim).
import std/[httpclient, strutils, json, times, os]

type
  DirectReply* = object
    ok*: bool
    retry*: bool                ## not ok and retry: the module or its store did not answer now
    fallback*: bool             ## the module cannot be reached from here, or does not take the grant: the bytes go through the core instead
    code*: int
    etag*: string               ## a part that was put
    data*: string               ## a range that was read
    detail*: string

  DirectClient* = ref object
    base: string
    http: HttpClient

const
  connectTries = 2              ## a module that cannot be reached at all is given up (for the core's channel) after this many tries, a second apart

proc newDirectClient*(base: string): DirectClient = DirectClient(base: base.strip(chars = {'/'}))

proc close*(d: DirectClient) =
  if d.http != nil:
    try: d.http.close() except CatchableError: discard
    d.http = nil

proc errorText(body: string): string =
  try:
    let j = parseJson(body)
    j{"error"}.getStr & (if j{"detail"}.getStr.len > 0: ": " & j{"detail"}.getStr else: "")
  except CatchableError: body[0 ..< min(body.len, 160)]

proc request(d: DirectClient; meth: HttpMethod; path, grant: string; headers: openArray[(string, string)]; body: string; patience: int): DirectReply =
  ## One request, again while the module does not answer or says to wait, for up to `patience` seconds (a connection that fails twice running is `fallback`).
  let until = epochTime() + patience.float
  var failures = 0
  while true:
    try:
      if d.http == nil: d.http = newHttpClient(timeout = 60000)
      var h = newHttpHeaders({"Authorization": "Bearer " & grant})
      for (k, v) in headers: h[k] = v
      let r = d.http.request(d.base & path, httpMethod = meth, body = body, headers = h)
      let code = r.code.int
      failures = 0
      if code in 200 .. 299: return DirectReply(ok: true, code: code, etag: (try: parseJson(r.body){"etag"}.getStr except CatchableError: ""), data: r.body)
      let why = errorText(r.body)
      if code in [401, 403, 404, 409]: return DirectReply(fallback: true, code: code, detail: "the storage module answered " & $code & " " & why)
      if code >= 500 and ("answered 422" in why or "another content" in why):
        # a node of the mirror refused the part because its bytes are not the digest it was told: not a reason to wait, the part is sent again (putPart) and then given up
        return DirectReply(code: code, detail: "sha256_mismatch: the storage module answered " & $code & " " & why)
      if code == 429 or code >= 500:
        if epochTime() >= until: return DirectReply(retry: true, code: code, detail: "the storage module answered " & $code & " " & why)
        d.close()
        sleep 2000
        continue
      return DirectReply(code: code, detail: "the storage module answered " & $code & " " & why)
    except CatchableError as e:
      d.close()
      inc failures
      if failures >= connectTries: return DirectReply(fallback: true, retry: true, detail: "the storage module could not be reached: " & e.msg)
      if epochTime() >= until: return DirectReply(retry: true, detail: "the storage module did not answer: " & e.msg)
      sleep 1000

proc putPart*(d: DirectClient; directPath, grant, upload: string; part: int; data, sha256: string; patience: int): DirectReply =
  ## One part of an upload; `etag` is what the store answered for it. A part whose digest the module found to be another (a body changed on the way) is sent again, twice, before it is given up.
  for attempt in 1 .. 3:
    result = d.request(HttpPut, directPath & "?upload=" & upload & "&part=" & $part, grant, [("X-Content-SHA256", sha256)], data, patience)
    if result.ok or result.retry or result.fallback or "sha256_mismatch" notin result.detail: return
  result.detail = result.detail & " (three times)"

proc getRange*(d: DirectClient; directPath, grant: string; offset, length: int64; patience: int): DirectReply =
  d.request(HttpGet, directPath, grant, [("Range", "bytes=" & $offset & "-" & $(offset + length - 1))], "", patience)
