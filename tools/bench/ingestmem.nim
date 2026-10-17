## where does the memory of the core's artifact path go: one 8 MiB put_part, stage by stage (the single ingest thread keeps the high-water mark of its heap)
import std/[strutils, httpclient, os, osproc]
import protobuf_serialization
import protobuf_serialization/files/type_generator
import crunchy
import_proto3 "../../build/nimproto/all.proto"

proc rssMiB(): int =
  for l in lines("/proc/self/status"):
    if l.startsWith("VmRSS:"): return parseInt(l.splitWhitespace()[1]) div 1024
proc report(what: string) = echo what.alignLeft(46), " heap total ", getTotalMem() div (1024*1024), " MiB, in use ", getOccupiedMem() div (1024*1024), " MiB, RSS ", rssMiB(), " MiB"

func toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)
func hexOf(a: openArray[uint8]): string =
  const d = "0123456789abcdef"
  for b in a:
    result.add d[int(b shr 4)]
    result.add d[int(b and 15)]

const mb8 = 8 * 1024 * 1024
report "start"
var wire = ""
block:
  var raw = newSeq[byte](mb8)
  for i in 0 ..< raw.len: raw[i] = byte(i mod 251)
  let bytes = Protobuf.encode(ArtifactRequest(op: "put_part", path: "dist/big.bin", upload_id: "u", part: 1, data: raw))
  wire = newString(bytes.len)
  copyMem(addr wire[0], unsafeAddr bytes[0], bytes.len)
report "built the message (test setup, 3 copies live)"
for round in 1 .. 3:
  block:
    let body = wire                                                   # what `conn.receive()` returns
    let req = Protobuf.decode(cast[seq[byte]](body), ArtifactRequest)
    report "round " & $round & ": decoded the request"
    let s = toStr(req.data)
    report "round " & $round & ": toStr(req.data)"
    let h = hexOf(sha256(s))
    report "round " & $round & ": sha256"
    # RemoteBackend: std/httpclient with the body
    let cl = newHttpClient(timeout = 20000)
    try:
      let r = cl.request("http://127.0.0.1:29977/x", httpMethod = HttpPut, body = s)
      discard r.body
    except CatchableError as e: echo "  (http: ", e.msg, ")"
    cl.close()
    report "round " & $round & ": sent by std/httpclient"
  report "round " & $round & ": all released"
