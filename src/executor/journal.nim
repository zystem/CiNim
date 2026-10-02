## Append-only run journal with a SHA-256 hash chain (PIP-003, tests: hash-chain).

import std/[base64, strutils, os]
import checksums/sha2

proc fsync(fd: cint): cint {.importc, header: "<unistd.h>".}

type
  Entry* = object
    seq*: int
    kind*, payload*, result*: string
    hash*: string  ## hex SHA-256 over the previous hash and this entry

  Journal* = object
    entries*: seq[Entry]

proc sha256hex(data: string): string =
  let d = secureHash(Sha_256, data)
  for c in d: result.add toHex(ord(c), 2).toLowerAscii

proc entryHash(prev: string; e: Entry): string =
  # Length-prefixed fields: no ambiguity between adjacent values.
  var buf = prev
  for f in [$e.seq, e.kind, e.payload, e.result]:
    buf.add $f.len & ":" & f & ";"
  sha256hex(buf)

proc tipHash*(j: Journal): string =
  if j.entries.len == 0: "" else: j.entries[^1].hash

proc append*(j: var Journal; kind, payload, res: string): Entry =
  result = Entry(seq: j.entries.len, kind: kind, payload: payload, result: res)
  result.hash = entryHash(j.tipHash, result)
  j.entries.add result

proc verify*(j: Journal): bool =
  var prev = ""
  for i, e in j.entries:
    if e.seq != i or e.hash != entryHash(prev, e): return false
    prev = e.hash
  true

proc appendToFile*(path: string; e: Entry) =
  ## One line per entry, flushed and fsync'd so a killed process loses at most the call in flight.
  let f = open(path, fmAppend)
  defer: f.close()
  f.writeLine([$e.seq, e.kind, encode(e.payload), encode(e.result), e.hash].join("\t"))
  f.flushFile()
  discard fsync(cint(f.getFileHandle))

proc loadJournal*(path: string): Journal =
  if not fileExists(path): return
  for line in lines(path):
    let p = line.split('\t')
    if p.len != 5: break  # torn last line after a kill: ignore
    result.entries.add Entry(seq: parseInt(p[0]), kind: p[1], payload: decode(p[2]),
                             result: decode(p[3]), hash: p[4])
