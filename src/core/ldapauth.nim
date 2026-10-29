## Directories (LDAP) of an organisation (D-87): people log in with the password the directory knows, and the groups they are in there give them roles in the organisation.
##
## An organisation has any number of directories (`ldap_servers`, tried in the order of `priority`, then of the name) and a map of groups to roles (`ldap_group_map`; the group is named by its DN,
## the role is any role, the place is the organisation). A person logs in as `<login>@<slug>` (the slug of the organisation): the core asks the directory to find the person
## (a search with the service account, or none), tries the password by a bind AS that person on a connection of its own, reads the groups, and keeps the person as the account
## `<login>@<slug>` with no password of its own. The roles of the account that come from the directory are rows of `role_bindings` marked `ldap:<server id>`: login and the periodic sync add what the
## groups give and take away what they do not give any more, and touch nothing else, so a role an administrator gave by hand stays. A person the directory has lost (the entry is gone) is switched
## off (`disabled` = 2: the sync that finds them again switches them on) and their roles from the directory are taken away.
##
## The password of the service account is sealed with the organisation\'s data key (secretvault.nim) and never answered. The core connects to the address in the settings, so adding a directory is the
## shard\'s permission (`ldap.write`), and the map of groups is the organisation\'s (`ldap.map`).
import std/[json, strutils, times, atomics, algorithm, os]
import ../common/[rqlite, ldapclient]
import schema, secretvault, kekprovider, apiauth, audit

type
  LdapServer* = object
    id*, tenantId*, slug*, name*, url*, caPem*, bindDn*, bindSecretEnc*, userBase*, userFilter*, uidAttr*, groupBase*, groupFilter*, groupAttr*, lastSyncResult*: string
    priority*, lastSyncAt*: int64
    startTls*, enabled*, autoCreate*, tlsInsecure*: bool

  LdapOutcome* = enum
    loOk, loNoDirectory, loBadCredentials, loUnavailable, loNoRole, loNameTaken, loNoAccount

  LdapLogin* = object
    outcome*: LdapOutcome
    user*: string                    ## the account, `<login>@<slug>`
    detail*: string                  ## why, for the log and the audit; never shown as the reason of a refused password
    roles*: seq[string]

  SyncReport* = object
    checked*, switchedOff*, switchedOn*, changed*: int
    error*: string

const
  defaultUserFilter* = "(&(objectClass=person)({uid_attr}={u}))"
  defaultGroupFilter* = "(member={dn})"
  maxServersPerOrg* = 8
  maxMapsPerOrg* = 500
  syncUserBudget = 5000                    ## users one sync looks at; more is a sign of a wrong filter, not of a big organisation

var syncStop: Atomic[bool]

func normDn*(dn: string): string =
  ## a DN to compare: lowercase, no space around `,` and `=`. (Escapes inside values are left as they are; a directory returns the same text for the same entry.)
  var parts: seq[string]
  for p in dn.split(','):
    let eq = p.find('=')
    parts.add (if eq < 0: p.strip else: p[0 ..< eq].strip & "=" & p[eq + 1 .. ^1].strip)
  parts.join(",").toLowerAscii

func accountName*(uid, slug: string): string = uid & "@" & slug

func sourceOf*(serverId: string): string = "ldap:" & serverId

func splitAccount*(name: string): tuple[uid, slug: string] =
  let at = name.rfind('@')
  if at < 1: return
  (name[0 ..< at], name[at + 1 .. ^1])

func fill(pattern, uid, uidAttr, dn: string): string =
  ## `{u}` the login, `{uid_attr}` the attribute of the login, `{dn}` the DN of the person, each made safe for a filter
  pattern.replace("{uid_attr}", uidAttr).replace("{u}", escapeFilterValue(uid)).replace("{dn}", escapeFilterValue(dn))

# ------------------------------------------------------------------ the settings

proc serverOf(v: JsonNode): LdapServer =
  LdapServer(id: v[0].getStr, tenantId: v[1].getStr, slug: v[2].getStr, name: v[3].getStr, priority: v[4].getBiggestInt, url: v[5].getStr, startTls: v[6].getInt > 0,
             caPem: v[7].getStr, bindDn: v[8].getStr, bindSecretEnc: v[9].getStr, userBase: v[10].getStr, userFilter: v[11].getStr, uidAttr: v[12].getStr,
             groupBase: v[13].getStr, groupFilter: v[14].getStr, groupAttr: v[15].getStr, enabled: v[16].getInt > 0, lastSyncAt: v[17].getBiggestInt, lastSyncResult: v[18].getStr, autoCreate: v[19].getInt > 0, tlsInsecure: v[20].getInt > 0)

const serverColumns = "s.id, s.tenant_id, o.slug, s.name, s.priority, s.url, s.start_tls, s.ca_pem, s.bind_dn, s.bind_secret_enc, s.user_base, s.user_filter, s.uid_attr, " &
                      "s.group_base, s.group_filter, s.group_attr, s.enabled, s.last_sync_at, s.last_sync_result, s.auto_create, s.tls_insecure"

proc serversOf*(c: var RqClient; tenantId: string; onlyEnabled = false): seq[LdapServer] =
  let vals = c.query(%*[["SELECT " & serverColumns & " FROM ldap_servers s JOIN organizations o ON o.id = s.tenant_id WHERE s.tenant_id = ?" &
                         (if onlyEnabled: " AND s.enabled = 1" else: "") & " ORDER BY s.priority, s.name", tenantId]])["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add serverOf(v)

proc allEnabledServers*(c: var RqClient): seq[LdapServer] =
  let vals = c.query(%*[["SELECT " & serverColumns & " FROM ldap_servers s JOIN organizations o ON o.id = s.tenant_id WHERE s.enabled = 1 AND o.state = 'active' ORDER BY s.tenant_id, s.priority, s.name"]])["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add serverOf(v)

proc serverNamed*(c: var RqClient; tenantId, name: string): tuple[found: bool, server: LdapServer] =
  let vals = c.query(%*[["SELECT " & serverColumns & " FROM ldap_servers s JOIN organizations o ON o.id = s.tenant_id WHERE s.tenant_id = ? AND s.name = ?", tenantId, name]])["results"][0]{"values"}
  if vals != nil and vals.len > 0: (true, serverOf(vals[0])) else: (false, LdapServer())

func warningsOf*(s: LdapServer): seq[string] =
  ## what is allowed but not wise; shown wherever the directory is shown
  if s.url.startsWith("ldap://") and not s.startTls:
    result.add "the connection is not encrypted: the passwords of the people who log in and of the service account cross the network in the clear; use ldaps:// or start_tls"
  if s.tlsInsecure and (s.url.startsWith("ldaps://") or s.startTls):
    result.add "the certificate of the directory is not checked: anyone on the network can pose as it and read the passwords; put its certificate (or its CA) in ca_pem and leave tls_verify on"

func view*(s: LdapServer): JsonNode =
  %*{"warnings": s.warningsOf, "name": s.name, "priority": s.priority, "url": s.url, "start_tls": s.startTls, "has_ca": s.caPem.len > 0, "bind_dn": s.bindDn, "has_bind_password": s.bindSecretEnc.len > 0,
     "user_base": s.userBase, "user_filter": s.userFilter, "uid_attr": s.uidAttr, "group_base": s.groupBase, "group_filter": s.groupFilter, "group_attr": s.groupAttr,
     "enabled": s.enabled, "auto_create": s.autoCreate, "tls_verify": not s.tlsInsecure, "last_sync_at": s.lastSyncAt, "last_sync_result": s.lastSyncResult}

func validName(n: string): bool =
  if n.len < 1 or n.len > 40 or n[0] notin {'a' .. 'z'}: return false
  for ch in n:
    if ch notin {'a' .. 'z', '0' .. '9', '-', '_'}: return false
  true

func validAttr(a: string): bool =
  if a.len < 1 or a.len > 64: return false
  for ch in a:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', ';'}: return false
  true

proc filterProblem(pattern, what: string): string =
  ## the filter, with a login and a DN put in, has to be one this client can send
  try: discard encodeFilter(fill(pattern, "x", "uid", "uid=x,dc=y"))
  except LdapError as e: return what & ": " & e.msg

proc putServer*(c: var RqClient; kek: KekProvider; vaultReady: bool; tenantId, name: string; j: JsonNode; now: int64): tuple[error: string, status: int, created: bool] =
  ## Makes the directory `name` of the organisation or changes it (a field that is left out keeps its value; the password of the service account is only ever written). `status` 0 or the HTTP
  ## status to answer with when `error` is set.
  if not validName(name): return ("a directory is named by lowercase letters, digits, - and _, starting with a letter, at most 40", 400, false)
  if j == nil or j.kind != JObject: return ("a JSON object is required", 400, false)
  let have = c.serverNamed(tenantId, name)
  var s = if have.found: have.server else: LdapServer(id: newId(), tenantId: tenantId, name: name, uidAttr: "uid", enabled: true, userFilter: defaultUserFilter, groupFilter: defaultGroupFilter)
  if not have.found:
    if c.serversOf(tenantId).len >= maxServersPerOrg: return ("at most " & $maxServersPerOrg & " directories per organisation", 409, false)
  template str(key: string; into: untyped; maxLen = 1000) =
    if j.hasKey(key):
      if j[key].kind != JString: return (key & " must be a string", 400, false)
      into = j[key].getStr
      if into.len > maxLen: return (key & " is too long", 400, false)
  str("url", s.url, 300)
  str("bind_dn", s.bindDn, 500)
  str("ca_pem", s.caPem, 30000)
  str("user_base", s.userBase, 500)
  str("user_filter", s.userFilter, 1000)
  str("uid_attr", s.uidAttr, 64)
  str("group_base", s.groupBase, 500)
  str("group_filter", s.groupFilter, 1000)
  str("group_attr", s.groupAttr, 64)
  for k in ["start_tls", "enabled", "auto_create", "tls_verify"]:
    if j.hasKey(k) and j[k].kind != JBool: return (k & " must be true or false", 400, false)
  if j.hasKey("start_tls"): s.startTls = j["start_tls"].getBool
  if j.hasKey("enabled"): s.enabled = j["enabled"].getBool
  if j.hasKey("auto_create"): s.autoCreate = j["auto_create"].getBool
  if j.hasKey("tls_verify"): s.tlsInsecure = not j["tls_verify"].getBool
  if j.hasKey("priority"):
    if j["priority"].kind != JInt: return ("priority must be an integer", 400, false)
    s.priority = j["priority"].getBiggestInt
  if s.url.len == 0: return ("url is required (ldaps://host[:port], or ldap://host[:port] with start_tls)", 400, false)
  if s.userBase.len == 0: return ("user_base is required: the DN under which people are searched", 400, false)
  if not validAttr(s.uidAttr): return ("uid_attr is the attribute a person logs in with, such as uid or sAMAccountName", 400, false)
  if "{u}" notin s.userFilter: return ("user_filter has to contain {u}, the login", 400, false)
  let uf = filterProblem(s.userFilter, "user_filter")
  if uf.len > 0: return (uf, 400, false)
  if s.groupFilter.len > 0:
    if s.groupBase.len == 0: return ("group_filter needs group_base", 400, false)
    if "{dn}" notin s.groupFilter and "{u}" notin s.groupFilter: return ("group_filter has to contain {dn} (the DN of the person) or {u} (the login)", 400, false)
    let gf = filterProblem(s.groupFilter, "group_filter")
    if gf.len > 0: return (gf, 400, false)
  if s.groupAttr.len > 0 and not validAttr(s.groupAttr): return ("group_attr is an attribute name, such as memberOf", 400, false)
  if s.groupFilter.len == 0 and s.groupAttr.len == 0: return ("a directory needs group_filter (with group_base) or group_attr, or no group could be read", 400, false)
  try: checkLdapUrl(s.url)
  except LdapError as e: return (e.msg, 400, false)
  if j.hasKey("bind_password"):
    if j["bind_password"].kind != JString: return ("bind_password must be a string", 400, false)
    if j["bind_password"].getStr.len > 0:
      if not vaultReady: return ("the secrets of the core are not available now", 503, false)
      let sealed = c.sealOrgText(kek, tenantId, "ldap-bind:" & s.id, j["bind_password"].getStr)
      if not sealed.ok: return (sealed.error, (if sealed.retry: 503 else: 500), false)
      s.bindSecretEnc = sealed.sealed
    else:
      s.bindSecretEnc = ""
  if s.bindDn.len > 0 and s.bindSecretEnc.len == 0: return ("bind_dn needs bind_password", 400, false)
  discard c.execute(%*[["INSERT INTO ldap_servers (id, tenant_id, name, priority, url, start_tls, ca_pem, bind_dn, bind_secret_enc, user_base, user_filter, uid_attr, group_base, group_filter, group_attr, enabled, auto_create, tls_insecure, created_at) " &
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET priority = excluded.priority, url = excluded.url, start_tls = excluded.start_tls, ca_pem = excluded.ca_pem, " &
    "bind_dn = excluded.bind_dn, bind_secret_enc = excluded.bind_secret_enc, user_base = excluded.user_base, user_filter = excluded.user_filter, uid_attr = excluded.uid_attr, " &
    "group_base = excluded.group_base, group_filter = excluded.group_filter, group_attr = excluded.group_attr, enabled = excluded.enabled, auto_create = excluded.auto_create, tls_insecure = excluded.tls_insecure",
    s.id, tenantId, name, s.priority, s.url, (if s.startTls: 1 else: 0), s.caPem, s.bindDn, s.bindSecretEnc, s.userBase, s.userFilter, s.uidAttr, s.groupBase, s.groupFilter, s.groupAttr,
    (if s.enabled: 1 else: 0), (if s.autoCreate: 1 else: 0), (if s.tlsInsecure: 1 else: 0), now]])
  for w in s.warningsOf: stderr.writeLine "core: WARNING - the directory " & name & " (" & s.url & "): " & w
  ("", 0, not have.found)

proc deleteServer*(c: var RqClient; tenantId, name: string): bool =
  ## the directory, its rows of the map, the people it vouched for are switched off and lose what it gave them
  let s = c.serverNamed(tenantId, name)
  if not s.found: return false
  discard c.execute(%*[
    ["UPDATE users SET disabled = 2 WHERE source = ?", sourceOf(s.server.id)],
    ["DELETE FROM role_bindings WHERE source = ?", sourceOf(s.server.id)],
    ["DELETE FROM team_members WHERE source = ?", sourceOf(s.server.id)],
    ["UPDATE teams SET group_dn = '', server_id = '' WHERE server_id = ?", s.server.id],
    ["DELETE FROM ldap_group_map WHERE server_id = ?", s.server.id],
    ["DELETE FROM ldap_servers WHERE id = ?", s.server.id]], transaction = true)
  true

# ------------------------------------------------------------------ the map of groups to roles

proc mappings*(c: var RqClient; tenantId: string): JsonNode =
  result = newJArray()
  let vals = c.query(%*[["SELECT m.id, COALESCE(s.name, ''), m.group_dn, m.role FROM ldap_group_map m LEFT JOIN ldap_servers s ON s.id = m.server_id WHERE m.tenant_id = ? ORDER BY m.group_dn, m.role", tenantId]])["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add %*{"id": v[0].getStr, "directory": v[1].getStr, "group_dn": v[2].getStr, "role": v[3].getStr}

proc addMapping*(c: var RqClient; tenantId, directory, groupDn, role: string; now: int64): tuple[error: string, status: int, id: string] =
  ## `directory` "" = a group of any of the organisation\'s directories
  if groupDn.len < 3 or groupDn.len > 500 or '=' notin groupDn: return ("group_dn is the DN of a group, such as cn=ci-admins,ou=groups,dc=example,dc=org", 400, "")
  if not c.roleExists(role): return ("no such role: " & role, 400, "")
  var serverId = ""
  if directory.len > 0:
    let s = c.serverNamed(tenantId, directory)
    if not s.found: return ("no such directory: " & directory, 404, "")
    serverId = s.server.id
  let n = c.query(%*[["SELECT count(*) FROM ldap_group_map WHERE tenant_id = ?", tenantId]])["results"][0]["values"][0][0].getInt
  if n >= maxMapsPerOrg: return ("at most " & $maxMapsPerOrg & " mappings per organisation", 409, "")
  let norm = normDn(groupDn)
  let have = c.query(%*[["SELECT id FROM ldap_group_map WHERE tenant_id = ? AND server_id = ? AND group_dn = ? AND role = ?", tenantId, serverId, norm, role]])["results"][0]{"values"}
  if have != nil and have.len > 0: return ("", 0, have[0][0].getStr)
  let id = newId()
  discard c.execute(%*[["INSERT INTO ldap_group_map (id, tenant_id, server_id, group_dn, role, created_at) VALUES (?, ?, ?, ?, ?, ?)", id, tenantId, serverId, norm, role, now]])
  ("", 0, id)

proc deleteMapping*(c: var RqClient; tenantId, id: string): bool =
  c.execute(%*[["DELETE FROM ldap_group_map WHERE tenant_id = ? AND id = ?", tenantId, id]])["results"][0]{"rows_affected"}.getInt > 0

proc rolesFor(c: var RqClient; s: LdapServer; groups: seq[string]): seq[string] =
  ## the roles that the groups give in this organisation (a role that does not exist any more is passed over)
  if groups.len == 0: return
  let vals = c.query(%*[["SELECT group_dn, role FROM ldap_group_map WHERE tenant_id = ? AND (server_id = '' OR server_id = ?)", s.tenantId, s.id]])["results"][0]{"values"}
  if vals == nil: return
  for v in vals:
    if normDn(v[0].getStr) in groups and v[1].getStr notin result and c.roleExists(v[1].getStr): result.add v[1].getStr
  result.sort()

# ------------------------------------------------------------------ talking to a directory

proc settingsOf(s: LdapServer): LdapSettings =
  LdapSettings(url: s.url, startTls: s.startTls, caPem: s.caPem, insecureTls: s.tlsInsecure, timeoutMs: 8000)

proc serviceConnection(c: var RqClient; kek: KekProvider; vaultReady: bool; s: LdapServer): LdapConn =
  ## a connection that is bound as the service account (or not bound at all, for a directory that lets anyone search)
  result = openLdap(s.settingsOf)
  try:
    if s.bindDn.len > 0:
      if not vaultReady: raise newException(LdapError, "the secrets of the core are not available now")
      let pw = c.openOrgText(kek, s.tenantId, "ldap-bind:" & s.id, s.bindSecretEnc)
      if not pw.ok: raise newException(LdapError, "the password of the service account cannot be read: " & pw.error)
      result.bindSimple(s.bindDn, pw.plain)
  except CatchableError:
    result.close()
    raise

type Found = object
  found, ambiguous: bool
  dn: string
  entry: LdapEntry

proc findPerson(conn: LdapConn; s: LdapServer; uid: string): Found =
  let es = conn.search(s.userBase, scSub, fill(s.userFilter, uid, s.uidAttr, ""), (if s.groupAttr.len > 0: @[s.uidAttr, s.groupAttr] else: @[s.uidAttr]), sizeLimit = 2)
  if es.len == 0: return
  if es.len > 1: return Found(ambiguous: true)
  Found(found: true, dn: es[0].dn, entry: es[0])

proc groupsOf(conn: LdapConn; s: LdapServer; uid, dn: string; entry: LdapEntry): seq[string] =
  ## the DNs (normalised) of the groups the person is in: those the search finds, and those named in the person\'s own attribute
  if s.groupFilter.len > 0:
    for g in conn.search(s.groupBase, scSub, fill(s.groupFilter, uid, s.uidAttr, dn), @["cn"]):
      let n = normDn(g.dn)
      if n notin result: result.add n
  if s.groupAttr.len > 0:
    for v in entry.values(s.groupAttr):
      let n = normDn(v)
      if n notin result: result.add n

proc teamsFor(c: var RqClient; s: LdapServer; groups: seq[string]): seq[string] =
  ## the ids of the teams of the organisation that take their members from a group the person is in (D-91)
  if groups.len == 0: return
  let vals = c.query(%*[["SELECT id, group_dn FROM teams WHERE tenant_id = ? AND group_dn <> '' AND (server_id = '' OR server_id = ?)", s.tenantId, s.id]])["results"][0]{"values"}
  if vals == nil: return
  for v in vals:
    if normDn(v[1].getStr) in groups: result.add v[0].getStr

proc syncTeams(c: var RqClient; user, serverId: string; want: seq[string]): int =
  ## the person is a member, given by this directory, of exactly these teams: the ones they are not in any more are left, the ones they are in now are joined; a member added by hand stays
  let src = sourceOf(serverId)
  let have = c.query(%*[["SELECT team_id FROM team_members WHERE user_name = ? AND source = ?", user, src]])["results"][0]{"values"}
  var current: seq[string]
  if have != nil:
    for v in have: current.add v[0].getStr
  var stmts = newJArray()
  for t in current:
    if t notin want:
      stmts.add %*["DELETE FROM team_members WHERE team_id = ? AND user_name = ? AND source = ?", t, user, src]
      inc result
  for t in want:
    if t notin current:
      stmts.add %*["INSERT OR IGNORE INTO team_members (team_id, user_name, source) VALUES (?, ?, ?)", t, user, src]
      inc result
  if stmts.len > 0: discard c.execute(stmts, transaction = true)

proc syncBindings(c: var RqClient; user, serverId, slug: string; roles: seq[string]): int =
  ## makes the bindings of the account that come from this directory the roles given (in the organisation); returns how many rows changed
  let scope = "org:" & slug
  let src = sourceOf(serverId)
  let have = c.query(%*[["SELECT role FROM role_bindings WHERE user_name = ? AND source = ? AND scope = ?", user, src, scope]])["results"][0]{"values"}
  var current: seq[string]
  if have != nil:
    for v in have: current.add v[0].getStr
  var stmts = newJArray()
  for r in current:
    if r notin roles:
      stmts.add %*["DELETE FROM role_bindings WHERE user_name = ? AND source = ? AND scope = ? AND role = ?", user, src, scope, r]
      inc result
  for r in roles:
    if r notin current:
      stmts.add %*["INSERT OR IGNORE INTO role_bindings (user_name, role, scope, source) VALUES (?, ?, ?, ?)", user, r, scope, src]
      inc result
  if stmts.len > 0: discard c.execute(stmts, transaction = true)

# ------------------------------------------------------------------ login

proc ldapLogin*(c: var RqClient; kek: KekProvider; vaultReady: bool; slug, uidGiven, password: string; now: int64): LdapLogin =
  ## `<uid>@<slug>` and a password. `loNoDirectory`: the organisation has none enabled (the caller goes on with the local users). `loBadCredentials`: no directory knows the person with this
  ## password. `loUnavailable`: nobody could say (a directory did not answer). `loNoRole`: the password is right but no group of the person gives a role here (the roles from before are taken away).
  let uid = uidGiven.toLowerAscii
  let org = c.organizationRow(slug)
  if org.id.len == 0 or org.state != "active": return LdapLogin(outcome: loNoDirectory)
  let servers = c.serversOf(org.id, onlyEnabled = true)
  if servers.len == 0: return LdapLogin(outcome: loNoDirectory)
  if not validDirectoryId(uid) or password.len == 0: return LdapLogin(outcome: loBadCredentials, detail: "the login or the password is not one")
  let name = accountName(uid, slug)
  var sawBad, sawDown, sawTaken, sawNoAccount = false
  var detail: seq[string]
  for s in servers:
    var service: LdapConn
    try:
      service = c.serviceConnection(kek, vaultReady, s)
      let who = service.findPerson(s, uid)
      if who.ambiguous:
        detail.add s.name & ": the login names more than one person"
        sawBad = true
        continue
      if not who.found:
        sawBad = true
        continue
      # the password is tried by a bind of the person, on a connection of its own: the service connection keeps the rights of the service account
      let person = openLdap(s.settingsOf)
      try: person.bindSimple(who.dn, password)
      except LdapAuthError:
        person.close()
        sawBad = true
        continue
      except CatchableError:
        person.close()
        raise
      person.close()
      let existing = c.query(%*[["SELECT source FROM users WHERE name = ?", name]])["results"][0]{"values"}
      if existing != nil and existing.len > 0 and existing[0][0].getStr != sourceOf(s.id):
        sawTaken = true
        detail.add s.name & ": the account " & name & " belongs to another directory"
        continue
      let isNew = existing == nil or existing.len == 0
      if isNew and not s.autoCreate:
        # the password is right and the directory knows the person, but the organisation has not made an account for them (PUT .../ldap/accounts/{login}) and does not make one by itself
        sawNoAccount = true
        detail.add s.name & ": there is no account " & name & " and this directory does not make accounts at login"
        continue
      let groups = service.groupsOf(s, uid, who.dn, who.entry)
      let roles = c.rolesFor(s, groups)
      let teams = c.teamsFor(s, groups)
      if roles.len == 0 and teams.len == 0 and isNew:
        return LdapLogin(outcome: loNoRole, user: name, detail: s.name & ": no group of " & name & " gives a role here")
      discard c.execute(%*[["INSERT INTO users (name, password_hash, created_at, disabled, must_change, source, dn) VALUES (?, '', ?, 0, 0, ?, ?) " &
        "ON CONFLICT(name) DO UPDATE SET disabled = 0, dn = excluded.dn WHERE users.source = excluded.source", name, now, sourceOf(s.id), who.dn]])
      discard c.syncBindings(name, s.id, slug, roles)
      discard c.syncTeams(name, s.id, teams)
      # the account is let in if it has a role at all: from the groups, or one given by hand
      if c.userRoles(name).bindings.len == 0: return LdapLogin(outcome: loNoRole, user: name, detail: s.name & ": no group of " & name & " gives a role here")
      return LdapLogin(outcome: loOk, user: name, roles: roles, detail: s.name)
    except LdapAuthError:
      sawBad = true                                       # the service account itself is refused: the directory is not usable, which is "nobody could say"
      sawDown = true
      detail.add s.name & ": the service account was refused"
    except LdapError as e:
      sawDown = true
      detail.add s.name & ": " & e.msg
    finally:
      if service != nil: service.close()
  if sawNoAccount: return LdapLogin(outcome: loNoAccount, user: name, detail: detail.join("; "))
  if sawTaken: return LdapLogin(outcome: loNameTaken, user: name, detail: detail.join("; "))
  if sawDown: return LdapLogin(outcome: loUnavailable, detail: detail.join("; "))
  LdapLogin(outcome: loBadCredentials, detail: detail.join("; "))

# ------------------------------------------------------------------ accounts made by hand

type AccountOutcome* = enum
  aoMade, aoExists, aoNotFound, aoAmbiguous, aoTaken, aoUnavailable, aoBadLogin, aoNoDirectory

proc makeAccount*(c: var RqClient; kek: KekProvider; vaultReady: bool; tenantId, slug, loginGiven, directory: string; now: int64): tuple[outcome: AccountOutcome, user, detail: string, roles: seq[string]] =
  ## The account `<login>@<slug>` for a person the directory knows, made by someone who may (PUT .../ldap/accounts/{login}), not by the person's login: the directory
  ## (the named one, or the first that knows the person) is asked, and the roles the groups give are put on the account. Any directory may do this; `auto_create` is only about login.
  let uid = loginGiven.toLowerAscii
  if not validDirectoryId(uid): return (aoBadLogin, "", "a login is lowercase letters, digits and . _ - (at most 64)", @[])
  let name = accountName(uid, slug)
  var servers = c.serversOf(tenantId, onlyEnabled = true)
  if directory.len > 0:
    var named: seq[LdapServer]
    for s in servers:
      if s.name == directory: named.add s
    servers = named
  if servers.len == 0: return (aoNoDirectory, name, (if directory.len > 0: "no such enabled directory: " & directory else: "the organisation has no enabled directory"), @[])
  var down: seq[string]
  for s in servers:
    var service: LdapConn
    try:
      service = c.serviceConnection(kek, vaultReady, s)
      let who = service.findPerson(s, uid)
      if who.ambiguous: return (aoAmbiguous, name, s.name & ": the login names more than one person", @[])
      if not who.found: continue
      let existing = c.query(%*[["SELECT source FROM users WHERE name = ?", name]])["results"][0]{"values"}
      let have = existing != nil and existing.len > 0
      if have and existing[0][0].getStr != sourceOf(s.id): return (aoTaken, name, "the account " & name & " belongs to another directory (or is a local one)", @[])
      let groups = service.groupsOf(s, uid, who.dn, who.entry)
      let roles = c.rolesFor(s, groups)
      discard c.execute(%*[["INSERT INTO users (name, password_hash, created_at, disabled, must_change, source, dn) VALUES (?, '', ?, 0, 0, ?, ?) " &
        "ON CONFLICT(name) DO UPDATE SET disabled = 0, dn = excluded.dn WHERE users.source = excluded.source", name, now, sourceOf(s.id), who.dn]])
      discard c.syncBindings(name, s.id, slug, roles)
      discard c.syncTeams(name, s.id, c.teamsFor(s, groups))
      let outcome = if have: aoExists else: aoMade
      return (outcome, name, s.name, roles)
    except LdapError as e:
      down.add s.name & ": " & e.msg
    finally:
      if service != nil: service.close()
  if down.len > 0: return (aoUnavailable, name, down.join("; "), @[])
  (aoNotFound, name, "no directory of the organisation knows " & uid, @[])

proc removeAccount*(c: var RqClient; tenantId, slug, loginGiven: string): bool =
  ## the account of a directory of this organisation, its roles and its tokens; the person can come back by an account made by hand, or by a login if a directory makes accounts
  let name = accountName(loginGiven.toLowerAscii, slug)
  var sources: seq[string]
  for s in c.serversOf(tenantId): sources.add sourceOf(s.id)
  let v = c.query(%*[["SELECT source FROM users WHERE name = ?", name]])["results"][0]{"values"}
  if v == nil or v.len == 0 or v[0][0].getStr notin sources: return false
  let now = getTime().toUnix()
  discard c.execute(%*[
    ["UPDATE api_tokens SET revoked_at = ? WHERE scope = ? AND revoked_at = 0", now, "user:" & name],
    ["DELETE FROM role_bindings WHERE user_name = ?", name],
    ["DELETE FROM team_members WHERE user_name = ?", name],
    ["DELETE FROM users WHERE name = ?", name]], transaction = true)
  true

proc accounts*(c: var RqClient; tenantId: string): JsonNode =
  ## the accounts the directories of the organisation vouch for, and the roles they have from them
  result = newJArray()
  let vals = c.query(%*[["SELECT u.name, s.name, u.dn, u.disabled FROM users u JOIN ldap_servers s ON u.source = 'ldap:' || s.id WHERE s.tenant_id = ? ORDER BY u.name", tenantId]])["results"][0]{"values"}
  if vals != nil:
    for v in vals:
      var roles = newJArray()
      let rs = c.query(%*[["SELECT role FROM role_bindings WHERE user_name = ? AND source LIKE 'ldap:%' ORDER BY role", v[0].getStr]])["results"][0]{"values"}
      if rs != nil:
        for r in rs: roles.add %r[0].getStr
      result.add %*{"account": v[0].getStr, "directory": v[1].getStr, "dn": v[2].getStr, "switched_off": v[3].getInt > 0, "roles_from_directory": roles}

# ------------------------------------------------------------------ what a configuration would do (a check)

proc checkServer*(c: var RqClient; kek: KekProvider; vaultReady: bool; s: LdapServer; uid: string): JsonNode =
  ## connects, binds the service account and, if a login is given, finds that person and says which groups they are in and which roles that gives: nothing is changed
  result = %*{"directory": s.name, "connected": false}
  var service: LdapConn
  try:
    service = c.serviceConnection(kek, vaultReady, s)
    result["connected"] = %true
    if uid.len > 0:
      let u = uid.toLowerAscii
      let who = service.findPerson(s, u)
      if who.ambiguous: result["person"] = %*{"found": false, "problem": "the login names more than one person"}
      elif not who.found: result["person"] = %*{"found": false}
      else:
        let groups = service.groupsOf(s, u, who.dn, who.entry)
        var gs = newJArray()
        for g in groups: gs.add %g
        var rs = newJArray()
        for r in c.rolesFor(s, groups): rs.add %r
        var ts = newJArray()
        for id in c.teamsFor(s, groups):
          let nm = c.query(%*[["SELECT name FROM teams WHERE id = ?", id]])["results"][0]{"values"}
          if nm != nil and nm.len > 0: ts.add %nm[0][0].getStr
        result["person"] = %*{"found": true, "dn": who.dn, "groups": gs, "roles": rs, "teams": ts, "account": accountName(u, s.slug)}
  except LdapError as e:
    result["error"] = %e.msg
  finally:
    if service != nil: service.close()

# ------------------------------------------------------------------ sync

proc syncServer*(c: var RqClient; kek: KekProvider; vaultReady: bool; s: LdapServer; now: int64): SyncReport =
  ## every account this directory vouches for: gone from the directory = switched off and its roles from the directory taken away; found = switched on again if it was switched off here, roles
  ## made what the groups give now. Written in the directory\'s row, so that it can be seen.
  var service: LdapConn
  try:
    service = c.serviceConnection(kek, vaultReady, s)
    let vals = c.query(%*[["SELECT name, dn, disabled FROM users WHERE source = ? ORDER BY name LIMIT ?", sourceOf(s.id), syncUserBudget]])["results"][0]{"values"}
    if vals != nil:
      for v in vals:
        let user = v[0].getStr
        let dn = v[1].getStr
        if dn.len == 0: continue
        inc result.checked
        var entry: LdapEntry
        var gone = false
        try:
          let es = service.search(dn, scBase, "(objectClass=*)", (if s.groupAttr.len > 0: @[s.groupAttr] else: @["1.1"]), sizeLimit = 1)
          if es.len == 0: gone = true else: entry = es[0]
        except LdapResultError as e:
          if e.code == 32: gone = true else: raise
        if gone:
          if v[2].getInt != 2:
            inc result.switchedOff
          discard c.execute(%*[["UPDATE users SET disabled = 2 WHERE name = ? AND source = ?", user, sourceOf(s.id)], ["DELETE FROM role_bindings WHERE user_name = ? AND source = ?", user, sourceOf(s.id)],
                               ["DELETE FROM team_members WHERE user_name = ? AND source = ?", user, sourceOf(s.id)]], transaction = true)
          continue
        let sp = splitAccount(user)
        let groups = service.groupsOf(s, sp.uid, dn, entry)
        let roles = c.rolesFor(s, groups)
        result.changed += c.syncBindings(user, s.id, s.slug, roles)
        result.changed += c.syncTeams(user, s.id, c.teamsFor(s, groups))
        if v[2].getInt == 2:
          discard c.execute(%*[["UPDATE users SET disabled = 0 WHERE name = ? AND source = ? AND disabled = 2", user, sourceOf(s.id)]])
          inc result.switchedOn
  except LdapError as e:
    result.error = e.msg
  finally:
    if service != nil: service.close()
  let text = if result.error.len > 0: "failed: " & result.error else: "ok: " & $result.checked & " accounts, " & $result.switchedOff & " switched off, " & $result.switchedOn & " switched on, " & $result.changed & " roles changed"
  discard c.execute(%*[["UPDATE ldap_servers SET last_sync_at = ?, last_sync_result = ? WHERE id = ?", now, text.substr(0, 300), s.id]])
  if result.error.len == 0 and (result.switchedOff > 0 or result.changed > 0 or result.switchedOn > 0):
    c.record(now, "ldap-sync", "ldap.sync", s.slug & "/" & s.name, "ok", text)

# ------------------------------------------------------------------ the periodic sync

var syncThread: Thread[tuple[url: string, interval: int, stop: ptr Atomic[bool]]]
var syncRunning = false

proc runSync(arg: tuple[url: string, interval: int, stop: ptr Atomic[bool]]) {.thread.} =
  {.cast(gcsafe).}:
    var waited = 0
    while not arg.stop[].load:
      sleep(1000)
      inc waited
      if waited < arg.interval: continue
      waited = 0
      try:
        var c = newRq(arg.url)
        let vk = vaultKek()
        for s in c.allEnabledServers():
          if arg.stop[].load: break
          discard c.syncServer(vk.kek, vk.ready, s, getTime().toUnix())
      except CatchableError as e:
        stderr.writeLine "core: the sync of the directories failed: " & e.msg

proc startLdapSync*(rqliteUrl: string; intervalSeconds: int; stop: ptr Atomic[bool]) =
  ## every `intervalSeconds` (0: never) the accounts of every enabled directory are looked at again
  if intervalSeconds <= 0: return
  createThread(syncThread, runSync, (rqliteUrl, intervalSeconds, stop))
  syncRunning = true
  echo "core: syncing the accounts of the directories every ", intervalSeconds, " s"

proc joinLdapSync*() =
  if syncRunning: joinThread(syncThread)
