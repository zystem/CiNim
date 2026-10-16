## Keeping the nodes of the store alike (docs/store.md, D-57). The database knows every object that should exist (`artifacts`, `caches`: key, size, state), so the repair is a comparison
## of the database with the nodes, and a queue for what is known to have been missed:
##   * `store_repair` holds what a node has to be given (`copy`) or to lose (`delete`) for a key; the last operation on a key and a node wins, so a stale `delete` is replaced by the
##     `copy` of a later write. A task that fails is tried again later, with a pause that doubles up to an hour.
##   * `repairPass` does the due tasks: a `copy` reads the object from a node that has it and writes it to the one that has not, checked by SHA-256 (core/zstore.nim `copyObject`);
##     a `delete` deletes; a `copy` of an object that is no longer in the database is dropped (the sweep deleted it).
##   * `checkNodes` takes a slice of the rows `stored` of `artifacts` and `caches`, asks every node for the size and makes a `copy` task of what is missing or differs. This is what puts
##     a node whose disk was lost back in order, and it needs nothing of the nodes but `size`.
import std/[json, strutils, times, sequtils]
import ../common/rqlite
import storagebackend, zstore

const
  maxPause = 3600
  checkSlice* = 200

proc noteMissed*(c: var RqClient; key, node, op: string; now: int64) =
  ## a node did not take a write or a delete; the last operation on this key and node is the one that stands
  discard c.execute(%*[["INSERT INTO store_repair (key, node, op, since, attempts, next_at, last_error) VALUES (?, ?, ?, ?, 0, 0, '') " &
    "ON CONFLICT(key, node) DO UPDATE SET op = excluded.op, since = excluded.since, attempts = 0, next_at = 0, last_error = ''", key, node, op, now]])

proc pendingRepairs*(c: var RqClient): int =
  c.query(%*[["SELECT count(*) FROM store_repair"]])["results"][0]{"values"}[0][0].getInt

proc inDatabase(c: var RqClient; key: string): bool =
  let v = c.query(%*[["SELECT (SELECT count(*) FROM artifacts WHERE s3_key = ?) + (SELECT count(*) FROM caches WHERE s3_key = ?)", key, key]])["results"][0]{"values"}[0][0].getInt
  v > 0

proc settle(c: var RqClient; key, node: string; done: bool; attempts: int; now: int64; err: string) =
  if done:
    discard c.execute(%*[["DELETE FROM store_repair WHERE key = ? AND node = ?", key, node]])
  else:
    let pause = min(maxPause, 30 * (1 shl min(attempts, 7)))
    discard c.execute(%*[["UPDATE store_repair SET attempts = attempts + 1, next_at = ?, last_error = ? WHERE key = ? AND node = ?", now + pause, err[0 ..< min(err.len, 200)], key, node]])

type RepairReport* = object
  copied*, deleted*, dropped*, failed*: int

proc repairPass*(c: var RqClient; b: MirrorBackend; now: int64; batch = 50): RepairReport =
  ## the due tasks, at most `batch`
  let rows = c.query(%*[["SELECT key, node, op, attempts FROM store_repair WHERE next_at <= ? ORDER BY since LIMIT ?", now, batch]])["results"][0]{"values"}
  if rows == nil: return
  for row in rows:
    let key = row[0].getStr
    let node = row[1].getStr
    let attempts = row[3].getInt
    let target = b.nodeNamed(node)
    if target == nil:                                   # the node is not in the settings any more
      c.settle(key, node, true, attempts, now, "")
      inc result.dropped
      continue
    if row[2].getStr == "delete":
      let r = target.nodeDelete(key)
      c.settle(key, node, r.ok, attempts, now, r.error)
      if r.ok: inc result.deleted else: inc result.failed
      continue
    if not c.inDatabase(key):
      # the object is gone from the database meanwhile (swept, or the write never became a row): there is nothing to give the node
      c.settle(key, node, true, attempts, now, "")
      inc result.dropped
      continue
    var source: ZNode
    for n in b.nodes:
      if n.name == node: continue
      let sz = n.nodeSize(key)
      if sz.reply.ok:
        source = n
        break
    if source == nil:
      c.settle(key, node, false, attempts, now, "no other node has the object")
      inc result.failed
      continue
    let r = copyObject(source, target, key)
    c.settle(key, node, r.ok, attempts, now, r.error)
    if r.ok: inc result.copied else: inc result.failed

proc checkNodes*(c: var RqClient; b: MirrorBackend; cursor: var string; now: int64; slice = checkSlice): int =
  ## The rows `stored` after `cursor` (a key), `slice` of them from `artifacts` and `caches` together: every node is asked the size, and a node that lacks the object or has another size
  ## gets a `copy` task. `cursor` is left at the last key looked at, "" when the end was reached. Returns the number of tasks made.
  if b.nodes.len < 2: return 0
  let rows = c.query(%*[["SELECT s3_key, size FROM (SELECT s3_key, size FROM artifacts WHERE state = 'stored' UNION ALL SELECT s3_key, size FROM caches WHERE state = 'stored') " &
    "WHERE s3_key > ? ORDER BY s3_key LIMIT ?", cursor, slice]])["results"][0]{"values"}
  if rows == nil or rows.len == 0:
    cursor = ""
    return
  for row in rows:
    let key = row[0].getStr
    let size = row[1].getBiggestInt
    cursor = key
    var have: seq[bool]
    for n in b.nodes:
      let r = n.nodeSize(key)
      have.add r.reply.ok and r.size == size
    if have.anyIt(it):                                    # some node has it right: the others are brought up to it
      for i, n in b.nodes:
        if not have[i]:
          c.noteMissed(key, n.name, "copy", now)
          inc result
    # nobody has it right: nothing to copy from; the object is lost or being written (the sweep and the owner of the row decide)
  if rows.len < slice: cursor = ""
