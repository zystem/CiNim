## The run journal in the database, with its hash chain (T-03; the chain itself is core/journalchain.nim). Only the core writes it: one lock for
## all the threads of the core, so that the hash of a new row is computed from the newest row that is really there. The newest hash is kept
## with the run (`runs.journal_tip`) in the same transaction.
import std/[json, locks, times]
import ../common/rqlite
import journalchain

var journalLock: Lock
initLock(journalLock)

proc readRows*(c: var RqClient; runId: string): seq[Row] =
  let r = c.query(%*[["SELECT seq, kind, payload, result, hash, call_key FROM run_journal WHERE run_id = ? AND seq >= 0 ORDER BY seq", runId]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for v in vals:
      result.add Row(seq: v[0].getInt, kind: v[1].getStr, payload: v[2].getStr, result: v[3].getStr, hash: v[4].getStr, key: v[5].getStr)

proc readTip*(c: var RqClient; runId: string): string =
  let r = c.query(%*[["SELECT journal_tip FROM runs WHERE id = ?", runId]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: vals[0][0].getStr else: ""

proc verifyJournal*(c: var RqClient; runId: string): tuple[check: ChainCheck, rows: seq[Row]] =
  ## The journal as it stands, and whether its chain holds.
  withLock journalLock:
    let rows = c.readRows(runId)
    result = (checkChain(rows, c.readTip(runId)), rows)

proc appendRow*(c: var RqClient; runId, key, kind, payload, outcome: string; alongside: JsonNode = nil): bool =
  ## Add the record of the call `key`, chained to the newest one, and keep the run's tip, in one transaction with `alongside` (statements the caller wants to
  ## succeed or fail with it). Its place (`seq`) is the next one: the order in which records are appended, which is the order of completion. false, and nothing
  ## done, if the call has a record already (the same call twice).
  withLock journalLock:
    let ex = c.query(%*[["SELECT 1 FROM run_journal WHERE run_id = ? AND call_key = ?", runId, key]])
    let exv = ex["results"][0]{"values"}
    if exv != nil and exv.len > 0: return false
    let rows = c.readRows(runId)
    let seq = rows.len
    let prev = if rows.len > 0: rows[^1].hash else: ""
    let row = Row(seq: seq, key: key, kind: kind, payload: payload, result: outcome)
    let h = chainHash(prev, row)
    var stmts = newJArray()
    if alongside != nil:
      for s in alongside: stmts.add s
    stmts.add %*["INSERT INTO run_journal (run_id, seq, call_key, kind, fingerprint, payload, result, created_at, hash) VALUES (?, ?, ?, ?, '', ?, ?, ?, ?)",
      runId, seq, key, kind, payload, outcome, $getTime().toUnix(), h]
    stmts.add %*["UPDATE runs SET journal_tip = ? WHERE id = ?", h, runId]
    discard c.execute(stmts, transaction = true)
    result = true
