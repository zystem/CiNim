## DAT-006: the log of a step of a held run is copied into the object store (core/heldlogs.nim), against a real rqlite and a store in memory, with a log reader of our own in place of
## VictoriaLogs: copied once the step has ended and its log is all stored, in blocks, whatever the size; waited for while lines are missing, copied as it is after the wait; and the copy
## goes when the hold is released. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, tables, strutils, times]
import common/rqlite
import common/storagebackend
import core/[schema, scheduler, holds, groups, heldlogs]

type MemStore = ref object of ObjectBackend
  objects: Table[string, string]
  uploads: Table[string, tuple[key: string, parts: Table[int, string]]]
  next, multiparts: int

method putObject(b: MemStore; key, data: string): Outcome =
  b.objects[key] = data
  done()
method createMultipart(b: MemStore; key: string): tuple[res: Outcome, uploadId: string] =
  inc b.next
  let id = "up" & $b.next
  b.uploads[id] = (key, initTable[int, string]())
  (done(), id)
method uploadPart(b: MemStore; key, uploadId: string; part: int; data: string): tuple[res: Outcome, etag: string] =
  b.uploads[uploadId].parts[part] = data
  (done(), "etag" & $part)
method completeMultipart(b: MemStore; key, uploadId: string; parts: seq[(int, string)]): Outcome =
  var all = ""
  for (n, _) in parts: all.add b.uploads[uploadId].parts[n]
  b.objects[key] = all
  b.uploads.del uploadId
  inc b.multiparts
  done()
method abortMultipart(b: MemStore; key, uploadId: string): Outcome =
  b.uploads.del uploadId
  done()
method readRange(b: MemStore; key: string; offset, length: int64): tuple[res: Outcome, data: string] =
  if key notin b.objects: return (fail("no such object"), "")
  (done(), b.objects[key][int(offset) ..< int(min(offset + length, b.objects[key].len))])
method deleteObject(b: MemStore; key: string): Outcome =
  if key notin b.objects: return fail("no such object")
  b.objects.del key
  done()

let url = getEnv("CINIM_RQLITE_URL")

# the logs the reader serves: run -> ordinal -> (lines, whether the store has all of them)
var logs = initTable[string, tuple[lines: seq[string], stored: int]]()
proc reader(runId: string; ordinal, first: int): LogWindow {.gcsafe.} =
  {.cast(gcsafe).}:
    let k = runId & "/" & $ordinal
    if k notin logs: return
    let l = logs[k]
    result.found = true
    result.total = l.lines.len
    let upTo = min(l.stored, l.lines.len)
    for i in first ..< min(upTo, first + maxLogWindow): result.lines.add l.lines[i]
    result.next = first + result.lines.len
    result.complete = upTo >= l.lines.len

suite "DAT-006 the logs of held runs":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let sfx = newId()[^6 .. ^1].toLowerAscii
    var n = 0
    let now = getTime().toUnix()
    proc newOrg(): tuple[id, profile: string] =
      inc n
      let id = c.addOrganization("l" & $n & sfx, "L")
      (id, c.ensureOrganizationProfile(id, "cinim-001-l" & $n & sfx))
    proc runWithStep(o: tuple[id, profile: string]; lines: seq[string]; stored: int; ordinal = 0; endedAgo = 10'i64; groupId = ""): string =
      result = co.createRun("return 1", o.id, o.profile, groupId = groupId)
      let jobId = newId()
      discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, 'job-1', 'OK', ?)", jobId, result, o.profile]])
      discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at, attempt, finished_at) " &
        "VALUES (?, ?, ?, ?, 'sh', 'OK', ?, 'alpine', 'true', '', '1', 1, ?)", newId(), result, jobId, ordinal, o.profile, $(now - endedAgo)]])
      logs[result & "/" & $ordinal] = (lines, stored)

    test "a step of a held run is copied once, lines in order, and not before the hold; an unheld run is left":
      let o = newOrg()
      let be = MemStore(objects: initTable[string, string]())
      let lines = @["one", "two", "three"]
      let held = o.runWithStep(lines, lines.len)
      let free = o.runWithStep(lines, lines.len)
      check c.keepHeldLogs(be, reader, now).kept == 0
      check c.placeHold(held, o.id, "case 1", "ann", now).placed
      let rep = c.keepHeldLogs(be, reader, now)
      check rep.kept == 1 and rep.failed == 0
      let key = logKey(o.id, held, 0, 1)
      check be.objects[key] == "one\ntwo\nthree\n"
      check (logKey(o.id, free, 0, 1)) notin be.objects
      let kept = c.keptLogs(held)
      check kept.len == 1 and kept[0].lines == 3 and kept[0].complete and kept[0].size == 14
      check c.keepHeldLogs(be, reader, now).kept == 0               # once
    test "a log of any size goes through a multipart upload in blocks and comes back whole":
      let o = newOrg()
      let be = MemStore(objects: initTable[string, string]())
      var lines: seq[string]
      for i in 0 ..< 3000: lines.add "line " & $i & " " & 'x'.repeat(4000)          # about 12 MB, three blocks of 8 MiB at most
      let r = o.runWithStep(lines, lines.len)
      check c.placeHold(r, o.id, "big", "ann", now).placed
      check c.keepHeldLogs(be, reader, now).kept == 1
      check be.multiparts == 1
      let got = be.objects[logKey(o.id, r, 0, 1)]
      check got.splitLines.len == 3001 and got.startsWith("line 0 ") and got.endsWith("x\n")
      check c.keptLogs(r)[0].lines == 3000
    test "a log that is not all stored waits, and is copied as it is, marked incomplete, after the wait":
      let o = newOrg()
      let be = MemStore(objects: initTable[string, string]())
      let lines = @["a", "b", "c", "d"]
      let fresh = o.runWithStep(lines, 2, endedAgo = 10)
      let old = o.runWithStep(lines, 2, endedAgo = waitComplete + 5)
      check c.placeHold(fresh, o.id, "x", "ann", now).placed and c.placeHold(old, o.id, "x", "ann", now).placed
      let rep = c.keepHeldLogs(be, reader, now)
      check rep.pending == 1 and rep.kept == 1
      check c.keptLogs(fresh).len == 0
      let k = c.keptLogs(old)
      check k.len == 1 and not k[0].complete and k[0].lines == 2
      logs[fresh & "/0"] = (lines, 4)                                # the rest arrives
      check c.keepHeldLogs(be, reader, now).kept == 1
      check c.keptLogs(fresh)[0].complete and be.objects[logKey(o.id, fresh, 0, 1)] == "a\nb\nc\nd\n"
    test "the log of a run under the hold of its group is kept, and the copy goes when the hold is released":
      let o = newOrg()
      let be = MemStore(objects: initTable[string, string]())
      discard c.createGroup(o.id, "legal", now)
      let g = c.groupIdOf(o.id, "legal").id
      let r = o.runWithStep(@["x"], 1, groupId = g)
      check c.placeScopeHold(o.id, g, "audit", "ann", now).placed
      check c.keepHeldLogs(be, reader, now).kept == 1
      check logKey(o.id, r, 0, 1) in be.objects
      check c.releaseScopeHold(o.id, g)
      let rep = c.keepHeldLogs(be, reader, now)
      check rep.released == 1 and logKey(o.id, r, 0, 1) notin be.objects and c.keptLogs(r).len == 0
    test "a step with no log stream keeps nothing and is not looked at again":
      let o = newOrg()
      let be = MemStore(objects: initTable[string, string]())
      let r = o.runWithStep(@[], 0)
      logs.del r & "/0"
      check c.placeHold(r, o.id, "x", "ann", now).placed
      check c.keepHeldLogs(be, reader, now).kept == 1
      check be.objects.len == 0 and c.keptLogs(r).len == 0
      check c.keepHeldLogs(be, reader, now).kept == 0
