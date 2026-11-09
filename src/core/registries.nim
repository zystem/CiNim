## Image registries as objects of an organisation (D-114): a name, an address (`host[:port][/path]`, what the images are `<address>/<image>`), whether it speaks plain HTTP, and the login (a user name and
## a password or a token), the pipelines of the organisation use by name. The password is sealed with the organisation's data key (secretvault.nim), never answered and only opened to make the
## Docker config of the registry (`config.json`), the form every tool that pushes (Kaniko, crane, skopeo) already reads and the registries' own documentation tells to make.
## What is built here: the objects and their rules. The things that are to be made from them (the login given to the steps that push, the egress rule of the build Pods, the pull secret of the
## step Pods) are not, see docs/deployment.md "Where the images go".
import std/[json, strutils, base64]
import ../common/rqlite
import schema, secretvault, kekprovider

const
  maxRegistriesPerOrg* = 50
  maxAddressLen* = 200

type
  Registry* = object
    id*, tenantId*, name*, address*, username*, secretEnc*, description*: string
    insecure*: bool                     ## the registry speaks plain HTTP or has no certificate to check (the registry of the cluster)
    createdAt*, updatedAt*: int64

func validRegistryName*(n: string): bool =
  if n.len < 1 or n.len > 40 or n[0] notin {'a' .. 'z'}: return false
  for ch in n:
    if ch notin {'a' .. 'z', '0' .. '9', '-', '_'}: return false
  true

func validRegistryAddress*(a: string): bool =
  ## host[:port][/path]: no scheme, no login in it, no query, no empty part of the path; a host name or an IPv4 address (an IPv6 one is not written here)
  if a.len < 1 or a.len > maxAddressLen: return false
  let slash = a.find('/')
  let hostPort = if slash >= 0: a[0 ..< slash] else: a
  let path = if slash >= 0: a[slash + 1 .. ^1] else: ""
  if hostPort.len == 0: return false
  let colon = hostPort.find(':')
  let host = if colon >= 0: hostPort[0 ..< colon] else: hostPort
  if host.len == 0 or host[0] in {'.', '-'} or host[^1] in {'.', '-'}: return false
  for ch in host:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '-'}: return false
  if colon >= 0:
    let port = hostPort[colon + 1 .. ^1]
    if port.len < 1 or port.len > 5: return false
    for ch in port:
      if ch notin {'0' .. '9'}: return false
    if parseInt(port) < 1 or parseInt(port) > 65535: return false
  if slash >= 0:
    if path.len == 0: return false
    for part in path.split('/'):
      if part.len == 0: return false
      for ch in part:
        if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '-', '_'}: return false
  true

func dockerKeyOf(address: string): string =
  ## the key of the login in a Docker config: the host (and the port), and for Docker Hub what `docker login` writes
  let slash = address.find('/')
  let hostPort = if slash >= 0: address[0 ..< slash] else: address
  if hostPort.toLowerAscii in ["docker.io", "index.docker.io", "registry-1.docker.io"]: "https://index.docker.io/v1/" else: hostPort

func dockerConfigOf*(address, username, password: string): string =
  ## the text of a Docker config with the one login; empty when there is none
  if username.len == 0 and password.len == 0: return ""
  $(%*{"auths": {dockerKeyOf(address): {"auth": encode(username & ":" & password)}}})

func view*(r: Registry): JsonNode =
  %*{"name": r.name, "address": r.address, "insecure": r.insecure, "username": r.username, "has_password": r.secretEnc.len > 0, "description": r.description,
     "created_at": r.createdAt, "updated_at": r.updatedAt}

proc registryOf(v: JsonNode): Registry =
  Registry(id: v[0].getStr, tenantId: v[1].getStr, name: v[2].getStr, address: v[3].getStr, insecure: v[4].getInt > 0, username: v[5].getStr, secretEnc: v[6].getStr,
           description: v[7].getStr, createdAt: v[8].getBiggestInt, updatedAt: v[9].getBiggestInt)

const registryColumns = "id, tenant_id, name, address, insecure, username, secret_enc, description, created_at, updated_at"

proc registriesOf*(c: var RqClient; tenantId: string): seq[Registry] =
  let vals = c.query(%*[["SELECT " & registryColumns & " FROM registries WHERE tenant_id = ? ORDER BY name", tenantId]])["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add registryOf(v)

proc registryNamed*(c: var RqClient; tenantId, name: string): tuple[found: bool, registry: Registry] =
  let vals = c.query(%*[["SELECT " & registryColumns & " FROM registries WHERE tenant_id = ? AND name = ?", tenantId, name]])["results"][0]{"values"}
  if vals != nil and vals.len > 0: (true, registryOf(vals[0])) else: (false, Registry())

proc putRegistry*(c: var RqClient; kek: KekProvider; vaultReady: bool; tenantId, name: string; j: JsonNode; now: int64): tuple[error: string, status: int, created: bool] =
  ## Makes the registry `name` of the organisation or changes it (a field that is left out keeps its value; the password is only ever written, an empty one takes the login away).
  ## `status` is 0 or the HTTP status to answer with when `error` is set.
  if not validRegistryName(name): return ("a registry is named by lowercase letters, digits, - and _, starting with a letter, at most 40", 400, false)
  if j == nil or j.kind != JObject: return ("a JSON object is required", 400, false)
  let have = c.registryNamed(tenantId, name)
  var r = if have.found: have.registry else: Registry(id: newId(), tenantId: tenantId, name: name, createdAt: now)
  if not have.found and c.registriesOf(tenantId).len >= maxRegistriesPerOrg: return ("at most " & $maxRegistriesPerOrg & " registries per organisation", 409, false)
  template str(key: string; into: untyped; maxLen: int) =
    if j.hasKey(key):
      if j[key].kind != JString: return (key & " must be a string", 400, false)
      into = j[key].getStr
      if into.len > maxLen: return (key & " is too long", 400, false)
  str("address", r.address, maxAddressLen)
  str("username", r.username, 200)
  str("description", r.description, 300)
  if j.hasKey("insecure"):
    if j["insecure"].kind != JBool: return ("insecure must be true or false", 400, false)
    r.insecure = j["insecure"].getBool
  if r.address.len == 0: return ("address is required: host[:port][/path] with no scheme, as the images are <address>/<image> (ghcr.io/acme)", 400, false)
  if not validRegistryAddress(r.address): return ("address is host[:port][/path] with no scheme, no login in it and no query", 400, false)
  for ch in r.username:
    if ch < ' ' or ch == ':' or ch == '\x7f': return ("username has a character that cannot be in a login (a colon or a control character)", 400, false)
  if j.hasKey("password"):
    if j["password"].kind != JString: return ("password must be a string", 400, false)
    let pw = j["password"].getStr
    if pw.len > 4096: return ("password is too long", 400, false)
    if pw.len > 0:
      if not vaultReady: return ("the secrets of the core are not available now", 503, false)
      let sealed = c.sealOrgText(kek, tenantId, "registry:" & r.id, pw)
      if not sealed.ok: return (sealed.error, (if sealed.retry: 503 else: 500), false)
      r.secretEnc = sealed.sealed
    else:
      r.secretEnc = ""
  if r.secretEnc.len > 0 and r.username.len == 0: return ("a password needs username", 400, false)
  if r.secretEnc.len == 0 and r.username.len > 0: return ("username needs password (a login is both)", 400, false)
  r.updatedAt = now
  discard c.execute(%*[["INSERT INTO registries (id, tenant_id, name, address, insecure, username, secret_enc, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) " &
    "ON CONFLICT(id) DO UPDATE SET address = excluded.address, insecure = excluded.insecure, username = excluded.username, secret_enc = excluded.secret_enc, description = excluded.description, " &
    "updated_at = excluded.updated_at", r.id, tenantId, name, r.address, (if r.insecure: 1 else: 0), r.username, r.secretEnc, r.description, r.createdAt, r.updatedAt]])
  ("", 0, not have.found)

proc deleteRegistry*(c: var RqClient; tenantId, name: string): bool =
  let r = c.registryNamed(tenantId, name)
  if not r.found: return false
  discard c.execute(%*[["DELETE FROM registries WHERE id = ?", r.registry.id]])
  true

proc dockerConfigFor*(c: var RqClient; kek: KekProvider; vaultReady: bool; r: Registry): tuple[ok: bool, config, error: string] =
  ## the Docker config of the registry: "" (and ok) when it has no login; the password is opened here and goes nowhere but into the text
  if r.secretEnc.len == 0: return (true, "", "")
  if not vaultReady: return (false, "", "the secrets of the core are not available now")
  let pw = c.openOrgText(kek, r.tenantId, "registry:" & r.id, r.secretEnc)
  if not pw.ok: return (false, "", "the password of the registry cannot be read: " & pw.error)
  (true, dockerConfigOf(r.address, r.username, pw.plain), "")

func loginRefused*(name: string): string =
  ## D-114: a registry with a login is privileged, as the profile `deploy` is (D-86): its login goes to runs on a protected ref of the project only
  "the registry " & name & " has a login: it goes to runs on a protected ref of the project only (protected_refs), and this run is not on one"

proc registriesConfig*(c: var RqClient; kek: KekProvider; vaultReady: bool; tenantId: string; names: seq[string]; trusted = false): tuple[ok, retry: bool, config, error: string] =
  ## the one Docker config that holds the logins of the named registries (D-114): what a step that names `registries` gets in `CINIM_REGISTRY_CONFIG`. A registry without a login adds nothing;
  ## the result is always a config (`{"auths":{}}` when none has a login), so that the step writes it where its tool looks for it. A name the organisation has not is an error, and so is
  ## a registry with a login for a run that is not `trusted` (on a protected ref): the login is not given, the step is told why.
  var auths = newJObject()
  for n in names:
    let r = c.registryNamed(tenantId, n)
    if not r.found: return (false, false, "", "this organisation has no registry " & n)
    if r.registry.secretEnc.len > 0 and not trusted: return (false, false, "", loginRefused(n))
    let d = c.dockerConfigFor(kek, vaultReady, r.registry)
    if not d.ok: return (false, not vaultReady, "", d.error)
    if d.config.len > 0:
      for k, v in parseJson(d.config)["auths"]: auths[k] = v
  (true, false, $(%*{"auths": auths}), "")
