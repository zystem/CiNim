## Step secrets (VAR-002, 6.7): the secrets of an organisation that a step asks for by name (`secrets = {"REGISTRY_PASSWORD"}`).
##
## The value is kept in one place only, a Kubernetes Secret `cinim-s-<name>-v<version>` in the organisation's namespace, made by the core when the
## administrator sets it (`PUT /api/v1/organizations/{slug}/secrets/{NAME}`) and read by nobody but the kubelet, which gives it to the step's container
## as the environment variable of that name (`secretKeyRef`). The database holds the names and the current version, never a value; Lua sees names only; the
## shim masks the value in the log (docs/secrets-masking.md). A new value is a new version, because the core may create and delete Secrets in the
## namespace but not change them; the previous version stays until the next change, so that a step that was just assigned still finds its Secret.
##
## The step is told `NAME:version` (StartStep.secret_handles) when it is assigned, so a value changed after that does not reach a Pod that is
## already waiting to start, and a retry of a step gets the current one (VAR-002: "the current values at that moment").
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

func handleOf*(name: string; version: int): string = name & ":" & $version

func parseHandle*(h: string): tuple[ok: bool, name: string, version: int] =
  let colon = h.rfind(':')
  if colon <= 0: return
  let v = try: parseInt(h[colon + 1 .. ^1]) except ValueError: return
  if v < 0: return
  (true, h[0 ..< colon], v)

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

proc recordStepSecret*(c: var RqClient; tenantId, name: string; version: int; now: int64) =
  discard c.execute(%*[["INSERT INTO step_secrets (tenant_id, name, version, updated_at) VALUES (?, ?, ?, ?) " &
                        "ON CONFLICT(tenant_id, name) DO UPDATE SET version = excluded.version, updated_at = excluded.updated_at",
                        tenantId, name, version, now]])

proc forgetStepSecret*(c: var RqClient; tenantId, name: string): bool =
  let r = c.execute(%*[["DELETE FROM step_secrets WHERE tenant_id = ? AND name = ?", tenantId, name]])
  r["results"][0]{"rows_affected"}.getInt > 0

proc missingSecrets*(have: Table[string, int]; wanted: seq[string]): seq[string] =
  for n in wanted:
    if n notin have: result.add n

proc handlesFor*(have: Table[string, int]; wanted: seq[string]): seq[string] =
  ## `NAME:version` for the step; a name that has gone since the step was submitted gets version 0, a Secret that does not exist, so that the Pod says
  ## so (CreateContainerConfigError, in the step's `pod_reason`) instead of running without it
  for n in wanted: result.add handleOf(n, have.getOrDefault(n, 0))
