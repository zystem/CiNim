## Plain variables of an organisation (VAR-001, VAR-002, VAR-003, VAR-004): a name and a text value, kept in the database and put into the environment of every step of
## every run of the organisation as an ordinary variable (`$URL`). The lowest level of the precedence (VAR-004): a launch parameter of the same name overrides it, and the run's
## view shows which value came from where. They are not secrets - the value is shown to whoever reads them; a secret is asked for by name (`secrets = {...}`, 6.7). Groups
## and projects, which VAR-001 puts between the organisation and the run, do not exist yet, so this is the one level above the launch parameters.
import std/[json, strutils, times]
import ../common/[rqlite, envname]
import runparams

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

proc listVariables*(c: var RqClient; tenantId: string): seq[(string, string)] =
  let vals = c.query(%*[["SELECT name, value FROM org_variables WHERE tenant_id = ? ORDER BY name", tenantId]])["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add (v[0].getStr, v[1].getStr)

proc setVariable*(c: var RqClient; tenantId, name, value: string; now: int64): string =
  ## "" if it is set, else why not: the checks above, at most 100 variables, at most 64 KiB of values in all
  let bad = checkVariable(name, value)
  if bad.len > 0: return bad
  let st = c.query(%*[["SELECT count(*), COALESCE(sum(length(value)), 0), COALESCE(sum(CASE WHEN name = ? THEN length(value) ELSE 0 END), 0), " &
    "COALESCE(sum(CASE WHEN name = ? THEN 1 ELSE 0 END), 0) FROM org_variables WHERE tenant_id = ?", name, name, tenantId]])["results"][0]{"values"}[0]
  let count = st[0].getInt - st[3].getInt + 1
  let total = st[1].getBiggestInt - st[2].getBiggestInt + value.len
  if count > maxVariables: return "an organisation has at most " & $maxVariables & " variables"
  if total > maxTotalBytes: return "the values of an organisation are at most " & $maxTotalBytes & " bytes in all"
  discard c.execute(%*[["INSERT INTO org_variables (tenant_id, name, value, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(tenant_id, name) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
                        tenantId, name, value, now]])
  ""

proc deleteVariable*(c: var RqClient; tenantId, name: string): bool =
  c.execute(%*[["DELETE FROM org_variables WHERE tenant_id = ? AND name = ?", tenantId, name]])["results"][0]{"rows_affected"}.getInt > 0

proc tenantOfRun(c: var RqClient; runId: string): string =
  let v = c.query(%*[["SELECT tenant_id FROM runs WHERE id = ?", runId]])["results"][0]{"values"}
  if v != nil and v.len > 0: v[0][0].getStr else: ""

proc effectiveVariables*(c: var RqClient; runId: string): seq[tuple[name, value, source: string]] =
  ## what a step of the run sees as plain variables, with where each came from: the variables of the organisation, and over them (VAR-004) the launch parameters
  var byName: seq[tuple[name, value, source: string]]
  for (k, v) in c.listVariables(c.tenantOfRun(runId)): byName.add (k, v, "organization")
  for (k, v) in c.runParams(runId):
    var found = false
    for e in byName.mitems:
      if e.name == k:
        e = (k, v, "launch")
        found = true
    if not found: byName.add (k, v, "launch")
  byName

proc stepEnv*(c: var RqClient; runId: string): seq[(string, string)] =
  for e in c.effectiveVariables(runId): result.add (e.name, e.value)
