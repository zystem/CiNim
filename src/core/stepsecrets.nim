## Step secrets (VAR-002, 6.7): the secrets of an organisation that a step asks for by name (`secrets = {"REGISTRY_PASSWORD"}`).
##
## A secret belongs to the organisation or to a group or project (D-86): a run sees the nearest one by name, up the tree, and one marked `protected` only when it is on a protected ref
## of its project (core/projectpolicy.nim).
##
## The value is sealed with the organisation's data key and kept in the shard's database (core/secretvault.nim), so it is backed up and restored with
## it; the master key is kept apart. Lua sees names only. When a step starts, its shim asks core for the values over the authenticated channel, with a
## credential bound to that run, step and attempt (`stepToken`), and puts them into the environment of the command only: the Pod's specification holds a
## placeholder per name, never a value, and nothing is left in Kubernetes. The shim masks the values in the log (docs/secrets-masking.md). A new value is
## a new version; a step that starts after the change gets it (VAR-002: "the current values at that moment").
import std/[json, strutils, tables, algorithm]
import ../common/[rqlite, envname]

const
  maxValueBytes* = 8 * 1024         ## VAR-003
  maxSecretsPerStep* = 32

func checkName*(name: string): string =
  ## "" if the name may be a secret, else what is wrong
  if not validEnvName(name, 64): "a secret is named like an environment variable: capital letters, digits and _, not starting with a digit, at most 64 characters"
  elif deniedEnvName(name): name & " cannot be set in a step's environment (STO-004)"
  else: ""

func checkValue*(value: string): string =
  if value.len == 0: return "the value is empty"
  if value.len > maxValueBytes: return "the value is longer than " & $maxValueBytes & " bytes"
  for c in value:
    if (c < ' ' and c != '\t' and c != '\n') or c == '\x7f': return "the value has a control character (a line break and a tab are allowed)"
  ""

proc secretNamesOf*(optsJson: string): seq[string] =
  ## the names a step asked for, from its options JSON ("" = none); a damaged JSON asks for nothing
  if optsJson.len == 0: return
  try:
    let j = parseJson(optsJson)
    if j.kind == JObject and j.hasKey("secrets") and j["secrets"].kind == JArray:
      for n in j["secrets"]:
        if n.kind == JString: result.add n.getStr
  except JsonParsingError: discard

# ------------------------------------------------------------------ the rows

type SecretInfo* = object
  ## a secret as a step sees it: the nearest one up the tree of groups with this name (a project's own, a group above it, the organisation's)
  groupId*, scope*: string          ## the group that holds it ('' and "" for the organisation's) and its path
  version*: int
  protected*: bool                  ## given to runs on a protected ref only (D-86)

proc chainOf*(c: var RqClient; tenantId, groupId: string): seq[tuple[id, path: string]] =
  ## the group of a run and the groups above it, nearest first, and last the organisation ('' and ""): where a secret is looked for
  if groupId.len > 0:
    let own = c.query(%*[["SELECT path FROM groups WHERE id = ? AND tenant_id = ?", groupId, tenantId]])["results"][0]{"values"}
    if own != nil and own.len > 0:
      let parts = own[0][0].getStr.strip(chars = {'/'}).split('/')
      for i in countdown(parts.len, 1):
        let path = parts[0 ..< i].join("/")
        let g = c.query(%*[["SELECT id FROM groups WHERE tenant_id = ? AND path = ?", tenantId, path]])["results"][0]{"values"}
        if g != nil and g.len > 0: result.add (g[0][0].getStr, path)
  result.add ("", "")

proc visibleSecrets*(c: var RqClient; tenantId, groupId: string): Table[string, SecretInfo] =
  ## what a run of this group can ask for, by name: the nearest holder wins, as for variables
  let chain = c.chainOf(tenantId, groupId)
  var marks: seq[string]
  var stmt = newJArray()
  for _ in chain: marks.add "?"
  stmt.add %("SELECT group_id, name, version, protected FROM step_secrets WHERE tenant_id = ? AND group_id IN (" & marks.join(",") & ")")
  stmt.add %tenantId
  for g in chain: stmt.add %g.id
  let vals = c.query(%*[stmt])["results"][0]{"values"}
  if vals == nil: return
  for depth, g in chain:                               # nearest first: the first holder of a name keeps it
    for v in vals:
      if v[0].getStr == g.id and v[1].getStr notin result:
        result[v[1].getStr] = SecretInfo(groupId: g.id, scope: g.path, version: v[2].getInt, protected: v[3].getInt > 0)

proc listStepSecrets*(c: var RqClient; tenantId: string; groupId = ""): JsonNode =
  ## names, versions and the time of the last change of the secrets held exactly here (the organisation, or one group); never a value
  result = newJArray()
  let r = c.query(%*[["SELECT name, version, updated_at, protected FROM step_secrets WHERE tenant_id = ? AND group_id = ? ORDER BY name", tenantId, groupId]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add %*{"name": v[0].getStr, "version": v[1].getInt, "updated_at": v[2].getBiggestInt, "protected": v[3].getInt > 0}

proc effectiveSecrets*(c: var RqClient; tenantId, groupId: string): JsonNode =
  ## what a run of this project can ask for, and where each secret comes from (`scope`: the path of the group, "" for the organisation)
  result = newJArray()
  let seen = c.visibleSecrets(tenantId, groupId)
  var names: seq[string]
  for n in seen.keys: names.add n
  names.sort()
  for n in names: result.add %*{"name": n, "version": seen[n].version, "scope": seen[n].scope, "protected": seen[n].protected}

proc forgetStepSecret*(c: var RqClient; tenantId, name: string; groupId = ""): bool =
  let r = c.execute(%*[["DELETE FROM step_secrets WHERE tenant_id = ? AND group_id = ? AND name = ?", tenantId, groupId, name]])
  r["results"][0]{"rows_affected"}.getInt > 0

proc missingSecrets*(have: Table[string, SecretInfo]; wanted: seq[string]; trusted = true): seq[string] =
  ## the names a step asks for that it cannot have: there is none by the name, or it is protected and the run is not on a protected ref
  for n in wanted:
    if n notin have or (have[n].protected and not trusted): result.add n
