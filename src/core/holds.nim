## Legal hold on runs (DAT-006): "a legal hold forbids GC of chosen runs". A run under a hold keeps what it left: the sweep of the artifacts (core/artifactsweep.nim) does not
## take its artifacts, the core does not tell the controller to delete its volume (core/runstorage.nim), and an organisation that has such a run is not deleted for good (the
## reconciliation and `DELETE /api/v1/organizations/{slug}?purge=true` refuse). A hold names a reason and who placed it, is placed and released by `rw` and `admin`, and is in
## the audit. It does not stop a run, and a run that is still going may be held (the hold takes effect when it ends). What is not covered: the logs, whose retention is the
## log store's own (there is no deletion of one run's log yet), and the journal (nothing deletes it).
import std/[json, strutils]
import ../common/rqlite

const maxReason* = 1000

type Hold* = object
  runId*, reason*, placedBy*: string
  placedAt*: int64

proc placeHold*(c: var RqClient; runId, tenantId, reason, by: string; now: int64): tuple[error: string, placed: bool] =
  ## `placed` false with no error: the run was held already (its first reason stands)
  if reason.strip.len == 0: return ("a legal hold has a reason", false)
  if reason.len > maxReason: return ("the reason is at most " & $maxReason & " characters", false)
  let r = c.execute(%*[["INSERT OR IGNORE INTO run_holds (run_id, tenant_id, reason, placed_by, placed_at) VALUES (?, ?, ?, ?, ?)", runId, tenantId, reason, by, now]])
  ("", r["results"][0]{"rows_affected"}.getInt > 0)

proc releaseHold*(c: var RqClient; runId: string): bool =
  c.execute(%*[["DELETE FROM run_holds WHERE run_id = ?", runId]])["results"][0]{"rows_affected"}.getInt > 0

proc holdOf*(c: var RqClient; runId: string): tuple[held: bool, hold: Hold] =
  let v = c.query(%*[["SELECT reason, placed_by, placed_at FROM run_holds WHERE run_id = ?", runId]])["results"][0]{"values"}
  if v != nil and v.len > 0: (true, Hold(runId: runId, reason: v[0][0].getStr, placedBy: v[0][1].getStr, placedAt: v[0][2].getBiggestInt)) else: (false, Hold())

proc listHolds*(c: var RqClient; tenantId: string): seq[Hold] =
  let v = c.query(%*[["SELECT run_id, reason, placed_by, placed_at FROM run_holds WHERE tenant_id = ? ORDER BY placed_at", tenantId]])["results"][0]{"values"}
  if v != nil:
    for row in v: result.add Hold(runId: row[0].getStr, reason: row[1].getStr, placedBy: row[2].getStr, placedAt: row[3].getBiggestInt)

proc heldCount*(c: var RqClient; tenantId: string): int =
  c.query(%*[["SELECT count(*) FROM run_holds WHERE tenant_id = ?", tenantId]])["results"][0]{"values"}[0][0].getInt

func view*(h: Hold): JsonNode = %*{"run": h.runId, "reason": h.reason, "placed_by": h.placedBy, "placed_at": h.placedAt}
