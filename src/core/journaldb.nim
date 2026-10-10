## The run journal in the database, with its hash chain (T-03; the chain itself is core/journalchain.nim). Only the core writes it: one lock for
## all the threads of the core, so that the hash of a new row is computed from the newest row that is really there. The newest hash is kept
## with the run (`runs.journal_tip`) in the same transaction.
import std/[json, locks, times]
import ../common/rqlite
import journalchain

var journalLock: Lock
initLock(journalLock)

proc readRows*(c: var RqClient; runId: string): seq[Row] =
  let r = c.query(%*[["SELECT seq, kind, payload, result, hash FROM run_journal WHERE run_id = ? AND seq >= 0 ORDER BY seq", runId]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for v in vals:
      result.add Row(seq: v[0].getInt, kind: v[1].getStr, payload: v[2].getStr, result: v[3].getStr, hash: v[4].getStr)

proc readTip*(c: var RqClient; runId: string): string =
  let r = c.query(%*[["SELECT journal_tip FROM runs WHERE id = ?", runId]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: vals[0][0].getStr else: ""

proc adoptLegacyLocked(c: var RqClient; runId: string; rows: seq[Row]) =
  ## the rows of a run that was written before the chain was kept get one now, from what is there
  let hashes = legacyHashes(rows)
  var stmts = newJArray()
  for i, r in rows:
    stmts.add %*["UPDATE run_journal SET hash = ? WHERE run_id = ? AND seq = ? AND hash = ''", hashes[i], runId, r.seq]
  if rows.len > 0: stmts.add %*["UPDATE runs SET journal_tip = ? WHERE id = ?", hashes[^1], runId]
  if stmts.len > 0: discard c.execute(stmts, transaction = true)

proc verifyJournal*(c: var RqClient; runId: string): tuple[check: ChainCheck, rows: seq[Row]] =
  ## The journal as it stands, and whether its chain holds. A run from before the chain gets one (and passes).
  withLock journalLock:
    var rows = c.readRows(runId)
    var check = checkChain(rows, c.readTip(runId))
    if check.verdict == cvLegacy:
      c.adoptLegacyLocked(runId, rows)
      rows = c.readRows(runId)
      check = checkChain(rows, c.readTip(runId))
    result = (check, rows)

proc appendRow*(c: var RqClient; runId: string; seq: int; kind, payload, outcome: string; alongside: JsonNode = nil): bool =
  ## Add a record, chained to the newest one, and keep the run's tip, in one transaction with `alongside` (statements the caller wants to
  ## succeed or fail with it). false, and nothing done, if the record is already there (the same call twice).
  withLock journalLock:
    let ex = c.query(%*[["SELECT 1 FROM run_journal WHERE run_id = ? AND seq = ?", runId, seq]])
    let exv = ex["results"][0]{"values"}
    if exv != nil and exv.len > 0: return false
    var rows = c.readRows(runId)
    if rows.len > 0 and rows[^1].hash.len == 0:
      c.adoptLegacyLocked(runId, rows)       # a run written before the chain: chain it first, so the journal is never half hashed
      rows = c.readRows(runId)
    var prev = ""
    for r in rows:
      if r.seq < seq: prev = r.hash
    let row = Row(seq: seq, kind: kind, payload: payload, result: outcome)
    let h = chainHash(prev, row)
    var stmts = newJArray()
    if alongside != nil:
      for s in alongside: stmts.add s
    stmts.add %*["INSERT INTO run_journal (run_id, seq, kind, fingerprint, payload, result, created_at, hash) VALUES (?, ?, ?, '', ?, ?, ?, ?)",
      runId, seq, kind, payload, outcome, $getTime().toUnix(), h]
    stmts.add %*["UPDATE runs SET journal_tip = ? WHERE id = ?", h, runId]
    discard c.execute(stmts, transaction = true)
    result = true
