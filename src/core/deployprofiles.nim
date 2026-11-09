## The deploy profiles of an organisation (D-115). The built-in profile `deploy` (D-48) is the local one: an ordinary Pod that may reach what the shard lists (`deploy.egress`,
## `deploy.kubeApiServer`) and has no token of the cluster, so what it deploys with is a step secret. An organisation may add profiles of its own: a name and the ServiceAccount its Pods
## run as, with that account's token mounted (the credential of a deployment into the cluster the platform runs in), and the namespace (or the namespaces: a pattern) it deploys into. A step asks for one by its name
## (`profile = "<name>"`); it is a deploy Pod in every other respect (the label of the network policies, the security class) and a privileged profile like `deploy` (D-86: the project
## must allow the name, and the run must be on a protected ref). So one organisation can have the profiles `test1` and `test2`, and its groups allow one, the other or both (`allowed_profiles`).
## What the account may do, and where, is the operator's: a RoleBinding of that account in the namespace (the core may not touch a namespace outside its shard); the profile's namespace is
## what the step is told (`CINIM_DEPLOY_NAMESPACE`), so that a profile and the binding that limits its account say the same thing; `*` is every namespace (a ClusterRoleBinding), and the
## step is told none, and so is a profile that names none. A prefix with a `*` (`test*`) is every namespace that begins so, and a step is told the pattern (`CINIM_DEPLOY_NAMESPACES`).
## Only a name is told as `CINIM_DEPLOY_NAMESPACE`. Each profile has an account of its own unless it is told
## otherwise (`deploy-<name>`), so that the token of `test1` is not the token of `test2`.
## What is built here: the objects and their rules. The egress of a profile of its own is not: every deploy Pod follows the shard's `deploy.egress`.
import std/[json, strutils, algorithm]
import ../common/rqlite
import schema

const
  maxDeployProfilesPerOrg* = 20
  allNamespaces* = "*"                                         ## the profile may deploy into every namespace (the operator binds its account with a ClusterRoleBinding)
  reservedProfileNames* = ["default", "build", "deploy"]      ## the words of `profile =` that are not a name of an organisation's own

type
  DeployProfile* = object
    id*, tenantId*, name*, serviceAccount*, targetNamespace*, description*: string
    createdAt*, updatedAt*: int64

func validDeployProfileName*(n: string): bool =
  ## lowercase letters, digits, - and _, starting with a letter, at most 40; not one of the built-in words
  if n.len < 1 or n.len > 40 or n[0] notin {'a' .. 'z'} or n in reservedProfileNames: return false
  for ch in n:
    if ch notin {'a' .. 'z', '0' .. '9', '-', '_'}: return false
  true

func isNamespacePattern*(p: string): bool =
  ## a namespace is a DNS label; a pattern is a name, a prefix with one `*` at the end (`test*`, the style of the ref patterns), or `*` alone: every namespace
  if p == allNamespaces: return true
  if p.len < 1 or p.len > 63 or p[0] == '-': return false
  for i, ch in p:
    if ch == '*':
      if i != p.high: return false
    elif ch notin {'a' .. 'z', '0' .. '9', '-'}: return false
  p[^1] != '-'

func namespaceMatches*(pattern, namespace: string): bool =
  ## whether the profile may deploy into the namespace: the name itself, a prefix of it for `test*`, anything for `*`
  if pattern.len == 0 or namespace.len == 0: return false
  if pattern.endsWith("*"): return namespace.startsWith(pattern[0 ..< pattern.len - 1])
  pattern == namespace

func isPlainNamespace*(p: string): bool = p.len > 0 and '*' notin p

func validServiceAccountName*(n: string): bool =
  ## a DNS label (what Kubernetes accepts as the name of a ServiceAccount here): lowercase letters, digits and -, not starting or ending with -, at most 63
  if n.len < 1 or n.len > 63 or n[0] == '-' or n[^1] == '-': return false
  for ch in n:
    if ch notin {'a' .. 'z', '0' .. '9', '-'}: return false
  true

func view*(p: DeployProfile): JsonNode =
  %*{"name": p.name, "service_account": p.serviceAccount, "token": p.serviceAccount.len > 0, "namespace": p.targetNamespace, "description": p.description, "created_at": p.createdAt, "updated_at": p.updatedAt}

proc profileOf(v: JsonNode): DeployProfile =
  DeployProfile(id: v[0].getStr, tenantId: v[1].getStr, name: v[2].getStr, serviceAccount: v[3].getStr, targetNamespace: v[4].getStr, description: v[5].getStr, createdAt: v[6].getBiggestInt, updatedAt: v[7].getBiggestInt)

const profileColumns = "id, tenant_id, name, service_account, target_namespace, description, created_at, updated_at"

proc deployProfilesOf*(c: var RqClient; tenantId: string): seq[DeployProfile] =
  let vals = c.query(%*[["SELECT " & profileColumns & " FROM deploy_profiles WHERE tenant_id = ? ORDER BY name", tenantId]])["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add profileOf(v)

proc deployProfileNamed*(c: var RqClient; tenantId, name: string): tuple[found: bool, profile: DeployProfile] =
  let vals = c.query(%*[["SELECT " & profileColumns & " FROM deploy_profiles WHERE tenant_id = ? AND name = ?", tenantId, name]])["results"][0]{"values"}
  if vals != nil and vals.len > 0: (true, profileOf(vals[0])) else: (false, DeployProfile())

proc putDeployProfile*(c: var RqClient; tenantId, name: string; j: JsonNode; now: int64): tuple[error: string, status: int, created: bool] =
  ## Makes the profile `name` of the organisation or changes it (a field that is left out keeps its value; an empty `service_account` takes the token away).
  ## `status` is 0 or the HTTP status to answer with when `error` is set.
  if not validDeployProfileName(name): return ("a deploy profile is named by lowercase letters, digits, - and _, starting with a letter, at most 40; default, build and deploy are the built-in words", 400, false)
  if j == nil or j.kind != JObject: return ("a JSON object is required", 400, false)
  let have = c.deployProfileNamed(tenantId, name)
  var p = if have.found: have.profile else: DeployProfile(id: newId(), tenantId: tenantId, name: name, createdAt: now, serviceAccount: "deploy-" & name)
  if not have.found and c.deployProfilesOf(tenantId).len >= maxDeployProfilesPerOrg: return ("at most " & $maxDeployProfilesPerOrg & " deploy profiles per organisation", 409, false)
  for (key, maxLen) in [("service_account", 63), ("namespace", 63), ("description", 300)]:
    if j.hasKey(key):
      if j[key].kind != JString: return (key & " must be a string", 400, false)
      if j[key].getStr.len > maxLen: return (key & " is too long", 400, false)
  if j.hasKey("service_account"): p.serviceAccount = j["service_account"].getStr
  if j.hasKey("namespace"): p.targetNamespace = j["namespace"].getStr
  if j.hasKey("description"): p.description = j["description"].getStr
  if p.serviceAccount.len > 0 and not validServiceAccountName(p.serviceAccount):
    return ("service_account is a name of a ServiceAccount: lowercase letters, digits and -, at most 63 (empty: the Pods have no token of the cluster)", 400, false)
  if p.targetNamespace.len > 0 and not isNamespacePattern(p.targetNamespace):
    return ("namespace is a name of a namespace (lowercase letters, digits and -, at most 63), a prefix with a * at the end (test*), or * for all of them", 400, false)
  p.updatedAt = now
  discard c.execute(%*[["INSERT INTO deploy_profiles (id, tenant_id, name, service_account, target_namespace, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) " &
    "ON CONFLICT(id) DO UPDATE SET service_account = excluded.service_account, target_namespace = excluded.target_namespace, description = excluded.description, updated_at = excluded.updated_at",
    p.id, tenantId, name, p.serviceAccount, p.targetNamespace, p.description, p.createdAt, p.updatedAt]])
  ("", 0, not have.found)

proc deleteDeployProfile*(c: var RqClient; tenantId, name: string): bool =
  let p = c.deployProfileNamed(tenantId, name)
  if not p.found: return false
  discard c.execute(%*[["DELETE FROM deploy_profiles WHERE id = ?", p.profile.id]])
  true

proc deployAccountsOf*(c: var RqClient; tenantId: string): seq[string] =
  ## the ServiceAccounts the Pods of the organisation's profiles run as (each once, sorted): what the core makes in its namespace
  for p in c.deployProfilesOf(tenantId):
    if p.serviceAccount.len > 0 and p.serviceAccount notin result: result.add p.serviceAccount
  result.sort

proc deployProfileForRun*(c: var RqClient; runId, profile: string): tuple[known: bool, account, targetNamespace: string] =
  ## the profile an organisation's step asked for, as the run's organisation has it: not known when it has none of that name
  let v = c.query(%*[["SELECT p.service_account, p.target_namespace FROM deploy_profiles p JOIN runs r ON r.tenant_id = p.tenant_id WHERE r.id = ? AND p.name = ?", runId, profile]])["results"][0]{"values"}
  if v != nil and v.len > 0: (true, v[0][0].getStr, v[0][1].getStr) else: (false, "", "")
