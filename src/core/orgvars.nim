## Plain variables of an organisation (VAR-001, VAR-002, VAR-003, VAR-004): a name and a text value, kept in the database and put into the environment of every step of
## every run of the organisation as an ordinary variable (`$URL`). The lowest level of the precedence (VAR-004): a launch parameter of the same name overrides it, and the run's
## view shows which value came from where. They are not secrets - the value is shown to whoever reads them; a secret is asked for by name (`secrets = {...}`, 6.7). Groups
## and projects, which VAR-001 puts between the organisation and the run, do not exist yet, so this is the one level above the launch parameters.
import std/[json, strutils, times]
import ../common/[rqlite, envname]
import runparams, groups

const
  maxVariables* = 100
  maxValueBytes* = 8192                 ## VAR-003
  maxTotalBytes* = 65536                ## all the values of an organisation

func checkVariable*(name, value: string): string =
  ## "" if this may be a variable, else the reason (for the 400 answer)
  if not validEnvName(name, 64): return "the name of a variable is capital letters, digits and _, not starting with a digit, at most 64 characters"
  if deniedEnvName(name): return name & " cannot be set in a step's environment (STO-004)"
  if value.len > maxValueBytes: return "the value is longer than " & $maxValueBytes & " bytes"
  for ch in value:
    if (ch < ' ' and ch notin {'\n', '\t'}) or ch == '\x7f': return "the value has a control character"
  ""

type VarScope* = enum
  vsShard = "shard", vsOrganization = "organization", vsGroup = "group"

func scopeTable(scope: VarScope): string =
  case scope
  of vsShard: "shard_variables"
  of vsOrganization: "org_variables"
  of vsGroup: "group_variables"

func scopeKey(scope: VarScope): string =
  ## the column that says whose the variable is; the shard has one set and no column
  case scope
  of vsShard: ""
  of vsOrganization: "tenant_id"
  of vsGroup: "group_id"

func scopeWhere(scope: VarScope): string = (if scope == vsShard: "1 = 1" else: scopeKey(scope) & " = ?")

proc keyArgs(scope: VarScope; key: string): seq[string] = (if scope == vsShard: @[] else: @[key])

proc query1(c: var RqClient; sql: string; args: seq[string]): JsonNode =
  var st = newJArray()
  st.add %sql
  for a in args: st.add %a
  c.query(%*[st])

proc exec1(c: var RqClient; sql: string; args: seq[JsonNode]): JsonNode =
  var st = newJArray()
  st.add %sql
  for a in args: st.add a
  c.execute(%*[st])

proc listScopeVariables*(c: var RqClient; scope: VarScope; key: string): seq[(string, string)] =
  ## `key` is the organisation's id or the group's id; the shard's variables have none
  let vals = c.query1("SELECT name, value FROM " & scopeTable(scope) & " WHERE " & scopeWhere(scope) & " ORDER BY name", keyArgs(scope, key))["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add (v[0].getStr, v[1].getStr)

proc setScopeVariable*(c: var RqClient; scope: VarScope; key, name, value: string; now: int64): string =
  ## "" if it is set, else why not: the checks above, at most 100 variables, at most 64 KiB of values in all (in one place: one organisation, one group, the shard)
  let bad = checkVariable(name, value)
  if bad.len > 0: return bad
  let tbl = scopeTable(scope)
  let st = c.query1("SELECT count(*), COALESCE(sum(length(value)), 0), COALESCE(sum(CASE WHEN name = ? THEN length(value) ELSE 0 END), 0), " &
    "COALESCE(sum(CASE WHEN name = ? THEN 1 ELSE 0 END), 0) FROM " & tbl & " WHERE " & scopeWhere(scope), @[name, name] & keyArgs(scope, key))["results"][0]{"values"}[0]
  let count = st[0].getInt - st[3].getInt + 1
  let total = st[1].getBiggestInt - st[2].getBiggestInt + value.len
  let whose = case scope
              of vsShard: "the shard has"
              of vsOrganization: "an organisation has"
              of vsGroup: "a group has"
  if count > maxVariables: return whose & " at most " & $maxVariables & " variables"
  if total > maxTotalBytes: return "the values of " & (if scope == vsShard: "the shard" elif scope == vsGroup: "a group" else: "an organisation") & " are at most " & $maxTotalBytes & " bytes in all"
  if scope == vsShard:
    discard c.exec1("INSERT INTO shard_variables (name, value, updated_at) VALUES (?, ?, ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
                    @[%name, %value, %now])
  else:
    discard c.exec1("INSERT INTO " & tbl & " (" & scopeKey(scope) & ", name, value, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(" & scopeKey(scope) &
                    ", name) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at", @[%key, %name, %value, %now])
  ""

proc deleteScopeVariable*(c: var RqClient; scope: VarScope; key, name: string): bool =
  c.exec1("DELETE FROM " & scopeTable(scope) & " WHERE " & scopeWhere(scope) & " AND name = ?", (if scope == vsShard: @[%name] else: @[%key, %name]))["results"][0]{"rows_affected"}.getInt > 0

# the organisation's own, as before
proc listVariables*(c: var RqClient; tenantId: string): seq[(string, string)] = c.listScopeVariables(vsOrganization, tenantId)
proc setVariable*(c: var RqClient; tenantId, name, value: string; now: int64): string = c.setScopeVariable(vsOrganization, tenantId, name, value, now)
proc deleteVariable*(c: var RqClient; tenantId, name: string): bool = c.deleteScopeVariable(vsOrganization, tenantId, name)

proc runOwner(c: var RqClient; runId: string): tuple[tenantId, groupId: string] =
  let v = c.query(%*[["SELECT tenant_id, group_id FROM runs WHERE id = ?", runId]])["results"][0]{"values"}
  if v != nil and v.len > 0: (v[0][0].getStr, v[0][1].getStr) else: ("", "")

type EffectiveVariable* = tuple[name, value, source, group: string]

proc effectiveVariables*(c: var RqClient; runId: string): seq[EffectiveVariable] =
  ## what a step of the run sees as plain variables, with where each came from (VAR-001, VAR-004): the variables of the shard, over them the organisation's, over them those of
  ## the groups from the top one to the run's own (the nearer wins), and over all of them the launch parameters. `source` is shard, organization, group (then `group` is its path)
  ## or launch.
  var byName: seq[EffectiveVariable]
  proc lay(items: seq[(string, string)]; source, group: string) =
    for (k, v) in items:
      var found = false
      for e in byName.mitems:
        if e.name == k:
          e = (k, v, source, group)
          found = true
      if not found: byName.add (k, v, source, group)
  let owner = c.runOwner(runId)
  lay(c.listScopeVariables(vsShard, ""), "shard", "")
  lay(c.listVariables(owner.tenantId), "organization", "")
  for g in c.groupChain(owner.tenantId, owner.groupId): lay(c.listScopeVariables(vsGroup, g.id), "group", g.path)
  lay(c.runParams(runId), "launch", "")
  byName

proc stepEnv*(c: var RqClient; runId: string): seq[(string, string)] =
  for e in c.effectiveVariables(runId): result.add (e.name, e.value)
