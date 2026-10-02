## Log spool (D-27): the shim turns the step's output into VictoriaLogs jsonline records, compresses them in
## independent gzip blocks and queues the blocks as files on the Pod's ephemeral storage; a sender drains the files to
## core. Core forwards each block to vlagent untouched (vlagent reads independently compressed blocks glued into one body -
## checked on the live vlagent), so nothing is ever recompressed. Pure module (no ZeroMQ): unit-tested in tlogspool.nim.
##
## Secrets (DAT-002, second half) are masked here, before compression - core never sees the plain text. Only values
## known when the step starts (`--secrets-file`) and at least `minSecretLen` characters long are masked (shorter ones
## would mangle ordinary output); a value split across two lines is not recognised.
import std/[os, strutils, json, algorithm, atomics, unicode]
import zippy
import secretmask

const
  blockRawTarget* = 64 * 1024     ## uncompressed bytes at which a block is cut
  maxLineBytes* = 32 * 1024       ## a longer line is split into several records
  minSecretLen* = 4
  encGzip* = "gzip"

type
  LogBlock* = object
    seq*: uint64                  ## per step, gap-free, starts at 1
    firstLn*: uint64              ## `ln` of the first record
    lines*: uint32
    encoding*: string
    data*: string                 ## the compressed bytes

  Builder* = object
    job*, run*: string            ## VictoriaLogs labels of every record
    baseMs*: int64                ## `_time` = baseMs + ln (DAT-001: a monotonic key), the wall clock goes into `ts`
    masker: Masker                ## secrets masked before anything leaves the shim (secretmask.nim)
    maxBytes: int64               ## the step's log limit (0 = none): past it lines are counted, not stored
    bytesIn: int64
    truncated*: bool
    droppedLines*: uint64
    carry: string                 ## a started, not yet newline-terminated line
    raw: string                   ## records of the block being built
    rawLines: uint32
    nextLn: uint64
    blockFirstLn: uint64
    nextSeq: uint64

var spoolBytes*: Atomic[int64]    ## compressed bytes currently queued on disk; one spool per process (shim and sender share it)

# ------------------------------------------------------------------ records

func maskSecrets*(line: string; secrets: openArray[string]): string =
  result = line
  for s in secrets:
    if s.len >= minSecretLen and s in result: result = result.replace(s, "***")

const replacementChar = "\xEF\xBF\xBD"     ## U+FFFD

func seqLen(s: string; i: int): int =
  ## Length of the well-formed UTF-8 sequence starting at s[i] (RFC 3629: no overlongs, no surrogates, nothing above
  ## U+10FFFF), 0 if there is none (invalid lead byte, bad or missing continuation).
  let b = ord(s[i])
  template cont(k: int; lo = 0x80, hi = 0xBF): bool = i + k < s.len and ord(s[i + k]) in lo .. hi
  if b < 0x80: 1
  elif b in 0xC2 .. 0xDF: (if cont(1): 2 else: 0)
  elif b == 0xE0: (if cont(1, 0xA0, 0xBF) and cont(2): 3 else: 0)
  elif b == 0xED: (if cont(1, 0x80, 0x9F) and cont(2): 3 else: 0)
  elif b in 0xE1 .. 0xEF: (if cont(1) and cont(2): 3 else: 0)
  elif b == 0xF0: (if cont(1, 0x90, 0xBF) and cont(2) and cont(3): 4 else: 0)
  elif b in 0xF1 .. 0xF3: (if cont(1) and cont(2) and cont(3): 4 else: 0)
  elif b == 0xF4: (if cont(1, 0x80, 0x8F) and cont(2) and cont(3): 4 else: 0)
  else: 0

func safeText*(s: string): string =
  ## UTF-8 is allowed as it is; only what is not valid UTF-8 is replaced - each bad byte by U+FFFD - so that the record is
  ## valid JSON for VictoriaLogs and a stray byte does not cost the rest of the line its non-ASCII text.
  var ascii = true                 # (std/unicode's validateUtf8 lets surrogates through, so it is not used here)
  for c in s:
    if ord(c) >= 0x80:
      ascii = false
      break
  if ascii: return s
  result = newStringOfCap(s.len + 8)
  var i = 0
  while i < s.len:
    let n = seqLen(s, i)
    if n == 0:
      result.add replacementChar
      inc i
    else:
      result.add s[i ..< i + n]
      i += n

func completeLen*(s: string): int =
  ## How much of `s` can be cut off now: a trailing *incomplete* sequence (the read ended in the middle of a character)
  ## is left for the next read instead of being mistaken for bad bytes.
  result = s.len
  var back = 1
  while back <= 3 and s.len - back >= 0:
    let b = ord(s[s.len - back])
    if b in 0x80 .. 0xBF: inc back                     # continuation byte: look further back for its lead
    else:
      if b >= 0xC2 and seqLen(s, s.len - back) == 0:   # a lead byte whose sequence does not fit in what we have
        let need = (if b < 0xE0: 2 elif b < 0xF0: 3 else: 4)
        if need > back and b <= 0xF4: result = s.len - back
      break

func charBoundary*(s: string; at: int): int =
  ## The largest cut position <= `at` that does not fall inside a multi-byte character (a truncated record stays valid).
  result = at
  var back = 0
  while result > 0 and result < s.len and ord(s[result]) in 0x80 .. 0xBF and back < 3:
    dec result
    inc back
  if result < 0 or (result < s.len and ord(s[result]) in 0x80 .. 0xBF): result = at   # not UTF-8 at all: cut where asked

func record*(b: Builder; ln: uint64; wallMs: int64; msg: string): string =
  "{\"_msg\":" & escapeJson(msg) & ",\"_time\":" & $(b.baseMs + int64(ln)) & ",\"ln\":" & $ln &
    ",\"ts\":" & $wallMs & ",\"job\":" & escapeJson(b.job) & ",\"run\":" & escapeJson(b.run) & "}\n"

func newBuilder*(job, run: string; baseMs: int64; secrets: seq[string] = @[]; variants = true;
                 minLen = defaultMinLen; maxBytes = 0'i64): Builder =
  result = Builder(job: job, run: run, baseMs: baseMs, masker: newMasker(minLen, variants), maxBytes: maxBytes,
                   nextSeq: 1, nextLn: 0, blockFirstLn: 0)
  result.masker.add secrets

func addSecrets*(b: var Builder; values: openArray[string]) =
  ## Values the build registered while running ($CICD_MASK): they protect every line cut from now on.
  b.masker.add values


proc cut(b: var Builder): seq[LogBlock] =
  if b.rawLines == 0: return
  result.add LogBlock(seq: b.nextSeq, firstLn: b.blockFirstLn, lines: b.rawLines, encoding: encGzip,
                      data: compress(b.raw, BestSpeed, dfGzip))
  inc b.nextSeq
  b.raw.setLen(0)
  b.rawLines = 0
  b.blockFirstLn = b.nextLn

proc addLine(b: var Builder; text: string; wallMs: int64; newline = true) =
  if b.truncated:
    inc b.droppedLines                      # past the limit: read and counted, never stored
    return
  b.bytesIn += int64(text.len) + 1
  if b.maxBytes > 0 and b.bytesIn > b.maxBytes:
    # the limit of this step's log: one marker line says so, everything after it is dropped (the build keeps running and
    # its pipe keeps draining - the log is bounded, the step is not)
    b.truncated = true
    inc b.droppedLines
    b.raw.add b.record(b.nextLn, wallMs, "[cicd: log truncated - this step's log reached its limit of " & $b.maxBytes &
      " bytes; the rest of the output is not stored]")
    inc b.rawLines
    inc b.nextLn
    return
  var line = b.masker.mask(text)
  if line.endsWith('\r'): line.setLen(line.len - 1)       # CRLF and progress-bar redraws
  line = safeText(line)
  var i = 0
  while true:
    let cutAt = if line.len - i > maxLineBytes: max(i + 1, charBoundary(line, i + maxLineBytes)) else: line.len
    b.raw.add b.record(b.nextLn, wallMs, line[i ..< cutAt])     # a long line is split between characters, never inside one
    inc b.rawLines
    inc b.nextLn
    i = cutAt
    if i >= line.len: break

proc feed*(b: var Builder; data: string; wallMs: int64): seq[LogBlock] =
  ## Raw bytes of the step's output -> finished blocks (usually none, a block is cut every ~64 KiB of records).
  b.carry.add data
  var start = 0
  while true:
    let nl = b.carry.find('\n', start)
    if nl < 0: break
    b.addLine(b.carry[start ..< nl], wallMs)
    start = nl + 1
    if b.raw.len >= blockRawTarget: result.add b.cut()
  b.carry = b.carry[start .. ^1]
  if b.carry.len > maxLineBytes * 4:        # a runaway line without newline must not grow memory without bound
    let n = completeLen(b.carry)            # ... but a character cut in half by the read waits for its other half
    b.addLine(b.carry[0 ..< n], wallMs, newline = false)
    b.carry = b.carry[n .. ^1]

proc flush*(b: var Builder; wallMs: int64; final = false): seq[LogBlock] =
  ## Cut what is pending even though the block is small (a quiet step still shows its lines within about a second).
  ## `final` also emits the last line that never got a newline.
  if final and b.carry.len > 0:
    b.addLine(b.carry, wallMs, newline = false)
    b.carry.setLen(0)
  b.cut()

func linesWritten*(b: Builder): uint64 = b.nextLn

# ------------------------------------------------------------------ spool files

proc blockFile(dir: string; blk: LogBlock): string =
  dir / (align($blk.seq, 12, '0') & "-" & $blk.firstLn & "-" & $blk.lines & "-" & blk.encoding & ".blk")

proc initSpool*(dir: string) =
  createDir(dir)
  for f in walkFiles(dir / "*"): removeFile(f)             # nothing of an earlier run is ever resumed
  spoolBytes.store(0)

proc fits*(cap: int64; blk: LogBlock): bool =
  ## Always true for an empty spool, otherwise one block larger than the cap could never be written.
  let used = spoolBytes.load
  used == 0 or used + blk.data.len.int64 <= cap

proc add*(dir: string; blk: LogBlock) =
  let path = blockFile(dir, blk)
  writeFile(path & ".tmp", blk.data)                        # the sender must never see a half-written block
  moveFile(path & ".tmp", path)
  discard spoolBytes.fetchAdd(blk.data.len.int64)

type Queued* = object
  path*: string
  blk*: LogBlock

proc parseName(path: string): LogBlock =
  let parts = splitFile(path).name.split('-')              # 000000000001-0-3-gzip
  LogBlock(seq: parseUInt(parts[0]), firstLn: parseUInt(parts[1]), lines: uint32(parseUInt(parts[2])), encoding: parts[3])

proc peek*(dir: string; maxBlocks = 16; maxBytes = 128 * 1024): seq[Queued] =
  ## The oldest queued blocks, in `seq` order, up to the batch limits (always at least one when any exists).
  var names: seq[string]
  for f in walkFiles(dir / "*.blk"): names.add f
  names.sort()
  var bytes = 0
  for f in names:
    var q = Queued(path: f, blk: parseName(f))
    q.blk.data = readFile(f)
    if result.len > 0 and (result.len >= maxBlocks or bytes + q.blk.data.len > maxBytes): break
    bytes += q.blk.data.len
    result.add q

proc remove*(q: Queued) =
  removeFile(q.path)
  discard spoolBytes.fetchSub(q.blk.data.len.int64)

proc isEmpty*(dir: string): bool =
  for f in walkFiles(dir / "*.blk"): return false
  true
