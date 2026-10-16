## NOT SWITCHED ON: written and tested, but not called by the core and not offered by the API. The owner put it off until after the UI (2026-10-15). Known gaps to close first:
## the pass copies at most `perPass` steps every ten minutes (far too slow for a hold on a big organisation); a log store that does not answer looks like an empty window, so after
## the wait an empty copy marked incomplete is made and never tried again; only the newest attempt of a step is copied. To switch it on: call `keepHeldLogs` from the watchdog's
## sweep (core/main.nim) with a `LogReader` over `Core.getStepLog`, and add the two routes `GET /api/v1/runs/{id}/held-logs[/{step}]` (see `keptLogs`).
## The logs of held runs (DAT-006): a legal hold has to keep the log too, and the log store (VictoriaLogs) drops whole days by its own period (DAT-008). So while a run is under a hold
## (its own, its group's or the organisation's, core/holds.nim) the core copies the log of each of its steps that has ended into the object store, once, as
## `heldlogs/<tenant>/<run>/<ordinal>-<attempt>.log` (the lines as the build wrote them, one per line). The copy is read through the same window as the API's (`getStepLog`), in blocks, and
## written as a multipart upload, so a log of any size takes a block of memory. A step whose log is not all stored yet (the store makes a record readable a second or two after the
## collector's acknowledgement, and a drain may bring lines late) is looked at again in the next pass; after `waitComplete` it is copied as it is and the record says `complete` false.
## When the hold is released the copies go with the next pass. What is not copied: the journal, and the logs of steps that ended before the hold was placed and have been dropped by the
## log store already (the copy is made from what is there).
import std/[json, strutils, times]
import ../common/[rqlite, states]
import storagebackend, holds

const
  waitComplete* = 3600'i64       ## seconds after a step ended that a log that is not complete waits to become so, before it is copied as it is
  perPass* = 20                  ## steps looked at in one pass
  maxLogWindow* = 500

type
  LogWindow* = object
    found*: bool                 ## the step has a log stream
    lines*: seq[string]
    next*: int                   ## the line to ask for next
    total*: int                  ## how many lines the shim says the step wrote (-1: nothing yet)
    complete*: bool
  LogReader* = proc (runId: string; ordinal, first: int): LogWindow {.gcsafe.}

  KeepReport* = object
    kept*, pending*, failed*, released*: int

func logKey*(tenant, run: string; ordinal, attempt: int): string =
  "heldlogs/" & tenant & "/" & run & "/" & $ordinal & "-" & $attempt & ".log"

func finalSteps(): string =
  for i, s in [ssSucceeded, ssFailed, ssCanceled, ssTimedOut, ssLost]:
    result.add (if i == 0: "'" else: ",'") & protoName(s) & "'"

type Candidate = tuple[run, tenant: string; ordinal, attempt: int; endedAt: int64]

proc candidates(c: var RqClient): seq[Candidate] =
  let v = c.query(%*[["SELECT s.run_id, r.tenant_id, s.ordinal, s.attempt, COALESCE(CAST(s.finished_at AS INTEGER), 0) FROM steps s JOIN runs r ON r.id = s.run_id " &
    "WHERE s.state IN (" & finalSteps() & ") AND " & heldRunSql("r.id", "r.tenant_id", "r.group_id") & " AND NOT EXISTS (SELECT 1 FROM held_logs l WHERE l.run_id = s.run_id AND " &
    "l.ordinal = s.ordinal AND l.attempt = s.attempt) ORDER BY s.finished_at LIMIT ?", perPass]])["results"][0]{"values"}
  if v != nil:
    for row in v: result.add (row[0].getStr, row[1].getStr, row[2].getInt, row[3].getInt, row[4].getBiggestInt)

type Keep = enum kDone, kPending, kFailed

proc keepOne(c: var RqClient; be: ObjectBackend; read: LogReader; cd: Candidate; now: int64): Keep =
  let key = logKey(cd.tenant, cd.run, cd.ordinal, cd.attempt)
  var w = read(cd.run, cd.ordinal, 0)
  if not w.found:
    # no log stream: the step wrote no log (or it was never opened); nothing to keep, and the row says it was looked at
    discard c.execute(%*[["INSERT OR IGNORE INTO held_logs (run_id, ordinal, attempt, tenant_id, s3_key, size, line_count, complete, created_at) VALUES (?, ?, ?, ?, '', 0, 0, 1, ?)",
      cd.run, cd.ordinal, cd.attempt, cd.tenant, now]])
    return kDone
  if not w.complete and now - cd.endedAt < waitComplete: return kPending
  var first = 0
  var buf = ""
  var size = 0'i64
  var lineCount = 0
  var uploadId = ""
  var parts: seq[(int, string)]
  proc abortUpload() =
    if uploadId.len > 0: discard be.abortMultipart(key, uploadId)
  proc flush(): bool =
    if uploadId.len == 0:
      let mp = be.createMultipart(key)
      if not mp.res.ok: return false
      uploadId = mp.uploadId
    let p = be.uploadPart(key, uploadId, parts.len + 1, buf)
    if not p.res.ok: return false
    parts.add (parts.len + 1, p.etag)
    size += buf.len
    buf.setLen 0
    true
  while true:
    for l in w.lines:
      buf.add l
      buf.add '\n'
      inc lineCount
      if buf.len >= partSize and not flush():
        abortUpload()
        return kFailed
    first = w.next
    if w.lines.len == 0 or (w.total >= 0 and first >= w.total): break
    w = read(cd.run, cd.ordinal, first)
    if not w.found: break
  if uploadId.len == 0:
    let put = be.putObject(key, buf)
    if not put.ok: return kFailed
    size = buf.len
  else:
    if buf.len > 0 and not flush():
      abortUpload()
      return kFailed
    let done = be.completeMultipart(key, uploadId, parts)
    if not done.ok:
      abortUpload()
      return kFailed
  discard c.execute(%*[["INSERT OR REPLACE INTO held_logs (run_id, ordinal, attempt, tenant_id, s3_key, size, line_count, complete, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    cd.run, cd.ordinal, cd.attempt, cd.tenant, key, size, lineCount, (if w.total < 0 or lineCount >= w.total: 1 else: 0), now]])
  kDone

proc dropObject(be: ObjectBackend; key: string): bool =
  let r = be.deleteObject(key)
  r.ok or (not r.retry and "no such object" in r.error.toLowerAscii)

proc keepHeldLogs*(c: var RqClient; be: ObjectBackend; read: LogReader; now: int64): KeepReport =
  ## one pass: the logs of the steps of held runs that have ended are copied, and the copies of runs that are not held any more are deleted
  for cd in c.candidates():
    case c.keepOne(be, read, cd, now)
    of kDone: inc result.kept
    of kPending: inc result.pending
    of kFailed: inc result.failed
  let gone = c.query(%*[["SELECT l.run_id, l.ordinal, l.attempt, l.s3_key FROM held_logs l LEFT JOIN runs r ON r.id = l.run_id WHERE r.id IS NULL OR NOT " &
    heldRunSql("r.id", "r.tenant_id", "r.group_id") & " LIMIT ?", perPass]])["results"][0]{"values"}
  if gone != nil:
    for row in gone:
      if row[3].getStr.len == 0 or dropObject(be, row[3].getStr):
        discard c.execute(%*[["DELETE FROM held_logs WHERE run_id = ? AND ordinal = ? AND attempt = ?", row[0].getStr, row[1].getInt, row[2].getInt]])
        inc result.released
      else: inc result.failed

type KeptLog* = object
  ordinal*, attempt*, lines*: int
  size*: int64
  complete*: bool
  key*: string

proc keptLogs*(c: var RqClient; runId: string): seq[KeptLog] =
  let v = c.query(%*[["SELECT ordinal, attempt, line_count, size, complete, s3_key FROM held_logs WHERE run_id = ? AND s3_key != '' ORDER BY ordinal, attempt", runId]])["results"][0]{"values"}
  if v != nil:
    for row in v: result.add KeptLog(ordinal: row[0].getInt, attempt: row[1].getInt, lines: row[2].getInt, size: row[3].getBiggestInt, complete: row[4].getInt == 1, key: row[5].getStr)

func view*(k: KeptLog): JsonNode =
  %*{"step": k.ordinal, "attempt": k.attempt, "lines": k.lines, "bytes": k.size, "complete": k.complete}
