## The list of runs (GET /api/v1/runs), for the page of runs of the UI (docs/ui.md) and for anyone who wants to see what ran: newest first, a page at a time, the id of the last run of a page
## as the cursor (`before`), filtered by organisation (its slug) and by state. A row is a run without its steps (`getRun` gives those): the list is cheap however long it is. The ids are
## made by the core and ordered by time, so that the order of the ids is the order of the runs, and a cursor that is an id never misses a run or shows one twice while new runs come.
import std/json
import ../common/rqlite
import apiauth

const
  defaultRunPage* = 50
  maxRunPage* = 200

proc listRuns*(c: var RqClient; organization, state: string; limit: int; before: string): JsonNode =
  ## {"runs": [...], "next": <the id to pass as `before` for the next page, or null at the end>}. `organization` and `state` and `before` are "" for no filter.
  let n = if limit < 1: defaultRunPage else: min(limit, maxRunPage)
  let r = c.query(%*[["SELECT r.id, COALESCE(o.slug, ''), COALESCE(g.path, ''), r.state, r.created_at, r.updated_at, r.fail_code, r.fail_message, " &
    "r.source_repository, r.source_commit, COALESCE(r.trigger_id, ''), r.source_path " &
    "FROM runs r LEFT JOIN organizations o ON o.id = r.tenant_id LEFT JOIN groups g ON g.id = r.group_id " &
    "WHERE (? = '' OR o.slug = ?) AND (? = '' OR r.state = ?) AND (? = '' OR r.id < ?) ORDER BY r.id DESC LIMIT ?",
    organization, organization, state, state, before, before, n + 1]])
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
      if row[8].getStr.len > 0: item["source"] = %*{"repository": row[8].getStr, "commit": row[9].getStr, "path": row[11].getStr}
      if row[6].getStr.len > 0 or row[7].getStr.len > 0: item["failure"] = %*{"code": row[6].getStr, "message": row[7].getStr}
      runs.add item
  %*{"runs": runs, "next": next}

func runListScope*(who: Principal; asked: string): tuple[ok: bool, organization: string] =
  ## which organisation's runs the caller may list: an administrator or a shard-level role, any (`asked`, or all of them when it is empty); a token of an organisation, its own only, whatever it asks
  ## (asking for another's is refused, not answered with its own, so that a mistake is seen). `ok` false: 403.
  if who.acrossOrgs: return (true, asked)
  if not who.ok or who.org.len == 0: return (false, "")
  if asked.len > 0 and asked != who.org: return (false, "")
  (true, who.org)
