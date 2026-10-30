## D-102: the login by an OpenID Connect provider (Keycloak, Dex, Entra, Okta, Google...), one or more for an organisation: the authorization code flow with PKCE. The core starts it (`beginLogin`: the address
## of the provider\'s login page, with a state that is kept ten minutes and used once), the browser comes back with a code, the core gives the code to the provider\'s token endpoint with its client secret and reads
## the ID token it gets **directly over TLS**, which OpenID Connect Core 3.1.3.7 lets a client trust in place of a signature. The claims are checked (issuer, audience, expiry, the nonce of this login); the person is
## the claim `user_claim` (`preferred_username`), their account is `<login>@<organisation>` (made at the first login only if the provider has `auto_create`), and the roles come from the values of the claim
## `groups_claim` through the map of the organisation (`oidc_group_map`), put on the account the way a directory\'s are (`source` = `oidc:<provider id>`). The client secret is sealed in the vault. OIDC
## says who the person is; the second factor of the provider is trusted, CiNim\'s own is not asked.
import std/[json, strutils, httpclient, uri, times, base64, tables, sets, sysrand, os]
import crunchy
import ../common/rqlite
import secretvault, ldapauth, apiauth

const
  pendingSeconds = 600'i64
  maxPending = 2000
  defaultScopes = "openid profile email"

type
  OidcProvider* = object
    id*, tenantId*, name*, issuer*, clientId*, redirectUri*, scopes*, userClaim*, groupsClaim*: string
    autoCreate*, enabled*: bool
  OidcOutcome* = enum olOk, olBadState, olUnavailable, olRefused, olNoAccount, olNoRole, olNameTaken
  OidcLogin* = object
    outcome*: OidcOutcome
    user*, detail*: string

func sourceOfProvider*(id: string): string = "oidc:" & id
func secretNameOf*(id: string): string = "OIDC_SECRET_" & id

proc randomText(n: int): string =
  var buf = newSeq[byte](n)
  if not urandom(buf): raise newException(OSError, "no source of randomness")
  for b in buf:
    result.add "0123456789abcdef"[int(b shr 4)]
    result.add "0123456789abcdef"[int(b and 15)]

func b64url(s: string): string = encode(s, safe = true).strip(leading = false, chars = {'='})

func b64urlDecode(s: string): string =
  var t = s.replace('-', '+').replace('_', '/')
  while t.len mod 4 != 0: t.add '='
  try: decode(t) except CatchableError: ""

proc challengeOf*(verifier: string): string =
  var d = ""
  for b in sha256(verifier): d.add char(b)
  b64url(d)

func validIssuer*(u: string): bool =
  ## https, or http on the machine itself (for a test); no query, no fragment, no user in the address
  if u.len > 300 or '?' in u or '#' in u or '@' in u: return false
  u.startsWith("https://") or u.startsWith("http://localhost") or u.startsWith("http://127.0.0.1")

func providerOf(r: JsonNode): OidcProvider =
  OidcProvider(id: r[0].getStr, tenantId: r[1].getStr, name: r[2].getStr, issuer: r[3].getStr, clientId: r[4].getStr, redirectUri: r[5].getStr, scopes: r[6].getStr,
               userClaim: r[7].getStr, groupsClaim: r[8].getStr, autoCreate: r[9].getInt > 0, enabled: r[10].getInt > 0)

const providerColumns = "id, tenant_id, name, issuer, client_id, redirect_uri, scopes, user_claim, groups_claim, auto_create, enabled"

proc providersOf*(c: var RqClient; tenantId: string; onlyEnabled = false): seq[OidcProvider] =
  let v = c.query(%*[["SELECT " & providerColumns & " FROM oidc_providers WHERE tenant_id = ?" & (if onlyEnabled: " AND enabled = 1" else: "") & " ORDER BY name", tenantId]])["results"][0]{"values"}
  if v != nil:
    for r in v: result.add providerOf(r)

proc providerById*(c: var RqClient; tenantId, id: string): OidcProvider =
  let v = c.query(%*[["SELECT " & providerColumns & " FROM oidc_providers WHERE tenant_id = ? AND id = ?", tenantId, id]])["results"][0]{"values"}
  if v != nil and v.len > 0: result = providerOf(v[0])

func view*(p: OidcProvider): JsonNode =
  %*{"id": p.id, "name": p.name, "issuer": p.issuer, "client_id": p.clientId, "redirect_uri": p.redirectUri, "scopes": p.scopes, "user_claim": p.userClaim, "groups_claim": p.groupsClaim,
     "auto_create": p.autoCreate, "enabled": p.enabled}

func validClaimName(s: string): bool =
  if s.len < 1 or s.len > 60: return false
  for ch in s:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-', '.', ':'}: return false
  true

proc putProvider*(c: var RqClient; kek: KekProvider; vaultReady: bool; tenantId: string; id: string; j: JsonNode; now: int64): tuple[id, error: string] =
  ## {"name", "issuer", "client_id", "client_secret" (write only; required for a new one), "redirect_uri", "scopes"?, "user_claim"?, "groups_claim"?, "auto_create"?, "enabled"?}
  if j == nil or j.kind != JObject: return ("", "a JSON object is required")
  let cur = if id.len > 0: c.providerById(tenantId, id) else: OidcProvider()
  if id.len > 0 and cur.id.len == 0: return ("", "no such provider")
  var p = if cur.id.len > 0: cur else: OidcProvider(userClaim: "preferred_username", groupsClaim: "groups", scopes: defaultScopes, enabled: true)
  for (k, f) in [("name", 0), ("issuer", 1), ("client_id", 2), ("redirect_uri", 3), ("scopes", 4), ("user_claim", 5), ("groups_claim", 6)]:
    if j.hasKey(k):
      if j[k].kind != JString: return ("", k & " is text")
      let v = j[k].getStr.strip
      case f
      of 0: p.name = v
      of 1: p.issuer = v.strip(leading = false, chars = {'/'})
      of 2: p.clientId = v
      of 3: p.redirectUri = v
      of 4: p.scopes = v
      of 5: p.userClaim = v
      else: p.groupsClaim = v
  if j.hasKey("auto_create") and j["auto_create"].kind == JBool: p.autoCreate = j["auto_create"].getBool
  if j.hasKey("enabled") and j["enabled"].kind == JBool: p.enabled = j["enabled"].getBool
  if p.name.len < 1 or p.name.len > 60 or p.name.contains({'\n', '|'}): return ("", "name is 1 to 60 characters")
  if not validIssuer(p.issuer): return ("", "issuer is the https address of the provider (http only on localhost)")
  if p.clientId.len < 1 or p.clientId.len > 200: return ("", "client_id is required")
  if not (p.redirectUri.startsWith("https://") or p.redirectUri.startsWith("http://localhost") or p.redirectUri.startsWith("http://127.0.0.1")) or p.redirectUri.len > 300 or '#' in p.redirectUri:
    return ("", "redirect_uri is the https address of the UI\'s /login/oidc/callback")
  if "openid" notin p.scopes.split(' '): return ("", "scopes must include openid")
  if not validClaimName(p.userClaim) or not validClaimName(p.groupsClaim): return ("", "a claim is a name of letters, digits and _ - . :")
  let newId = if id.len > 0: id else: "o" & randomText(5)
  let hasSecret = j.hasKey("client_secret") and j["client_secret"].kind == JString and j["client_secret"].getStr.len > 0
  if id.len == 0 and not hasSecret: return ("", "client_secret is required")
  if hasSecret:
    if not vaultReady: return ("", "the secrets of the core are not available")
    let put = c.putSecret(kek, tenantId, secretNameOf(newId), j["client_secret"].getStr, now)
    if not put.ok: return ("", "the client secret could not be kept: " & put.error)
  discard c.execute(%*[["INSERT INTO oidc_providers (id, tenant_id, name, issuer, client_id, redirect_uri, scopes, user_claim, groups_claim, auto_create, enabled, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) " &
    "ON CONFLICT(id) DO UPDATE SET name = excluded.name, issuer = excluded.issuer, client_id = excluded.client_id, redirect_uri = excluded.redirect_uri, scopes = excluded.scopes, user_claim = excluded.user_claim, " &
    "groups_claim = excluded.groups_claim, auto_create = excluded.auto_create, enabled = excluded.enabled",
    newId, tenantId, p.name, p.issuer, p.clientId, p.redirectUri, p.scopes, p.userClaim, p.groupsClaim, (if p.autoCreate: 1 else: 0), (if p.enabled: 1 else: 0), now]])
  (newId, "")

proc deleteProvider*(c: var RqClient; tenantId, id: string): bool =
  let r = c.execute(%*[["DELETE FROM oidc_providers WHERE tenant_id = ? AND id = ?", tenantId, id], ["DELETE FROM oidc_group_map WHERE tenant_id = ? AND provider_id = ?", tenantId, id],
                       ["DELETE FROM step_secrets WHERE tenant_id = ? AND name = ?", tenantId, secretNameOf(id)]], transaction = true)
  r["results"][0]{"rows_affected"}.getInt > 0

proc putOidcMapping*(c: var RqClient; tenantId, providerId, claimValue, role: string; now: int64): tuple[id, error: string] =
  if c.providerById(tenantId, providerId).id.len == 0: return ("", "no such provider")
  if claimValue.len < 1 or claimValue.len > 200: return ("", "the value of the claim is 1 to 200 characters")
  if not c.roleExists(role): return ("", "no such role: " & role)
  if role == roleAdmin: return ("", "admin is a role of the shard; an organisation\'s administrator is rw or a role of your own")
  let id = "m" & randomText(5)
  discard c.execute(%*[["INSERT OR IGNORE INTO oidc_group_map (id, tenant_id, provider_id, claim_value, role, created_at) VALUES (?, ?, ?, ?, ?, ?)", id, tenantId, providerId, claimValue, role, now]])
  (id, "")

proc listOidcMappings*(c: var RqClient; tenantId: string): JsonNode =
  result = newJArray()
  let v = c.query(%*[["SELECT id, provider_id, claim_value, role FROM oidc_group_map WHERE tenant_id = ? ORDER BY provider_id, claim_value, role", tenantId]])["results"][0]{"values"}
  if v != nil:
    for r in v: result.add %*{"id": r[0].getStr, "provider": r[1].getStr, "claim_value": r[2].getStr, "role": r[3].getStr}

proc deleteOidcMapping*(c: var RqClient; tenantId, id: string): bool =
  c.execute(%*[["DELETE FROM oidc_group_map WHERE tenant_id = ? AND id = ?", tenantId, id]])["results"][0]{"rows_affected"}.getInt > 0

# ------------------------------------------------------------------ the flow

proc httpClient(): HttpClient =
  let proxy = getEnv("CINIM_OIDC_PROXY")
  if proxy.len > 0: newHttpClient(timeout = 10000, proxy = newProxy(proxy), headers = newHttpHeaders({"User-Agent": "cinim-core"}))
  else: newHttpClient(timeout = 10000, headers = newHttpHeaders({"User-Agent": "cinim-core"}))

proc discover(issuer: string): tuple[ok: bool, authz, token, userinfo, error: string] =
  try:
    let client = httpClient()
    defer: client.close()
    let r = client.get(issuer & "/.well-known/openid-configuration")
    if r.code.int != 200: return (false, "", "", "", "the provider answered " & $r.code.int & " to its discovery")
    let j = parseJson(r.body)
    if j{"issuer"}.getStr.strip(leading = false, chars = {'/'}) != issuer: return (false, "", "", "", "the issuer in the discovery is not " & issuer)
    result = (true, j{"authorization_endpoint"}.getStr, j{"token_endpoint"}.getStr, j{"userinfo_endpoint"}.getStr, "")
    if result.authz.len == 0 or result.token.len == 0: return (false, "", "", "", "the discovery names no authorization or token endpoint")
  except CatchableError as e:
    result = (false, "", "", "", "the provider could not be asked: " & e.msg)

proc beginLogin*(c: var RqClient; p: OidcProvider; now: int64): tuple[ok: bool, url, error: string] =
  ## the address the browser is sent to; the state, the nonce and the verifier of the PKCE are kept for ten minutes
  let d = discover(p.issuer)
  if not d.ok: return (false, "", d.error)
  discard c.execute(%*[["DELETE FROM oidc_pending WHERE expires_at < ?", now]])
  if c.query(%*[["SELECT count(*) FROM oidc_pending"]])["results"][0]{"values"}[0][0].getInt >= maxPending: return (false, "", "too many logins are being made; try again in a moment")
  let state = randomText(16)
  let nonce = randomText(16)
  let verifier = randomText(32)                                   # 64 characters of the unreserved set (RFC 7636 wants 43 to 128)
  discard c.execute(%*[["INSERT INTO oidc_pending (state, provider_id, verifier, nonce, expires_at) VALUES (?, ?, ?, ?, ?)", state, p.id, verifier, nonce, now + pendingSeconds]])
  let sep = if '?' in d.authz: "&" else: "?"
  (true, d.authz & sep & "response_type=code&client_id=" & encodeUrl(p.clientId, usePlus = false) & "&redirect_uri=" & encodeUrl(p.redirectUri, usePlus = false) & "&scope=" & encodeUrl(p.scopes, usePlus = false) &
        "&state=" & state & "&nonce=" & nonce & "&code_challenge=" & challengeOf(verifier) & "&code_challenge_method=S256", "")

func claimStrings(j: JsonNode; name: string): seq[string] =
  let v = j{name}
  if v.isNil: return
  if v.kind == JString: result.add v.getStr
  elif v.kind == JArray:
    for x in v: (if x.kind == JString: result.add x.getStr)

proc syncBindings(c: var RqClient; user, providerId, slug: string; roles: seq[string]) =
  let scope = "org:" & slug
  let src = sourceOfProvider(providerId)
  let have = c.query(%*[["SELECT role FROM role_bindings WHERE user_name = ? AND source = ? AND scope = ?", user, src, scope]])["results"][0]{"values"}
  var current: seq[string]
  if have != nil:
    for v in have: current.add v[0].getStr
  var stmts = newJArray()
  for r in current:
    if r notin roles: stmts.add %*["DELETE FROM role_bindings WHERE user_name = ? AND source = ? AND scope = ? AND role = ?", user, src, scope, r]
  for r in roles:
    if r notin current: stmts.add %*["INSERT OR IGNORE INTO role_bindings (user_name, role, scope, source) VALUES (?, ?, ?, ?)", user, r, scope, src]
  if stmts.len > 0: discard c.execute(stmts, transaction = true)

proc finishLogin*(c: var RqClient; kek: KekProvider; vaultReady: bool; state, code: string; now: int64): OidcLogin =
  ## The browser is back with a state and a code. The state is used up here whatever comes of the rest.
  let pend = c.query(%*[["SELECT provider_id, verifier, nonce, expires_at FROM oidc_pending WHERE state = ?", state]])["results"][0]{"values"}
  discard c.execute(%*[["DELETE FROM oidc_pending WHERE state = ?", state]])
  if pend == nil or pend.len == 0 or pend[0][3].getBiggestInt < now: return OidcLogin(outcome: olBadState, detail: "the login is not known or took too long: start again")
  let pv = c.query(%*[["SELECT " & providerColumns & " FROM oidc_providers WHERE id = ? AND enabled = 1", pend[0][0].getStr]])["results"][0]{"values"}
  if pv == nil or pv.len == 0: return OidcLogin(outcome: olBadState, detail: "the provider is gone or switched off")
  let p = providerOf(pv[0])
  let org = c.query(%*[["SELECT slug, state FROM organizations WHERE id = ?", p.tenantId]])["results"][0]{"values"}
  if org == nil or org.len == 0 or org[0][1].getStr != "active": return OidcLogin(outcome: olBadState, detail: "the organisation is not active")
  let slug = org[0][0].getStr
  if not vaultReady: return OidcLogin(outcome: olUnavailable, detail: "the secrets of the core are not available")
  let sec = c.getSecrets(kek, p.tenantId, @[secretNameOf(p.id)])
  if not sec.ok or sec.values.len == 0: return OidcLogin(outcome: olUnavailable, detail: "the client secret is not available")
  let d = discover(p.issuer)
  if not d.ok: return OidcLogin(outcome: olUnavailable, detail: d.error)
  var idClaims: JsonNode
  var accessToken = ""
  try:
    let client = httpClient()
    defer: client.close()
    client.headers["Content-Type"] = "application/x-www-form-urlencoded"
    let body = "grant_type=authorization_code&code=" & encodeUrl(code, usePlus = false) & "&redirect_uri=" & encodeUrl(p.redirectUri, usePlus = false) & "&client_id=" & encodeUrl(p.clientId, usePlus = false) &
               "&client_secret=" & encodeUrl(sec.values[0][1], usePlus = false) & "&code_verifier=" & pend[0][1].getStr
    let r = client.post(d.token, body)
    if r.code.int != 200: return OidcLogin(outcome: olRefused, detail: "the provider refused the code (" & $r.code.int & ")")
    let tj = parseJson(r.body)
    accessToken = tj{"access_token"}.getStr
    let parts = tj{"id_token"}.getStr.split('.')
    if parts.len != 3: return OidcLogin(outcome: olRefused, detail: "the provider gave no ID token")
    idClaims = parseJson(b64urlDecode(parts[1]))
    if idClaims.kind != JObject: return OidcLogin(outcome: olRefused, detail: "the ID token is not readable")
    # the ID token came over TLS from the token endpoint itself (OIDC Core 3.1.3.7): its claims are checked, its signature is not needed
    if idClaims{"iss"}.getStr.strip(leading = false, chars = {'/'}) != p.issuer: return OidcLogin(outcome: olRefused, detail: "the ID token is from another issuer")
    if p.clientId notin claimStrings(idClaims, "aud"): return OidcLogin(outcome: olRefused, detail: "the ID token is for another client")
    if idClaims{"exp"}.getBiggestInt <= now: return OidcLogin(outcome: olRefused, detail: "the ID token has expired")
    if idClaims{"nonce"}.getStr != pend[0][2].getStr: return OidcLogin(outcome: olRefused, detail: "the nonce is not the one of this login")
    # a claim that the ID token does not carry may be in the user info
    if (idClaims{p.userClaim}.isNil or idClaims{p.groupsClaim}.isNil) and d.userinfo.len > 0 and accessToken.len > 0:
      client.headers = newHttpHeaders({"Authorization": "Bearer " & accessToken, "User-Agent": "cinim-core"})
      let ui = client.get(d.userinfo)
      if ui.code.int == 200:
        let uj = parseJson(ui.body)
        if uj{"sub"}.getStr == idClaims{"sub"}.getStr:
          for k in [p.userClaim, p.groupsClaim]:
            if idClaims{k}.isNil and not uj{k}.isNil: idClaims[k] = uj[k]
  except CatchableError as e:
    return OidcLogin(outcome: olUnavailable, detail: "the provider could not be asked: " & e.msg)
  let uidRaw = claimStrings(idClaims, p.userClaim)
  let uid = if uidRaw.len > 0: uidRaw[0].toLowerAscii else: ""
  if not validDirectoryId(uid): return OidcLogin(outcome: olRefused, detail: "the claim " & p.userClaim & " is not a login CiNim can use (letters, digits and . _ -, at most 64)")
  let name = accountName(uid, slug)
  let existing = c.query(%*[["SELECT source FROM users WHERE name = ?", name]])["results"][0]{"values"}
  let isNew = existing == nil or existing.len == 0
  if not isNew and existing[0][0].getStr != sourceOfProvider(p.id):
    return OidcLogin(outcome: olNameTaken, user: name, detail: "the account " & name & " belongs to another provider or directory")
  if isNew and not p.autoCreate:
    return OidcLogin(outcome: olNoAccount, user: name, detail: "the provider knows " & uid & ", but " & slug & " has no account for them and this provider does not make accounts at login")
  var roles: seq[string]
  let groups = claimStrings(idClaims, p.groupsClaim)
  let mp = c.query(%*[["SELECT claim_value, role FROM oidc_group_map WHERE tenant_id = ? AND provider_id = ?", p.tenantId, p.id]])["results"][0]{"values"}
  if mp != nil:
    for m in mp:
      if m[0].getStr in groups and m[1].getStr notin roles: roles.add m[1].getStr
  if roles.len == 0 and isNew: return OidcLogin(outcome: olNoRole, user: name, detail: "no group of " & uid & " gives a role in " & slug)
  discard c.execute(%*[["INSERT INTO users (name, password_hash, created_at, disabled, must_change, source, dn) VALUES (?, '', ?, 0, 0, ?, '') ON CONFLICT(name) DO UPDATE SET disabled = 0 WHERE users.source = excluded.source",
                        name, now, sourceOfProvider(p.id)]])
  c.syncBindings(name, p.id, slug, roles)
  if c.userRoles(name, now).bindings.len == 0: return OidcLogin(outcome: olNoRole, user: name, detail: "no group of " & uid & " gives a role in " & slug)
  OidcLogin(outcome: olOk, user: name, detail: p.name)
