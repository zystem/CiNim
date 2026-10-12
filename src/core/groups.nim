## The groups of an organisation (PRJ-001, D-54). The structure is shard -> organisation -> group (nested up to 8 levels) -> job; there is no project. The organisation itself is the
## root: it has no row, and a run or a trigger with `group_id` '' belongs to it. A group is named by its path, the slugs from the top joined by '/', for example `team/backend`; a
## run or a trigger belongs to one group, which may be at any level. The variables of a group (VAR-001) are inherited by its runs and by the groups below it (core/orgvars.nim).
import std/[json, strutils, sequtils]
import ../common/rqlite
import schema

const
  maxGroupDepth* = 8
  maxGroupsPerOrganization* = 1000
  reservedSlugs = ["variables"]           ## a segment of the URL that names something under a group

func validGroupSlug*(s: string): bool =
  ## lowercase letters, digits and '-', starting with a letter, at most 40; not a word the URLs use
  if s.len < 1 or s.len > 40 or s[0] notin {'a' .. 'z'}: return false
  for ch in s:
    if ch notin {'a' .. 'z', '0' .. '9', '-'}: return false
  s notin reservedSlugs

func pathParts*(path: string): seq[string] =
  ## "team/backend" -> @["team", "backend"]; "" and "/" are the root
  path.strip(chars = {'/'}).split('/').filterIt(it.len > 0)

func normalPath*(path: string): string = pathParts(path).join("/")

proc groupIdOf*(c: var RqClient; tenantId, path: string): tuple[found: bool, id: string] =
  ## the root (an empty path) is found and has the id ""; an unknown path is not found
  let p = normalPath(path)
  if p.len == 0: return (true, "")
  let v = c.query(%*[["SELECT id FROM groups WHERE tenant_id = ? AND path = ?", tenantId, p]])["results"][0]{"values"}
  if v != nil and v.len > 0: (true, v[0][0].getStr) else: (false, "")

proc groupPathOf*(c: var RqClient; groupId: string): string =
  if groupId.len == 0: return ""
  let v = c.query(%*[["SELECT path FROM groups WHERE id = ?", groupId]])["results"][0]{"values"}
  if v != nil and v.len > 0: v[0][0].getStr else: ""

proc createGroup*(c: var RqClient; tenantId, path: string; now: int64): tuple[error, id: string; created: bool] =
  ## The group at `path`; its parent has to exist. Idempotent: a group that is there is answered with its id. `error` is "" or why not.
  let parts = pathParts(path)
  if parts.len == 0: return ("the organisation is the root; a group has a name", "", false)
  if parts.len > maxGroupDepth: return ("groups are nested at most " & $maxGroupDepth & " levels", "", false)
  for part in parts:
    if not validGroupSlug(part):
      return ("a group's name is lowercase letters, digits and '-', starting with a letter, at most 40 characters, and not 'variables': " & part, "", false)
  let full = parts.join("/")
  let have = c.groupIdOf(tenantId, full)
  if have.found: return ("", have.id, false)
  let parent = c.groupIdOf(tenantId, parts[0 ..< parts.high].join("/"))
  if not parent.found: return ("the group " & parts[0 ..< parts.high].join("/") & " does not exist; create the parent first", "", false)
  let count = c.query(%*[["SELECT count(*) FROM groups WHERE tenant_id = ?", tenantId]])["results"][0]{"values"}[0][0].getInt
  if count >= maxGroupsPerOrganization: return ("an organisation has at most " & $maxGroupsPerOrganization & " groups", "", false)
  let id = newId()
  discard c.execute(%*[["INSERT INTO groups (id, tenant_id, parent_id, slug, path, depth, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    id, tenantId, parent.id, parts[^1], full, parts.len, now]])
  ("", id, true)

proc listGroups*(c: var RqClient; tenantId: string): seq[tuple[id, path: string; depth: int]] =
  let v = c.query(%*[["SELECT id, path, depth FROM groups WHERE tenant_id = ? ORDER BY path", tenantId]])["results"][0]{"values"}
  if v != nil:
    for row in v: result.add (row[0].getStr, row[1].getStr, row[2].getInt)

proc deleteGroup*(c: var RqClient; tenantId, path: string): tuple[error: string; deleted: bool] =
  ## A group goes only when nothing is in it: no group below, no run, no trigger. Its variables go with it.
  let g = c.groupIdOf(tenantId, path)
  if not g.found or g.id.len == 0: return ("", false)
  let n = c.query(%*[["SELECT (SELECT count(*) FROM groups WHERE parent_id = ?), (SELECT count(*) FROM runs WHERE group_id = ?), (SELECT count(*) FROM triggers WHERE group_id = ?)",
    g.id, g.id, g.id]])["results"][0]{"values"}[0]
  if n[0].getInt > 0: return ("the group has groups below it", false)
  if n[1].getInt > 0: return ("the group has runs", false)
  if n[2].getInt > 0: return ("the group has triggers", false)
  discard c.execute(%*[["DELETE FROM group_variables WHERE group_id = ?", g.id], ["DELETE FROM groups WHERE id = ?", g.id]], transaction = true)
  ("", true)

proc groupChain*(c: var RqClient; tenantId, groupId: string): seq[tuple[id, path: string]] =
  ## the group and every one above it, from the top: the order in which their variables are laid over each other
  if groupId.len == 0: return
  let path = c.groupPathOf(groupId)
  if path.len == 0: return
  let parts = pathParts(path)
  for i in 1 .. parts.len:
    let prefix = parts[0 ..< i].join("/")
    let g = c.groupIdOf(tenantId, prefix)
    if g.found and g.id.len > 0: result.add (g.id, prefix)
