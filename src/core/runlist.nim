## The list of runs (GET /api/v1/runs), for the page of runs of the UI (docs/ui.md) and for anyone who wants to see what ran: newest first, a page at a time, the id of the last run of a page
## as the cursor (`before`), filtered by organisation (its slug) and by state. A row is a run without its steps (`getRun` gives those): the list is cheap however long it is. The ids are
## made by the core and ordered by time, so that the order of the ids is the order of the runs, and a cursor that is an id never misses a run or shows one twice while new runs come.
import std/[json, sequtils, strutils]
import ../common/rqlite
import apiauth

const
  defaultRunPage* = 50
  maxRunPage* = 200

type RunLimit* = tuple[org, path: string, onlyOwn: bool, refs: seq[string]]       ## D-92: a binding with a condition: its organisation or group, and what a run must be to be listed

func limitClause(l: RunLimit): string =
  ## the SQL for one binding with a condition: its organisation (and group), the runs the caller started, the runs on a ref that matches (the arguments are added in the same order)
  result = "(o.slug = ?"
  if l.path.len > 0: result.add " AND (g.path = ? OR substr(g.path, 1, ?) = ?)"
  if l.onlyOwn: result.add " AND r.actor_id = ?"
  if l.refs.len > 0:
    result.add " AND ("
    result.add l.refs.mapIt(if it.endsWith("*"): "substr(r.source_ref, 1, ?) = ?" else: "r.source_ref = ?").join(" OR ")
    result.add ")"
  result.add ")"

proc listRuns*(c: var RqClient; organization, state: string; limit: int; before: string; only: seq[string] = @[]; groups: seq[tuple[org, path: string]] = @[]; limited: seq[RunLimit] = @[]; actor = ""): JsonNode =
  ## {"runs": [...], "next": <the id to pass as `before` for the next page, or null at the end>}. `organization` and `state` and `before` are "" for no filter; `only` and `groups`
  ## keep the runs of these organisations and of these groups and projects (with what is under them), for a caller who may see some and not others (D-84).
  let n = if limit < 1: defaultRunPage else: min(limit, maxRunPage)
  var stmt = newJArray()
  stmt.add %("SELECT r.id, COALESCE(o.slug, ''), COALESCE(g.path, ''), r.state, r.created_at, r.updated_at, r.fail_code, r.fail_message, " &
    "r.source_repository, r.source_commit, COALESCE(r.trigger_id, ''), r.source_path, " &
    # D-94: a run that is RUNNING and has nothing running, only steps that wait for a place, is PENDING
    "(r.state = 'RUNNING' AND EXISTS (SELECT 1 FROM steps s WHERE s.run_id = r.id AND s.state = 'PENDING') AND NOT EXISTS (SELECT 1 FROM steps s WHERE s.run_id = r.id AND s.state IN ('STARTING', 'RUNNING'))) " &
    "FROM runs r LEFT JOIN organizations o ON o.id = r.tenant_id LEFT JOIN groups g ON g.id = r.group_id " &
    "WHERE (? = '' OR o.slug = ?) AND (? = '' OR r.state = ?) AND (? = '' OR r.id < ?)" &
    (if only.len > 0 or groups.len > 0 or limited.len > 0:
       " AND (" & (@[(if only.len > 0: "o.slug IN (" & newSeqWith(only.len, "?").join(",") & ")" else: "")] &
                   groups.mapIt("(o.slug = ? AND (g.path = ? OR substr(g.path, 1, ?) = ?))") &
                   limited.mapIt(limitClause(it))).filterIt(it.len > 0).join(" OR ") & ")"
     else: "") & " ORDER BY r.id DESC LIMIT ?")
  for a in [organization, organization, state, state, before, before]: stmt.add %a
  for s in only: stmt.add %s
  for g in groups:
    stmt.add %g.org
    stmt.add %g.path
    stmt.add %(g.path.len + 1)
    stmt.add %(g.path & "/")
  for l in limited:
    stmt.add %l.org
    if l.path.len > 0:
      stmt.add %l.path
      stmt.add %(l.path.len + 1)
      stmt.add %(l.path & "/")
    if l.onlyOwn: stmt.add %actor
    for pat in l.refs:
      if pat.endsWith("*"):
        stmt.add %(pat.len - 1)
        stmt.add %pat[0 ..< pat.len - 1]
      else: stmt.add %pat
  stmt.add %(n + 1)
  let r = c.query(%*[stmt])
  let vals = r["results"][0]{"values"}
  var runs = newJArray()
  var next = newJNull()
  if vals != nil:
    for i, row in vals.elems:
      if i == n:
        next = %runs[n - 1]["id"].getStr           # one more than a page was asked for: there is a next page, and it starts after the last row shown
        break
      var item = %*{"id": row[0].getStr, "organization": row[1].getStr, "project": row[2].getStr, "state": row[3].getStr,
                    "created_at": row[4].getStr, "updated_at": row[5].getStr}
      if row[10].getStr.len > 0: item["trigger_id"] = %row[10].getStr
      if row[12].getInt > 0: item["pending"] = %true
      if row[8].getStr.len > 0: item["source"] = %*{"repository": row[8].getStr, "commit": row[9].getStr, "path": row[11].getStr}
      if row[6].getStr.len > 0 or row[7].getStr.len > 0: item["failure"] = %*{"code": row[6].getStr, "message": row[7].getStr}
      runs.add item
  %*{"runs": runs, "next": next}

func runListScope*(who: Principal; asked: string): tuple[ok: bool, organization: string, only: seq[string], groups: seq[tuple[org, path: string]], limited: seq[RunLimit]] =
  ## which runs the caller may list: where `run.read` is held (D-84). An administrator, or a role at the shard: any (`asked`, or all of them when it is empty); a role in some
  ## organisations and on some groups: those, and asking for an organisation where nothing is held is refused, not answered with the others, so that a mistake is seen.
  ## A binding tied to the caller's own runs or to refs (D-92) lists the runs that meet it. A token of an organisation: its own. `ok` false: 403.
  let seen = who.visibleOrgs("run.read")
  if seen.all: return (true, asked, @[], @[], @[])
  if not who.ok: return
  var groups = who.visibleGroups("run.read")
  var limited: seq[RunLimit] = who.visibleLimited("run.read")
  if asked.len > 0:
    if asked in seen.slugs: return (true, asked, @[], @[], @[])
    groups = groups.filterIt(it.org == asked)
    limited = limited.filterIt(it.org == asked)
    if groups.len == 0 and limited.len == 0: return
    return (true, asked, @[], groups, limited)
  if seen.slugs.len == 0 and groups.len == 0 and limited.len == 0: return
  (true, "", seen.slugs, groups, limited)
