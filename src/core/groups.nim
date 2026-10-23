## The groups of an organisation (PRJ-001, D-54, D-68). The structure is shard -> organisation -> group (nested up to 8 levels) -> project, a project being a leaf group that has a repository -> pipeline. The organisation itself is the
## root: it has no row, and a run or a trigger with `group_id` '' belongs to it. A group is named by its path, the slugs from the top joined by '/', for example `team/backend`; a
## run or a trigger belongs to one group, which may be at any level. The variables of a group (VAR-001) are inherited by its runs and by the groups below it (core/orgvars.nim).
import std/[json, strutils, sequtils]
import ../common/rqlite
import schema
import ../common/scriptsource

const
  maxGroupDepth* = 8
  maxGroupsPerOrganization* = 1000
  reservedSlugs = ["variables", "settings", "hold"]           ## a segment of the URL that names something under a group

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
  if parent.found and parent.id.len > 0:
    let repo = c.query(%*[["SELECT repository FROM groups WHERE id = ?", parent.id]])["results"][0]{"values"}
    if repo != nil and repo.len > 0 and repo[0][0].getStr.len > 0:
      return ("the group " & parts[0 ..< parts.high].join("/") & " is a project (it has a repository): nothing is made below a project, a project is a leaf", "", false)
  if not parent.found: return ("the group " & parts[0 ..< parts.high].join("/") & " does not exist; create the parent first", "", false)
  let count = c.query(%*[["SELECT count(*) FROM groups WHERE tenant_id = ?", tenantId]])["results"][0]{"values"}[0][0].getInt
  if count >= maxGroupsPerOrganization: return ("an organisation has at most " & $maxGroupsPerOrganization & " groups", "", false)
  let id = newId()
  discard c.execute(%*[["INSERT INTO groups (id, tenant_id, parent_id, slug, path, depth, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    id, tenantId, parent.id, parts[^1], full, parts.len, now]])
  ("", id, true)

proc listGroups*(c: var RqClient; tenantId: string): seq[tuple[id, path: string; depth: int; repository: string]] =
  let v = c.query(%*[["SELECT id, path, depth, repository FROM groups WHERE tenant_id = ? ORDER BY path", tenantId]])["results"][0]{"values"}
  if v != nil:
    for row in v: result.add (row[0].getStr, row[1].getStr, row[2].getInt, row[3].getStr)

proc setRepository*(c: var RqClient; tenantId, path, repository: string): string =
  ## D-68: the main repository of the group at `path`, which makes it a project ("" takes it away). "" is done, else why not. The organisation (the root) has none.
  let g = c.groupIdOf(tenantId, path)
  if not g.found: return "the group " & normalPath(path) & " does not exist"
  if g.id.len == 0: return "the organisation has no repository; a project is a group"
  if repository.len > 0 and not validRepository(repository): return "repository must be an https:// or http:// URL"
  if repository.len > 0 and c.query(%*[["SELECT count(*) FROM groups WHERE parent_id = ?", g.id]])["results"][0]{"values"}[0][0].getInt > 0:
    return "the group " & normalPath(path) & " has groups below it: it is a group, and a project is a leaf of the tree"
  discard c.execute(%*[["UPDATE groups SET repository = ? WHERE id = ?", repository, g.id]])
  ""

type ResolvedProject* = object
  code*, message*: string            ## "" when the path is a project
  id*, path*, repository*: string

proc resolveProject*(c: var RqClient; tenantId, path: string): ResolvedProject =
  ## D-68: the project at `path` (`cinim`, or `ci/cinim` under the group `ci`): a group with a repository. A run and a trigger are of a project, so the organisation itself and a group
  ## that is only a folder are not one.
  let p = normalPath(path)
  if p.len == 0: return ResolvedProject(code: "project_required", message: "a run belongs to a project: give its path, for example cinim or ci/cinim")
  let v = c.query(%*[["SELECT id, repository FROM groups WHERE tenant_id = ? AND path = ?", tenantId, p]])["results"][0]{"values"}
  if v == nil or v.len == 0: return ResolvedProject(code: "project_not_found", message: "there is no project " & p & " in this organisation")
  if v[0][1].getStr.len == 0:
    return ResolvedProject(code: "project_has_no_repository", message: p & " is a group with no repository, not a project; a project is a leaf of the tree and has one: PUT /groups/" & p & " {\"repository\": \"https://...\"}")
  ResolvedProject(id: v[0][0].getStr, path: p, repository: v[0][1].getStr)

proc deleteGroup*(c: var RqClient; tenantId, path: string): tuple[error: string; deleted: bool] =
  ## A group goes only when nothing is in it: no group below, no run, no trigger. Its variables go with it.
  let g = c.groupIdOf(tenantId, path)
  if not g.found or g.id.len == 0: return ("", false)
  let n = c.query(%*[["SELECT (SELECT count(*) FROM groups WHERE parent_id = ?), (SELECT count(*) FROM runs WHERE group_id = ?), (SELECT count(*) FROM triggers WHERE group_id = ?)",
    g.id, g.id, g.id]])["results"][0]{"values"}[0]
  if n[0].getInt > 0: return ("the group has groups below it", false)
  if n[1].getInt > 0: return ("the group has runs", false)
  if n[2].getInt > 0: return ("the group has triggers", false)
  if c.query(%*[["SELECT count(*) FROM scope_holds WHERE group_id = ?", g.id]])["results"][0]{"values"}[0][0].getInt > 0: return ("the group is under a legal hold; release it first", false)
  discard c.execute(%*[["DELETE FROM group_variables WHERE group_id = ?", g.id], ["DELETE FROM group_settings WHERE group_id = ?", g.id], ["DELETE FROM groups WHERE id = ?", g.id]], transaction = true)
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

type GroupKind* = enum gkNone, gkGroup, gkProject

proc groupKind*(c: var RqClient; tenantId, path: string): GroupKind =
  ## what is at `path`: a group (a folder, no repository), a project (a leaf with a repository), or nothing
  let v = c.query(%*[["SELECT repository FROM groups WHERE tenant_id = ? AND path = ?", tenantId, normalPath(path)]])["results"][0]{"values"}
  if v == nil or v.len == 0: gkNone elif v[0][0].getStr.len > 0: gkProject else: gkGroup

proc createProject*(c: var RqClient; tenantId, path, repository: string; now: int64): tuple[error, code, id: string; created: bool] =
  ## D-68, the second of the two things one makes (the first is `createGroup`): the project at `path`, a leaf of the tree with its main repository. The parent group has to exist; a group that is there
  ## stays a group (`already_a_group`); a project that is there takes the new repository. `code` is "" or `invalid_project` / `already_a_group`, `error` is why.
  if repository.len == 0: return ("a project has a repository: give it", "invalid_project", "", false)
  if not validRepository(repository): return ("repository must be an https:// or http:// URL", "invalid_project", "", false)
  if pathParts(path).len == 0: return ("the organisation is the root; a project has a name", "invalid_project", "", false)
  case c.groupKind(tenantId, path)
  of gkGroup: return ("there is a group at " & normalPath(path) & ", not a project: a project is made, a group is not converted", "already_a_group", "", false)
  of gkProject:
    let err = c.setRepository(tenantId, path, repository)
    return (err, (if err.len > 0: "invalid_project" else: ""), c.groupIdOf(tenantId, path).id, false)
  of gkNone: discard
  let made = c.createGroup(tenantId, path, now)
  if made.error.len > 0: return (made.error, "invalid_project", "", false)
  let err = c.setRepository(tenantId, path, repository)
  if err.len > 0:
    discard c.deleteGroup(tenantId, path)
    return (err, "invalid_project", "", false)
  ("", "", made.id, true)
