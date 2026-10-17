## Keeping the nodes of a mirrored store alike (docs/store.md, D-57, D-58; docs/storage-module.md). The module's inventory (`storage_objects`: every object it accepted, with its size) knows what
## should exist, so the repair is a comparison of the inventory with the nodes, and a queue for what is known to have been missed:
##   * `storage_repair` holds what a node has to be given (`copy`) or to lose (`delete`) for a key of a store; the last operation on a key and a node wins, so a stale `delete` is replaced by the
##     `copy` of a later write. A task that fails is tried again later, with a pause that doubles up to an hour.
##   * `repairPass` does the due tasks: a `copy` reads the object from a node that has it and writes it to the one that has not, checked by SHA-256 (storage/httpstore.nim `copyBetween`);
##     a `delete` deletes; a `copy` of an object that is no longer in the inventory is dropped (it was deleted meanwhile).
##   * `checkNodes` takes a slice of the inventory of the store, asks every node for the size and makes a `copy` task of what is missing or differs. This is what puts a node whose disk was lost
##     back in order, and it needs nothing of the nodes but `size`.
##   * `tryLease` lets one replica of the module at a time do these passes (a row of `storage_lease` that the holder renews).
import std/[json, strutils, sequtils]
import ../common/[rqlite, storagebackend]
import replicas

const
  maxPause = 3600
  checkSlice* = 200
  leaseSeconds* = 120

# ------------------------------------------------------------------ the inventory

proc recordObject*(c: var RqClient; store, key: string; size: int64; now: int64) =
  discard c.execute(%*[["INSERT INTO storage_objects (store, key, size, written_at) VALUES (?, ?, ?, ?) ON CONFLICT(store, key) DO UPDATE SET size = excluded.size, written_at = excluded.written_at",
                        store, key, size, now]])

proc forgetObject*(c: var RqClient; store, key: string) =
  discard c.execute(%*[["DELETE FROM storage_objects WHERE store = ? AND key = ?", store, key]])

proc inInventory(c: var RqClient; store, key: string): bool =
  c.query(%*[["SELECT count(*) FROM storage_objects WHERE store = ? AND key = ?", store, key]])["results"][0]{"values"}[0][0].getInt > 0

# ------------------------------------------------------------------ the parts a shim sent directly (D-61)

proc recordPart*(c: var RqClient; store, key, upload: string; part: int; sha256: string; size: int64; now: int64) =
  discard c.execute(%*[["INSERT INTO storage_parts (store, key, upload, part, sha256, size, written_at) VALUES (?, ?, ?, ?, ?, ?, ?) " &
    "ON CONFLICT(store, key, upload, part) DO UPDATE SET sha256 = excluded.sha256, size = excluded.size, written_at = excluded.written_at", store, key, upload, part, sha256, size, now]])

proc partsOf*(c: var RqClient; store, key, upload: string): seq[tuple[part: int, sha256: string, size: int64]] =
  let v = c.query(%*[["SELECT part, sha256, size FROM storage_parts WHERE store = ? AND key = ? AND upload = ? ORDER BY part", store, key, upload]])["results"][0]{"values"}
  if v != nil:
    for row in v: result.add (row[0].getInt, row[1].getStr, row[2].getBiggestInt)

proc forgetParts*(c: var RqClient; store, key, upload: string) =
  discard c.execute(%*[["DELETE FROM storage_parts WHERE store = ? AND key = ? AND upload = ?", store, key, upload]])

# ------------------------------------------------------------------ the queue

proc noteMissed*(c: var RqClient; store, key, node, op: string; now: int64) =
  ## a node did not take a write or a delete; the last operation on this key and node is the one that stands
  discard c.execute(%*[["INSERT INTO storage_repair (store, key, node, op, since, attempts, next_at, last_error) VALUES (?, ?, ?, ?, ?, 0, 0, '') " &
    "ON CONFLICT(store, key, node) DO UPDATE SET op = excluded.op, since = excluded.since, attempts = 0, next_at = 0, last_error = ''", store, key, node, op, now]])

proc pendingRepairs*(c: var RqClient; store = ""): int =
  if store.len == 0: c.query(%*[["SELECT count(*) FROM storage_repair"]])["results"][0]{"values"}[0][0].getInt
  else: c.query(%*[["SELECT count(*) FROM storage_repair WHERE store = ?", store]])["results"][0]{"values"}[0][0].getInt

proc settle(c: var RqClient; store, key, node: string; done: bool; attempts: int; now: int64; err: string) =
  if done:
    discard c.execute(%*[["DELETE FROM storage_repair WHERE store = ? AND key = ? AND node = ?", store, key, node]])
  else:
    let pause = min(maxPause, 30 * (1 shl min(attempts, 7)))
    discard c.execute(%*[["UPDATE storage_repair SET attempts = attempts + 1, next_at = ?, last_error = ? WHERE store = ? AND key = ? AND node = ?",
                          now + pause, err[0 ..< min(err.len, 200)], store, key, node]])

type RepairReport* = object
  copied*, deleted*, dropped*, failed*: int

proc repairPass*(c: var RqClient; store: string; b: ReplicaBackend; now: int64; batch = 50): RepairReport =
  ## the due tasks of the store, at most `batch`
  let rows = c.query(%*[["SELECT key, node, op, attempts FROM storage_repair WHERE store = ? AND next_at <= ? ORDER BY since LIMIT ?", store, now, batch]])["results"][0]{"values"}
  if rows == nil: return
  for row in rows:
    let key = row[0].getStr
    let node = row[1].getStr
    let attempts = row[3].getInt
    let target = b.indexOf(node)
    if target < 0:                                      # the node is not in the settings any more
      c.settle(store, key, node, true, attempts, now, "")
      inc result.dropped
      continue
    if row[2].getStr == "delete":
      let r = b.deleteOn(target, key)
      c.settle(store, key, node, r.ok, attempts, now, r.error)
      if r.ok: inc result.deleted else: inc result.failed
      continue
    if not c.inInventory(store, key):
      # the object is gone from the inventory meanwhile (deleted, or the write never became an object): there is nothing to give the node
      c.settle(store, key, node, true, attempts, now, "")
      inc result.dropped
      continue
    var source = -1
    for i in 0 ..< b.nodeNames().len:
      if i == target: continue
      if b.sizeOn(i, key).ok:
        source = i
        break
    if source < 0:
      c.settle(store, key, node, false, attempts, now, "no other node has the object")
      inc result.failed
      continue
    let r = b.copyBetween(source, target, key)
    c.settle(store, key, node, r.ok, attempts, now, r.error)
    if r.ok: inc result.copied else: inc result.failed

proc checkNodes*(c: var RqClient; store: string; b: ReplicaBackend; cursor: var string; now: int64; slice = checkSlice): int =
  ## The objects of the store after `cursor` (a key), `slice` of them: every node is asked the size, and a node that lacks the object or has another size gets a `copy` task. `cursor` is left at
  ## the last key looked at, "" when the end was reached. Returns the number of tasks made.
  let names = b.nodeNames()
  if names.len < 2: return 0
  let rows = c.query(%*[["SELECT key, size FROM storage_objects WHERE store = ? AND key > ? ORDER BY key LIMIT ?", store, cursor, slice]])["results"][0]{"values"}
  if rows == nil or rows.len == 0:
    cursor = ""
    return
  for row in rows:
    let key = row[0].getStr
    let size = row[1].getBiggestInt
    cursor = key
    var have: seq[bool]
    for i in 0 ..< names.len:
      let r = b.sizeOn(i, key)
      have.add r.ok and (size < 0 or r.size == size)       # size -1: the object was completed by parts and its size was not known to the inventory
    if have.anyIt(it):                                    # some node has it right: the others are brought up to it
      for i, name in names:
        if not have[i]:
          c.noteMissed(store, key, name, "copy", now)
          inc result
    # nobody has it right: nothing to copy from; the object is lost or being written
  if rows.len < slice: cursor = ""

# ------------------------------------------------------------------ the lease

proc tryLease*(c: var RqClient; name, holder: string; now: int64): bool =
  ## true if `holder` holds the lease `name` now: it took it free or expired, or it held it already (and the hold is renewed for `leaseSeconds`)
  let r = c.execute(%*[["INSERT INTO storage_lease (name, holder, until) VALUES (?, ?, ?) ON CONFLICT(name) DO UPDATE SET holder = excluded.holder, until = excluded.until " &
    "WHERE storage_lease.holder = excluded.holder OR storage_lease.until < ?", name, holder, now + leaseSeconds, now]])
  r["results"][0]{"rows_affected"}.getInt > 0
