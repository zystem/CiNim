## The wire form of a shim spool read through `kubectl exec`-style streams (D-29, the fallback for a shim that cannot reach core):
## `cicd-shim --read-spool DIR` writes the queued blocks to its stdout as frames, the job-controller reads them through the
## Kubernetes API and hands them to core's LogIngest, then `cicd-shim --ack-spool DIR --upto N` frees what core has.
## A frame is a header line and the block's bytes:  CICD-BLK <seq> <first_ln> <lines> <encoding> <len> <crc32c hex>\n<data>
## Frames are whole blocks (never a slice of a stream): the usual mistakes of log readers over exec streams - duplicates after a
## reconnect, a line cut in two by a full buffer, a hang when the file is gone - are excluded by the unit of transfer (a block
## with a sequence number and a checksum), by core's idempotence on `seq`, and by a parser that reports a damaged tail instead
## of guessing. Pure; std + crc32c only.
import std/strutils
import crunchy

type
  Frame* = object
    seq*, firstLn*: uint64
    lines*: uint32
    encoding*: string
    data*: string

  Parsed* = object
    frames*: seq[Frame]
    damaged*: bool        ## a frame failed its checksum or the header is malformed: everything after it is not trusted
    consumed*: int        ## bytes of the input that formed whole, valid frames

const headerTag = "CICD-BLK "

func encodeFrame*(f: Frame): string =
  headerTag & $f.seq & " " & $f.firstLn & " " & $f.lines & " " & f.encoding & " " & $f.data.len & " " &
    toHex(int64(crc32c(f.data)), 8).toLowerAscii & "\n" & f.data

func parseFrames*(s: string): Parsed =
  ## Whole frames from the start of `s`; an incomplete last frame is simply not consumed (more bytes may follow).
  var pos = 0
  while pos < s.len:
    let nl = s.find('\n', pos)
    if nl < 0: break
    let line = s[pos ..< nl]
    if not line.startsWith(headerTag):
      if line.len > 0 or true:                # stray output (an error message from the exec) is not a frame
        result.damaged = true
        return
    let p = line[headerTag.len .. ^1].split(' ')
    if p.len != 6:
      result.damaged = true
      return
    var f = Frame(encoding: p[3])
    var len = 0
    var crc: uint32
    try:
      f.seq = parseBiggestUInt(p[0])
      f.firstLn = parseBiggestUInt(p[1])
      f.lines = uint32(parseBiggestUInt(p[2]))
      len = parseInt(p[4])
      crc = uint32(parseHexInt(p[5]))
    except ValueError:
      result.damaged = true
      return
    if len < 0 or len > 64 * 1024 * 1024:
      result.damaged = true
      return
    if nl + 1 + len > s.len: break              # the data has not all arrived yet
    f.data = s[nl + 1 ..< nl + 1 + len]
    if crc32c(f.data) != crc:
      result.damaged = true
      return
    result.frames.add f
    pos = nl + 1 + len
    result.consumed = pos
