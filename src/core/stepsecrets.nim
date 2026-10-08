## Step secrets (VAR-002, 6.7): the secrets of an organisation that a step asks for by name (`secrets = {"REGISTRY_PASSWORD"}`).
##
## The value is sealed with the organisation's data key and kept in the shard's database (core/secretvault.nim), so it is backed up and restored with
## it; the master key is kept apart. Lua sees names only. When a step starts, its shim asks core for the values over the authenticated channel, with a
## credential bound to that run, step and attempt (`stepToken`), and puts them into the environment of the command only: the Pod's specification holds a
## placeholder per name, never a value, and nothing is left in Kubernetes. The shim masks the values in the log (docs/secrets-masking.md). A new value is
## a new version; a step that starts after the change gets it (VAR-002: "the current values at that moment").
import std/[json, strutils, tables]
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

proc secretVersions*(c: var RqClient; tenantId: string): Table[string, int] =
  let r = c.query(%*[["SELECT name, version FROM step_secrets WHERE tenant_id = ?", tenantId]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for v in vals: result[v[0].getStr] = v[1].getInt

proc listStepSecrets*(c: var RqClient; tenantId: string): JsonNode =
  ## names, versions and the time of the last change; never a value
  result = newJArray()
  let r = c.query(%*[["SELECT name, version, updated_at FROM step_secrets WHERE tenant_id = ? ORDER BY name", tenantId]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add %*{"name": v[0].getStr, "version": v[1].getInt, "updated_at": v[2].getBiggestInt}

proc forgetStepSecret*(c: var RqClient; tenantId, name: string): bool =
  let r = c.execute(%*[["DELETE FROM step_secrets WHERE tenant_id = ? AND name = ?", tenantId, name]])
  r["results"][0]{"rows_affected"}.getInt > 0

proc missingSecrets*(have: Table[string, int]; wanted: seq[string]): seq[string] =
  for n in wanted:
    if n notin have: result.add n
