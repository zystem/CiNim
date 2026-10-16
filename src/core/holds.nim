## Legal hold on runs (DAT-006): "a legal hold forbids GC of chosen runs". A run under a hold keeps what it left: the sweep of the artifacts (core/artifactsweep.nim) does not
## take its artifacts, the core does not tell the controller to delete its volume (core/runstorage.nim), and an organisation that has such a run is not deleted for good (the
## reconciliation and `DELETE /api/v1/organizations/{slug}?purge=true` refuse). A hold names a reason and who placed it, is placed and released by `rw` and `admin`, and is in
## the audit. It does not stop a run, and a run that is still going may be held (the hold takes effect when it ends). What is not covered: the logs, whose retention is the
## log store's own (there is no deletion of one run's log yet), and the journal (nothing deletes it).
##
## A hold can also be on a **group** or on the **organisation** (`scope_holds`, group_id '' is the organisation): it covers every run in the group and in the groups below it, or every
## run of the organisation, those that exist and those that will be made while it stands. It is a standing condition the sweeps look at (`heldRunSql`), not a mark on each run.
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
  ## the holds of an organisation: those on runs, and those on its groups and on itself
  c.query(%*[["SELECT (SELECT count(*) FROM run_holds WHERE tenant_id = ?) + (SELECT count(*) FROM scope_holds WHERE tenant_id = ?)", tenantId, tenantId]])["results"][0]{"values"}[0][0].getInt

func view*(h: Hold): JsonNode = %*{"run": h.runId, "reason": h.reason, "placed_by": h.placedBy, "placed_at": h.placedAt}

# ------------------------------------------------------------------ a hold on a group or on the organisation

type ScopeHold* = object
  groupPath*: string           ## "" is the organisation
  reason*, placedBy*: string
  placedAt*: int64

func heldRunSql*(runId, tenant, group: string): string =
  ## A SQL condition, true when the run is held: by a hold of its own, by one on its group or a group above it, or by one on the organisation. The three arguments are the
  ## SQL expressions of the run's id, its organisation and its group (`runs.id`, `runs.tenant_id`, `runs.group_id`).
  "(EXISTS (SELECT 1 FROM run_holds h WHERE h.run_id = " & runId & ") OR EXISTS (SELECT 1 FROM scope_holds sh WHERE sh.tenant_id = " & tenant &
  " AND (sh.group_id = '' OR EXISTS (SELECT 1 FROM groups hg, groups rg WHERE hg.id = sh.group_id AND rg.id = " & group &
  " AND (rg.path = hg.path OR substr(rg.path, 1, length(hg.path) + 1) = hg.path || '/')))))"

proc placeScopeHold*(c: var RqClient; tenantId, groupId, reason, by: string; now: int64): tuple[error: string, placed: bool] =
  ## `groupId` '' holds the organisation. `placed` false with no error: it was held already (the first reason stands)
  if reason.strip.len == 0: return ("a legal hold has a reason", false)
  if reason.len > maxReason: return ("the reason is at most " & $maxReason & " characters", false)
  let r = c.execute(%*[["INSERT OR IGNORE INTO scope_holds (tenant_id, group_id, reason, placed_by, placed_at) VALUES (?, ?, ?, ?, ?)", tenantId, groupId, reason, by, now]])
  ("", r["results"][0]{"rows_affected"}.getInt > 0)

proc releaseScopeHold*(c: var RqClient; tenantId, groupId: string): bool =
  c.execute(%*[["DELETE FROM scope_holds WHERE tenant_id = ? AND group_id = ?", tenantId, groupId]])["results"][0]{"rows_affected"}.getInt > 0

proc scopeHoldOf*(c: var RqClient; tenantId, groupId: string): tuple[held: bool, hold: ScopeHold] =
  ## the hold that is on exactly this group ('' the organisation), not those above it
  let v = c.query(%*[["SELECT reason, placed_by, placed_at FROM scope_holds WHERE tenant_id = ? AND group_id = ?", tenantId, groupId]])["results"][0]{"values"}
  if v != nil and v.len > 0: (true, ScopeHold(reason: v[0][0].getStr, placedBy: v[0][1].getStr, placedAt: v[0][2].getBiggestInt)) else: (false, ScopeHold())

proc listScopeHolds*(c: var RqClient; tenantId: string): seq[ScopeHold] =
  let v = c.query(%*[["SELECT COALESCE(g.path, ''), sh.reason, sh.placed_by, sh.placed_at FROM scope_holds sh LEFT JOIN groups g ON g.id = sh.group_id WHERE sh.tenant_id = ? " &
                      "ORDER BY sh.placed_at", tenantId]])["results"][0]{"values"}
  if v != nil:
    for row in v: result.add ScopeHold(groupPath: row[0].getStr, reason: row[1].getStr, placedBy: row[2].getStr, placedAt: row[3].getBiggestInt)

proc coveringHold*(c: var RqClient; runId: string): tuple[held: bool, hold: ScopeHold] =
  ## the hold of a group or of the organisation that covers the run (the nearest one: the group itself, then those above it, then the organisation), if any
  let v = c.query(%*[["SELECT COALESCE(hg.path, ''), sh.reason, sh.placed_by, sh.placed_at FROM runs r JOIN scope_holds sh ON sh.tenant_id = r.tenant_id " &
                      "LEFT JOIN groups hg ON hg.id = sh.group_id LEFT JOIN groups rg ON rg.id = r.group_id " &
                      "WHERE r.id = ? AND (sh.group_id = '' OR (rg.path = hg.path OR substr(rg.path, 1, length(hg.path) + 1) = hg.path || '/')) " &
                      "ORDER BY length(COALESCE(hg.path, '')) DESC LIMIT 1", runId]])["results"][0]{"values"}
  if v != nil and v.len > 0: (true, ScopeHold(groupPath: v[0][0].getStr, reason: v[0][1].getStr, placedBy: v[0][2].getStr, placedAt: v[0][3].getBiggestInt)) else: (false, ScopeHold())

proc scopeHeldCount*(c: var RqClient; tenantId: string): int =
  c.query(%*[["SELECT count(*) FROM scope_holds WHERE tenant_id = ?", tenantId]])["results"][0]{"values"}[0][0].getInt

func view*(h: ScopeHold): JsonNode =
  result = %*{"reason": h.reason, "placed_by": h.placedBy, "placed_at": h.placedAt}
  result["level"] = %(if h.groupPath.len == 0: "organization" else: "group")
  if h.groupPath.len > 0: result["group"] = %h.groupPath
