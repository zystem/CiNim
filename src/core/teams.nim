## Teams (D-91): a named set of the people of an organisation, to which roles are given instead of person by person. A team belongs to one organisation, is made by hand or takes its members
## from a group of a directory (LDAP, D-87), and its roles are bindings of the organisation or of a group or project in it (`role_bindings` whose user is `team:<slug>/<name>`; core/apiauth.nim
## adds them to the rights of every member). A member is added by hand (`source` '') or given by the directory (`ldap:<server id>`): the login and the sync of a directory add and take away
## only the second kind, as they do for roles.
import std/[json, strutils, times]
import ../common/rqlite
import schema, apiauth, ldapauth

const maxTeamsPerOrg* = 200
const maxMembersPerTeam* = 2000

func validTeamName*(n: string): bool =
  if n.len < 1 or n.len > 40 or n[0] notin {'a' .. 'z'}: return false
  for ch in n:
    if ch notin {'a' .. 'z', '0' .. '9', '-', '_'}: return false
  true

func teamSubject*(slug, name: string): string = "team:" & slug & "/" & name

proc teamId*(c: var RqClient; tenantId, name: string): string =
  let v = c.query(%*[["SELECT id FROM teams WHERE tenant_id = ? AND name = ?", tenantId, name]])["results"][0]{"values"}
  if v != nil and v.len > 0: v[0][0].getStr else: ""

proc listTeams*(c: var RqClient; tenantId, slug: string): JsonNode =
  ## the teams with how each is made, who is in it and what roles it has
  result = newJArray()
  let ts = c.query(%*[["SELECT t.id, t.name, t.description, t.group_dn, COALESCE(s.name, '') FROM teams t LEFT JOIN ldap_servers s ON s.id = t.server_id WHERE t.tenant_id = ? ORDER BY t.name", tenantId]])["results"][0]{"values"}
  if ts == nil: return
  for t in ts:
    var members = newJArray()
    let ms = c.query(%*[["SELECT user_name, source FROM team_members WHERE team_id = ? ORDER BY user_name", t[0].getStr]])["results"][0]{"values"}
    if ms != nil:
      for m in ms: members.add %*{"user": m[0].getStr, "source": m[1].getStr}
    var roles = newJArray()
    let rs = c.query(%*[["SELECT role, scope FROM role_bindings WHERE user_name = ? ORDER BY scope, role", teamSubject(slug, t[1].getStr)]])["results"][0]{"values"}
    if rs != nil:
      for r in rs: roles.add %*{"role": r[0].getStr, "scope": r[1].getStr}
    var item = %*{"name": t[1].getStr, "description": t[2].getStr, "members": members, "roles": roles}
    if t[3].getStr.len > 0: item["ldap"] = %*{"group_dn": t[3].getStr, "directory": t[4].getStr}
    result.add item

proc putTeam*(c: var RqClient; tenantId, name: string; j: JsonNode; now: int64): tuple[error: string, status: int, created: bool] =
  ## makes the team or changes its description and the group it takes members from (`ldap`: {group_dn, directory?}; `ldap: null` makes it a team of hand-made members only)
  if not validTeamName(name): return ("a team is named by lowercase letters, digits, - and _, starting with a letter, at most 40", 400, false)
  if j == nil or j.kind != JObject: return ("a JSON object is required", 400, false)
  let have = c.teamId(tenantId, name)
  if have.len == 0 and c.query(%*[["SELECT count(*) FROM teams WHERE tenant_id = ?", tenantId]])["results"][0]["values"][0][0].getInt >= maxTeamsPerOrg:
    return ("at most " & $maxTeamsPerOrg & " teams per organisation", 409, false)
  var desc, groupDn, serverId = ""
  var keepLdap = false
  if have.len > 0:
    let cur = c.query(%*[["SELECT description, group_dn, server_id FROM teams WHERE id = ?", have]])["results"][0]["values"][0]
    desc = cur[0].getStr
    groupDn = cur[1].getStr
    serverId = cur[2].getStr
    keepLdap = true
  if j.hasKey("description"):
    if j["description"].kind != JString or j["description"].getStr.len > 300: return ("description is text of at most 300 characters", 400, false)
    desc = j["description"].getStr
  if j.hasKey("ldap"):
    keepLdap = false
    let l = j["ldap"]
    if l.isNil or l.kind == JNull:
      groupDn = ""
      serverId = ""
    elif l.kind != JObject or not l.isString("group_dn"):
      return ("ldap is {\"group_dn\": \"cn=...\", \"directory\": \"corp\" (optional)} or null", 400, false)
    else:
      groupDn = l["group_dn"].getStr
      if groupDn.len < 3 or groupDn.len > 500 or '=' notin groupDn: return ("group_dn is the DN of a group of a directory", 400, false)
      serverId = ""
      if l.isString("directory") and l["directory"].getStr.len > 0:
        let s = c.query(%*[["SELECT id FROM ldap_servers WHERE tenant_id = ? AND name = ?", tenantId, l["directory"].getStr]])["results"][0]{"values"}
        if s == nil or s.len == 0: return ("no such directory: " & l["directory"].getStr, 404, false)
        serverId = s[0][0].getStr
  discard keepLdap
  let normalised = if groupDn.len > 0: normDn(groupDn) else: ""
  if have.len == 0:
    discard c.execute(%*[["INSERT INTO teams (id, tenant_id, name, description, group_dn, server_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", newId(), tenantId, name, desc, normalised, serverId, now]])
    return ("", 0, true)
  discard c.execute(%*[["UPDATE teams SET description = ?, group_dn = ?, server_id = ? WHERE id = ?", desc, normalised, serverId, have]])
  ("", 0, false)

proc deleteTeam*(c: var RqClient; tenantId, slug, name: string): bool =
  ## the team, its members and its roles
  let id = c.teamId(tenantId, name)
  if id.len == 0: return false
  discard c.execute(%*[
    ["DELETE FROM role_bindings WHERE user_name = ?", teamSubject(slug, name)],
    ["DELETE FROM team_members WHERE team_id = ?", id],
    ["DELETE FROM teams WHERE id = ?", id]], transaction = true)
  true

proc addTeamMember*(c: var RqClient; tenantId, name, user: string): tuple[error: string, status: int] =
  ## a member added by hand: an account that exists
  let id = c.teamId(tenantId, name)
  if id.len == 0: return ("no such team: " & name, 404)
  if not c.userRoles(user).found: return ("no such user: " & user, 404)
  if c.query(%*[["SELECT count(*) FROM team_members WHERE team_id = ?", id]])["results"][0]["values"][0][0].getInt >= maxMembersPerTeam:
    return ("at most " & $maxMembersPerTeam & " members per team", 409)
  discard c.execute(%*[["INSERT INTO team_members (team_id, user_name, source) VALUES (?, ?, '') ON CONFLICT(team_id, user_name) DO UPDATE SET source = ''", id, user]])
  ("", 0)

proc removeTeamMember*(c: var RqClient; tenantId, name, user: string): tuple[found: bool, error: string] =
  ## takes a member away. One the directory gives is not a thing to take away by hand (it would come back at the next login): the group is what decides.
  let id = c.teamId(tenantId, name)
  if id.len == 0: return (false, "no such team: " & name)
  let v = c.query(%*[["SELECT source FROM team_members WHERE team_id = ? AND user_name = ?", id, user]])["results"][0]{"values"}
  if v == nil or v.len == 0: return (false, "")
  if v[0][0].getStr.len > 0: return (true, "this member comes from the group of a directory: take them out of the group, or change the group of the team")
  discard c.execute(%*[["DELETE FROM team_members WHERE team_id = ? AND user_name = ?", id, user]])
  (true, "")
