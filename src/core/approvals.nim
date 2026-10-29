## D-93: a run can wait for approval before it starts. It is made in the state WAITING with `approval_required` (how many people must approve, taken from its project when it is made)
## and `approval_deadline`; it holds no Pod and no volume while it waits. Whoever holds `run.approve` for it, and did not start it, may approve or reject it; enough approvals make it
## RUNNING, one rejection ABORTED, the deadline TIMED_OUT, and a run for which there is nobody who could approve is ABORTED at once (and when the last one who could goes). This module
## says who could: the people, through their own bindings or through a team, that hold the permission on the project and are not switched off. The decisions are in scheduler.nim.
import std/[json, strutils, sets, tables, algorithm, sequtils]
import ../common/rqlite
import apiauth, refpattern

type ApprovalSpec* = object
  required*: int            ## 0: the run needs no approval
  timeoutSeconds*: int64

const
  defaultApprovalSeconds* = 86400'i64
  minApprovalSeconds* = 60'i64
  maxApprovalSeconds* = 30'i64 * 86400
  maxRequiredApprovals* = 10

proc approverNames*(c: var RqClient; slug, groupPath, ref0, author: string; now: int64): seq[string] =
  ## the accounts that could approve a run of this project on this ref: a person with a binding that gives `run.approve` there (in the organisation, on the project or on a group above it,
  ## or `admin` at the shard), or a member of a team that has one; not the one who started it (`author` is `user:<name>`), nobody who is switched off, and nobody whose binding is tied
  ## to their own runs or to other refs than this one (D-92) or whose term has ended.
  var scopes = @[shardScope, "org:" & slug]
  var path = ""
  for part in groupPath.split('/'):
    if part.len == 0: continue
    path = if path.len == 0: part else: path & "/" & part
    scopes.add "org:" & slug & "/" & path
  var stmt = newJArray()
  stmt.add %("SELECT user_name, role, scope, only_own, refs FROM role_bindings WHERE scope IN (" & scopes.mapIt("?").join(",") & ") AND (expires_at = 0 OR expires_at > ?)")
  for s in scopes: stmt.add %s
  stmt.add %now
  let rows = c.query(%*[stmt])["results"][0]{"values"}
  var perms = initTable[string, bool]()
  var subjects = initHashSet[string]()
  if rows != nil:
    for v in rows:
      let role = v[1].getStr
      if role notin perms: perms[role] = "run.approve" in c.rolePermissions(role)
      if not perms[role]: continue
      if v[2].getStr == shardScope and role != roleAdmin: continue          # D-90
      if v[3].getInt > 0: continue                                          # tied to the user's own runs: not another's
      let conds = v[4].getStr.splitLines
      var matches = true
      var any = false
      for p in conds:
        if p.strip.len == 0: continue
        any = true
        matches = false
        if refMatches(p.strip, ref0):
          matches = true
          break
      if any and not matches: continue
      subjects.incl v[0].getStr
  var people = initHashSet[string]()
  for s in subjects:
    if s.startsWith("team:"):
      let at = s.find('/')
      if at < 0: continue
      let members = c.query(%*[["SELECT m.user_name FROM team_members m JOIN teams t ON t.id = m.team_id JOIN organizations o ON o.id = t.tenant_id WHERE o.slug = ? AND t.name = ?", s[5 ..< at], s[at + 1 .. ^1]]])["results"][0]{"values"}
      if members != nil:
        for m in members: people.incl m[0].getStr
    else: people.incl s
  for name in people:
    if author == "user:" & name: continue
    let u = c.query(%*[["SELECT disabled FROM users WHERE name = ?", name]])["results"][0]{"values"}
    if u == nil or u.len == 0 or u[0][0].getInt > 0: continue
    result.add name
  result.sort()
