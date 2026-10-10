## The pipe between the supervisor of a conductor and a run process (docs/conductors.md section 5): frames of `kind (1 byte) | length (4 bytes, big
## endian) | payload`. The payloads are protobuf messages of the executor channel (a lease, a host call, its answer, the end of the run). A reader
## takes bytes as they come (the supervisor reads without blocking) and gives whole frames; a broken stream is a flag, not a guess.
import std/options
import posix

const maxPipePayload* = 64 * 1024 * 1024

type
  PipeKind* = enum
    pkLease = 'L'       ## supervisor to run: the LeaseGranted
    pkCall = 'C'        ## run to supervisor: a HostCall
    pkReply = 'R'       ## supervisor to run: the answer to a call (an ExecutorResponse)
    pkFinish = 'F'      ## run to supervisor: a FinishRun; the run process then exits
    pkSuspended = 'S'   ## run to supervisor: the run waits (for a step); the run process then exits
    pkLost = 'X'        ## run to supervisor: the core said the lease is lost; the run process then exits and nothing is written about the run
  PipeFrame* = tuple[kind: PipeKind, payload: string]
  PipeReader* = object
    buf: string
    broken*: bool

func encodePipe*(kind: PipeKind; payload: string): string =
  let n = payload.len
  result = newStringOfCap(5 + n)
  result.add char(kind)
  result.add char((n shr 24) and 255)
  result.add char((n shr 16) and 255)
  result.add char((n shr 8) and 255)
  result.add char(n and 255)
  result.add payload

func isKind(c: char): bool = c in {'L', 'C', 'R', 'F', 'S', 'X'}

proc feed*(r: var PipeReader; data: string) = r.buf.add data

proc next*(r: var PipeReader): Option[PipeFrame] =
  ## the next whole frame; none if there is not one yet, or if the stream is broken (`broken`)
  if r.broken or r.buf.len < 5: return none(PipeFrame)
  if not isKind(r.buf[0]):
    r.broken = true
    return none(PipeFrame)
  let n = (ord(r.buf[1]) shl 24) or (ord(r.buf[2]) shl 16) or (ord(r.buf[3]) shl 8) or ord(r.buf[4])
  if n < 0 or n > maxPipePayload:
    r.broken = true
    return none(PipeFrame)
  if r.buf.len < 5 + n: return none(PipeFrame)
  let frame: PipeFrame = (PipeKind(r.buf[0]), r.buf[5 ..< 5 + n])
  r.buf = r.buf[5 + n .. ^1]
  some(frame)

# --- blocking use on a file descriptor (the run process; the supervisor writes its answers this way too)

proc openPipe*(fds: var array[2, cint]): bool = pipe(fds) == 0

proc closeFd*(fd: cint) = discard close(fd)

proc writeAll(fd: cint; s: string): bool =
  var off = 0
  while off < s.len:
    let n = write(fd, unsafeAddr s[off], s.len - off)
    if n < 0:
      if errno == EINTR: continue
      return false
    off += n
  true

proc writePipeFd*(fd: cint; kind: PipeKind; payload: string): bool = writeAll(fd, encodePipe(kind, payload))

proc readExactly(fd: cint; n: int; into: var string): bool =
  into = newString(n)
  var off = 0
  while off < n:
    let got = read(fd, addr into[off], n - off)
    if got < 0:
      if errno == EINTR: continue
      return false
    if got == 0: return false
    off += got
  true

proc readPipeFd*(fd: cint): Option[PipeFrame] =
  ## one whole frame, waiting for it; none when the other end is closed or the stream is broken
  var head: string
  if not readExactly(fd, 5, head): return none(PipeFrame)
  var r = PipeReader()
  r.feed head
  if not isKind(head[0]): return none(PipeFrame)
  let n = (ord(head[1]) shl 24) or (ord(head[2]) shl 16) or (ord(head[3]) shl 8) or ord(head[4])
  if n < 0 or n > maxPipePayload: return none(PipeFrame)
  var body: string
  if n > 0 and not readExactly(fd, n, body): return none(PipeFrame)
  some((PipeKind(head[0]), body))
