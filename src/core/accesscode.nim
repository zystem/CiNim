## D-98: the roles of an organisation as a document, so that they can be kept in git and applied by a CI step: `GET /api/v1/organizations/{slug}/access` writes it, `PUT .../access` reads it
## (`?dry_run=true` says what would change and changes nothing; `?prune=true` also takes away the hand-given bindings the document does not name). Only what is given by hand is in it
## (`source` ''): the roles that a directory gives or a team passes on are theirs. The roles themselves (`PUT /api/v1/roles/{name}`) are the shard\'s, not part of an organisation\'s document.
##   {"version": 1, "members": [{"scope": "org:acme" | "org:acme/ci/app", "subject": "ann" | "team:ops", "roles": ["dev", {"role": "rw", "expires_at": ..., "only_own": true, "refs": [...]}]}],
##    "teams": [{"name": "ops", "description": "...", "ldap": {"group_dn": "...", "directory": "..."} | null, "members": ["bob"]}]}
## The document is checked whole before anything is changed; a prune that would take away the caller\'s own roles is refused.
import std/[json, strutils, tables, algorithm, sets, sequtils]
import ../common/rqlite
import apiauth, teams, groups

type AccessResult* = object
  errors*: seq[string]
  changes*: seq[JsonNode]

func condKey(roles: seq[(string, BindingCondition)]): string =
  var parts: seq[string]
  for (r, cd) in roles: parts.add r & "|" & $cd.expiresAt & "|" & $cd.onlyOwn & "|" & cd.refs.join(",")
  parts.sort()
  parts.join(";")

proc currentManual(c: var RqClient; slug: string): Table[string, seq[(string, BindingCondition)]] =
  ## (scope, user) -> the roles given by hand there, with their conditions; the key is `scope\tuser`
  let v = c.query(%*[["SELECT scope, user_name, role, expires_at, only_own, refs FROM role_bindings WHERE source = '' AND (scope = ? OR scope LIKE ?) ORDER BY scope, user_name, role", "org:" & slug, "org:" & slug & "/%"]])["results"][0]{"values"}
  if v != nil:
    for r in v:
      let key = r[0].getStr & "\t" & r[1].getStr
      if key notin result: result[key] = @[]
      result[key].add (r[2].getStr, conditionOf(r[3].getBiggestInt, r[4].getInt > 0, r[5].getStr))

func subjectName(slug, user: string): string =
  let prefix = "team:" & slug & "/"
  if user.startsWith(prefix): "team:" & user[prefix.len .. ^1] else: user

proc exportAccess*(c: var RqClient; tenantId, slug: string): JsonNode =
  var members = newJArray()
  let cur = c.currentManual(slug)
  var keys = toSeq(cur.keys)
  keys.sort()
  for k in keys:
    let parts = k.split('\t')
    var roles = newJArray()
    for (r, cd) in cur[k]:
      let view = conditionView(cd, 0)
      if view.len == 0: roles.add %r
      else:
        var o = %*{"role": r}
        for fk, fv in view: (if fk != "expired": o[fk] = fv)
        roles.add o
    members.add %*{"scope": parts[0], "subject": subjectName(slug, parts[1]), "roles": roles}
  var tj = newJArray()
  for t in c.listTeams(tenantId, slug):
    var ms = newJArray()
    for m in t["members"]:
      if m["source"].getStr.len == 0: ms.add m["user"]
    var item = %*{"name": t["name"], "description": t["description"], "members": ms}
    item["ldap"] = if t.hasKey("ldap"): %*{"group_dn": t["ldap"]["group_dn"], "directory": t["ldap"]["directory"]} else: newJNull()
    tj.add item
  %*{"version": 1, "organization": slug, "members": members, "teams": tj}

proc applyAccess*(c: var RqClient; tenantId, slug: string; doc: JsonNode; prune, dryRun: bool; actor: string; now: int64): AccessResult =
  ## checks the document, and (unless `dryRun`) makes the organisation\'s hand-given roles and teams what it says
  template bad(msg: string) = result.errors.add msg
  if doc == nil or doc.kind != JObject or doc{"version"}.getInt != 1: return AccessResult(errors: @["a document is {\"version\": 1, \"members\": [...], \"teams\": [...]}"])
  var desired = initTable[string, seq[(string, BindingCondition)]]()
  var teamNames = initHashSet[string]()
  for t in c.listTeams(tenantId, slug): teamNames.incl t["name"].getStr
  if doc.hasKey("teams"):
    if doc["teams"].kind != JArray: bad "teams is a list"
    else:
      for t in doc["teams"]:
        if t.kind != JObject or not t.isString("name") or not validTeamName(t["name"].getStr): bad "a team is {name, description?, ldap?, members?} with a name of lowercase letters, digits, - and _"
        else: teamNames.incl t["name"].getStr
  if doc.hasKey("members"):
    if doc["members"].kind != JArray: bad "members is a list"
    else:
      for m in doc["members"]:
        if m.kind != JObject or not m.isString("scope") or not m.isString("subject") or m{"roles"}.kind != JArray:
          bad "a member is {scope, subject, roles}"
          continue
        let scope = m["scope"].getStr
        let subject = m["subject"].getStr
        if scope != "org:" & slug and not scope.startsWith("org:" & slug & "/"): bad scope & " is not in the organisation " & slug
        elif scope != "org:" & slug and not (let g = c.groupIdOf(tenantId, scope["org:".len + slug.len + 1 .. ^1]); g.found and g.id.len > 0): bad "no group or project at " & scope
        var user = subject
        if subject.startsWith("team:"):
          if subject[5 .. ^1] notin teamNames: bad "no team " & subject
          user = teamSubject(slug, subject[5 .. ^1])
        elif not c.userRoles(subject).found: bad "no user " & subject
        var roles: seq[(string, BindingCondition)]
        for r in m["roles"]:
          if r.kind == JString: roles.add (r.getStr, BindingCondition())
          elif r.kind == JObject and r.isString("role"):
            let p = bindingConditionOf(r)
            if p.error.len > 0: bad subject & ": " & p.error
            else:
              for pat in p.cond.refs:
                if not isRefPattern(pat): bad subject & ": a ref is a branch or tag name, or a name followed by * (" & pat & ")"
              if p.cond.refs.len > maxBindingRefs: bad subject & ": at most " & $maxBindingRefs & " refs to a role"
              if p.cond.expiresAt > 0 and p.cond.expiresAt <= now: bad subject & ": the term of " & r["role"].getStr & " is in the past"
              roles.add (r["role"].getStr, p.cond)
          else: bad "a role is a name or {role, expires_at?, only_own?, refs?}"
        for (r, _) in roles:
          if not c.roleExists(r): bad "no role " & r
        desired[scope & "\t" & user] = roles
  if result.errors.len > 0: return
  let cur = c.currentManual(slug)
  for key, roles in desired:
    let parts = key.split('\t')
    if key notin cur or condKey(cur[key]) != condKey(roles):
      result.changes.add %*{"op": "set", "scope": parts[0], "subject": subjectName(slug, parts[1]), "roles": roles.mapIt(it[0])}
  if prune:
    for key, roles in cur:
      if key notin desired:
        let parts = key.split('\t')
        if parts[1] == actor: bad "a prune would take away your own roles at " & parts[0] & ": name yourself in the document"
        result.changes.add %*{"op": "remove", "scope": parts[0], "subject": subjectName(slug, parts[1])}
  if result.errors.len > 0:
    result.changes = @[]
    return
  var teamPlan: seq[JsonNode]
  if doc.hasKey("teams"):
    for t in doc["teams"]:
      result.changes.add %*{"op": "team", "name": t["name"], "members": t{"members"}}
  if dryRun: return
  # teams first (a team is the subject of a binding), then the bindings
  if doc.hasKey("teams"):
    for t in doc["teams"]:
      let name = t["name"].getStr
      var body = newJObject()
      for k in ["description", "ldap"]:
        if t.hasKey(k): body[k] = t[k]
      let made = c.putTeam(tenantId, name, body, now)
      if made.error.len > 0:
        bad "team " & name & ": " & made.error
        continue
      var want = initHashSet[string]()
      if t.hasKey("members") and t["members"].kind == JArray:
        for u in t["members"]:
          if u.kind != JString: continue
          want.incl u.getStr
          let a = c.addTeamMember(tenantId, name, u.getStr)
          if a.error.len > 0 and a.status != 409: bad "team " & name & ": " & a.error
      if prune:
        for cur in c.listTeams(tenantId, slug):
          if cur["name"].getStr != name: continue
          for m in cur["members"]:
            if m["source"].getStr.len == 0 and m["user"].getStr notin want: discard c.removeTeamMember(tenantId, name, m["user"].getStr)
  for ch in result.changes:
    case ch["op"].getStr
    of "set":
      var roles: seq[string]
      var conds = initTable[string, BindingCondition]()
      let key = ch["scope"].getStr & "\t" & (if ch["subject"].getStr.startsWith("team:"): teamSubject(slug, ch["subject"].getStr[5 .. ^1]) else: ch["subject"].getStr)
      for (r, cd) in desired[key]:
        roles.add r
        conds[r] = cd
      let err = c.setMember(ch["scope"].getStr, (if ch["subject"].getStr.startsWith("team:"): teamSubject(slug, ch["subject"].getStr[5 .. ^1]) else: ch["subject"].getStr), roles, conds, now)
      if err.len > 0: bad err
    of "remove":
      let err = c.setMember(ch["scope"].getStr, (if ch["subject"].getStr.startsWith("team:"): teamSubject(slug, ch["subject"].getStr[5 .. ^1]) else: ch["subject"].getStr), @[], initTable[string, BindingCondition](), now)
      if err.len > 0: bad err
    else: discard
