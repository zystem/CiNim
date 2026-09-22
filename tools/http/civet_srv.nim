## Measurement server: civetweb + nimja. Routes: /page (streamed chunks), /err, /stream?mb=N, /sse, /rss.
import std/[strutils, parseutils]
import nimja
import common/civetbind

type Row = object
  id: int
  name, state: string

proc rowHtml(r: Row): string =
  compileTemplateStr("<tr><td>{{ r.id }}</td><td>{{ r.name }}</td><td class=\"{{ r.state }}\">{{ r.state }}</td></tr>\n")

proc pageHead(title: string): string =
  compileTemplateStr("<!doctype html><html><head><meta charset=utf-8><title>{{ title }}</title></head><body><h1>{{ title }}</h1><table>\n")

proc chunk(c: ptr mg_connection; s: string) =
  discard mg_send_chunk(c, s.cstring, s.len.cuint)

proc startChunked(c: ptr mg_connection; ctype: string) =
  discard mg_response_header_start(c, 200)
  discard mg_response_header_add(c, "Content-Type", ctype.cstring, -1)
  discard mg_response_header_add(c, "Transfer-Encoding", "chunked", -1)
  discard mg_response_header_send(c)

proc usleep(us: cuint): cint {.importc: "usleep", header: "<unistd.h>", discardable.}

proc rssKb(): int =
  var a, b: int
  discard parseInt(readFile("/proc/self/statm").splitWhitespace()[1], b)
  b * 4

proc page(c: ptr mg_connection; d: pointer): cint {.cdecl.} =
  try:
    startChunked(c, "text/html; charset=utf-8")
    chunk(c, pageHead("Runs"))
    for i in 0 ..< 100:                               # rendered and sent row by row: memory does not depend on the page size (UI-009)
      chunk(c, rowHtml(Row(id: i, name: "pipeline-" & $i & " <b>", state: (if i mod 7 == 0: "failed" else: "ok"))))
    chunk(c, "</table></body></html>\n")
    discard mg_send_chunk(c, "", 0)
  except CatchableError:
    discard
  200

proc err(c: ptr mg_connection; d: pointer): cint {.cdecl.} =
  try:
    raise newException(ValueError, "boom")            # exceptions must never cross the C frame: caught here, answered as a Problem Details 500
  except CatchableError as e:
    let body = "{\"type\":\"about:blank\",\"status\":500,\"detail\":\"" & e.msg & "\"}"
    discard mg_response_header_start(c, 500)
    discard mg_response_header_add(c, "Content-Type", "application/problem+json", -1)
    discard mg_response_header_add(c, "Content-Length", ($body.len).cstring, -1)
    discard mg_response_header_send(c)
    discard mg_write(c, body.cstring, body.len.csize_t)
  500

proc stream(c: ptr mg_connection; d: pointer): cint {.cdecl.} =
  let info = mg_get_request_info(c)
  var mb = 16
  let q = if info.query_string == nil: "" else: $info.query_string
  if q.startsWith("mb="): discard parseInt(q[3 .. ^1], mb)
  startChunked(c, "application/octet-stream")
  let block64k = 'x'.repeat(65536)
  for _ in 0 ..< mb * 16: chunk(c, block64k)          # blocks on a slow reader: backpressure, constant memory
  discard mg_send_chunk(c, "", 0)
  200

proc sse(c: ptr mg_connection; d: pointer): cint {.cdecl.} =
  discard mg_response_header_start(c, 200)
  discard mg_response_header_add(c, "Content-Type", "text/event-stream", -1)
  discard mg_response_header_add(c, "Cache-Control", "no-cache", -1)
  discard mg_response_header_add(c, "Transfer-Encoding", "chunked", -1)
  discard mg_response_header_send(c)
  for i in 0 ..< 5:
    chunk(c, "event: status\ndata: {\"n\":" & $i & "}\n\n")
    usleep(200_000)
  discard mg_send_chunk(c, "", 0)
  200

proc rss(c: ptr mg_connection; d: pointer): cint {.cdecl.} =
  let s = $rssKb()
  discard mg_response_header_start(c, 200)
  discard mg_response_header_add(c, "Content-Length", ($s.len).cstring, -1)
  discard mg_response_header_send(c)
  discard mg_write(c, s.cstring, s.len.csize_t)
  200


discard mg_init_library(0)
var opts = allocCStringArray(["listening_ports", "18800", "num_threads", "8", "request_timeout_ms", "30000"])
let ctx = mg_start(nil, nil, opts)
doAssert ctx != nil, "mg_start failed"
mg_set_request_handler(ctx, "/page", page, nil)
mg_set_request_handler(ctx, "/err", err, nil)
mg_set_request_handler(ctx, "/stream", stream, nil)
mg_set_request_handler(ctx, "/sse", sse, nil)
mg_set_request_handler(ctx, "/rss", rss, nil)
while true: usleep(1_000_000)
