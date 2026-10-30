## D-102, against a real rqlite and a stand-in OpenID Connect provider: the providers of an organisation, the start of a login (state, nonce, PKCE), the code exchanged with the client secret, the claims of
## the ID token checked, the account made or refused, the roles that the groups give put on it. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, tables, sequtils, asynchttpserver, asyncdispatch, locks, base64, uri]
import common/rqlite
import core/[schema, apiauth, secretvault, kekprovider, oidc]

let url = getEnv("CINIM_RQLITE_URL")
const port = 24885
let issuer = "http://127.0.0.1:" & $port

var
  lock: Lock
  claims: JsonNode = newJObject()          ## what the stand-in provider puts in the ID token (set by the test)
  userinfo: JsonNode = newJObject()
  tokenRequests: seq[string]
  lastNonce, lastChallenge: string
  tokenStatus = 200
initLock lock

func b64(s: string): string = encode(s, safe = true).strip(leading = false, chars = {'='})

proc handle(req: Request) {.async, gcsafe.} =
  {.cast(gcsafe).}:
    var status = Http200
    var body = ""
    withLock lock:
      case req.url.path
      of "/.well-known/openid-configuration":
        body = $(%*{"issuer": issuer, "authorization_endpoint": issuer & "/authorize", "token_endpoint": issuer & "/token", "userinfo_endpoint": issuer & "/userinfo"})
      of "/token":
        tokenRequests.add req.body
        if tokenStatus != 200: status = HttpCode(tokenStatus)
        else:
          var c = claims.copy
          c["nonce"] = %lastNonce
          body = $(%*{"access_token": "at-1", "token_type": "Bearer", "id_token": b64("""{"alg":"none"}""") & "." & b64($c) & ".sig"})
      of "/userinfo":
        if req.headers.getOrDefault("Authorization") == "Bearer at-1": body = $userinfo else: status = Http401
      else: status = Http404
    await req.respond(status, body)

proc standIn() {.thread.} =
  {.cast(gcsafe).}:
    var server = newAsyncHttpServer()
    waitFor server.serve(Port(port), handle)

suite "D-102 PKCE":
  test "RFC 7636 appendix B: the challenge of the example verifier":
    check challengeOf("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  test "an issuer is https, or http on the machine itself; a provider needs its name, client, redirect address and the scope openid":
    check validIssuer("https://sso.example/realms/x") and validIssuer("http://127.0.0.1:9") and validIssuer("http://localhost:9")
    for bad in ["http://sso.example", "ftp://x", "https://u@sso.example", "https://sso.example?x=1", ""]: check not validIssuer(bad)

suite "D-102 the login":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    setDekCacheSeconds(0.0)
    var th: Thread[void]
    createThread(th, standIn)
    sleep 400
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let slug = "oi" & sfx
    let org = c.addOrganization(slug, "A")
    let now = getTime().toUnix()
    let kek = derivedKek("oidc-key-" & sfx)
    let provJson = %*{"name": "Corp SSO", "issuer": issuer, "client_id": "cinim", "client_secret": "s3cret-value", "redirect_uri": "http://127.0.0.1:18080/ui/login/oidc/callback", "auto_create": true}
    proc idClaims(user: string; groups: seq[string] = @["dev-team"]; aud = "cinim"; iss = issuer; exp = now + 600): JsonNode =
      %*{"iss": iss, "aud": aud, "exp": exp, "sub": "sub-" & user, "preferred_username": user, "groups": groups}
    proc login(p: OidcProvider; t: int64 = now): OidcLogin =
      ## the whole round: the start, and the return with a code
      let began = c.beginLogin(p, t)
      check began.ok
      let q = began.url.split('?')[1]
      var params = initTable[string, string]()
      for k, v in decodeQuery(q): params[k] = v
      withLock lock:
        lastNonce = params["nonce"]
        lastChallenge = params["code_challenge"]
      c.finishLogin(kek, true, params["state"], "code-1", t)
    var pid = ""

    test "a provider is made with its secret sealed, listed without it, changed without sending it again, and removed with its secret and its map":
      check c.putProvider(kek, true, org, "", %*{"name": "x", "issuer": "http://sso.example", "client_id": "a", "client_secret": "b", "redirect_uri": "https://ui.example/ui/login/oidc/callback"}, now).error.contains("issuer")
      check c.putProvider(kek, true, org, "", %*{"name": "x", "issuer": issuer, "client_id": "a", "redirect_uri": "https://ui.example/cb"}, now).error.contains("client_secret")
      check c.putProvider(kek, true, org, "", %*{"name": "x", "issuer": issuer, "client_id": "a", "client_secret": "b", "redirect_uri": "ftp://x"}, now).error.contains("redirect_uri")
      check c.putProvider(kek, true, org, "", %*{"name": "x", "issuer": issuer, "client_id": "a", "client_secret": "b", "redirect_uri": "https://ui.example/cb", "scopes": "profile"}, now).error.contains("openid")
      let made = c.putProvider(kek, true, org, "", provJson, now)
      check made.error == ""
      pid = made.id
      let listed = c.providersOf(org)
      check listed.len == 1 and listed[0].name == "Corp SSO" and listed[0].autoCreate and $listed[0].view notin "s3cret-value" and "client_secret" notin $listed[0].view
      check c.getSecrets(kek, org, @[secretNameOf(pid)]).values == @[(secretNameOf(pid), "s3cret-value")]
      check c.putProvider(kek, true, org, pid, %*{"name": "Corp SSO 2"}, now).error == "" and c.providerById(org, pid).name == "Corp SSO 2" and c.getSecrets(kek, org, @[secretNameOf(pid)]).ok
      check c.putProvider(kek, true, org, "nope", %*{"name": "y"}, now).error == "no such provider"
      discard c.putProvider(kek, true, org, pid, %*{"name": "Corp SSO"}, now)
    test "the map: a claim value gives a role of the organisation; admin is the shard\'s and is refused":
      check c.putOidcMapping(org, pid, "dev-team", "dev", now).error == "" and c.putOidcMapping(org, pid, "dev-team", "admin", now).error.contains("shard") and c.putOidcMapping(org, pid, "x", "nosuchrole", now).error.contains("no such role")
      check c.putOidcMapping(org, "nope", "x", "dev", now).error == "no such provider" and c.listOidcMappings(org).len == 1
    test "the start gives the address of the login page with the state, the nonce and the challenge of the PKCE, and keeps them":
      let began = c.beginLogin(c.providerById(org, pid), now)
      check began.ok and began.url.startsWith(issuer & "/authorize?response_type=code&client_id=cinim&redirect_uri=http%3A%2F%2F127.0.0.1%3A18080")
      var params = initTable[string, string]()
      for k, v in decodeQuery(began.url.split('?')[1]): params[k] = v
      check params["code_challenge_method"] == "S256" and params["scope"] == "openid profile email" and params["state"].len == 32 and params["nonce"].len == 32
      let kept = c.query(%*[["SELECT verifier, nonce FROM oidc_pending WHERE state = ?", params["state"]]])["results"][0]["values"][0]
      check challengeOf(kept[0].getStr) == params["code_challenge"] and kept[1].getStr == params["nonce"] and kept[0].getStr.len == 64
    test "the first login makes the account (auto_create), with the roles of the groups; the code goes to the token endpoint with the secret and the verifier":
      withLock lock:
        claims = idClaims("ann")
        tokenRequests = @[]
      let r = login(c.providerById(org, pid))
      check r.outcome == olOk and r.user == "ann@" & slug
      let u = c.userRoles("ann@" & slug)
      check u.found and u.bindings.len == 1 and u.bindings[0].role == "dev" and u.bindings[0].source == "oidc:" & pid and u.bindings[0].scope == "org:" & slug
      check c.query(%*[["SELECT source, password_hash FROM users WHERE name = ?", "ann@" & slug]])["results"][0]["values"][0] == %*["oidc:" & pid, ""]
      withLock lock:
        let body = tokenRequests[0]
        check "grant_type=authorization_code" in body and "client_secret=s3cret-value" in body and "code=code-1" in body and "code_verifier=" in body and "client_id=cinim" in body
    test "the next login brings the roles up to date: a group gone takes the role away, and with no role left the login is refused":
      withLock lock: claims = idClaims("ann", @["other-group"])
      check login(c.providerById(org, pid)).outcome == olNoRole and c.userRoles("ann@" & slug).bindings.len == 0
      withLock lock: claims = idClaims("ann", @["dev-team", "x"])
      check login(c.providerById(org, pid)).outcome == olOk and c.userRoles("ann@" & slug).bindings.len == 1
    test "a person with no group that gives a role gets no account; with auto_create off an unknown person is told to ask for one; a hand-made account of the same name is not taken over":
      withLock lock: claims = idClaims("nogroups", @["nothing"])
      check login(c.providerById(org, pid)).outcome == olNoRole and not c.userRoles("nogroups@" & slug).found
      check c.putProvider(kek, true, org, pid, %*{"auto_create": false}, now).error == ""
      withLock lock: claims = idClaims("newbie")
      check login(c.providerById(org, pid)).outcome == olNoAccount and not c.userRoles("newbie@" & slug).found
      check c.createUser("hand@" & slug, "dev", "a-long-password-of-hand", now, "org:" & slug)
      withLock lock: claims = idClaims("hand")
      check login(c.providerById(org, pid)).outcome == olNameTaken
      check c.putProvider(kek, true, org, pid, %*{"auto_create": true}, now).error == ""
    test "the claims are checked: issuer, audience (a list may hold it), expiry, nonce; a login that is not a login is refused":
      withLock lock: claims = idClaims("bob", iss = "https://evil.example")
      check login(c.providerById(org, pid)).outcome == olRefused
      withLock lock: claims = idClaims("bob", aud = "another-client")
      check login(c.providerById(org, pid)).outcome == olRefused
      withLock lock: claims = idClaims("bob", exp = now - 10)
      check login(c.providerById(org, pid)).outcome == olRefused
      withLock lock:
        claims = idClaims("bob")
        claims["aud"] = %*["other", "cinim"]
      check login(c.providerById(org, pid)).outcome == olOk
      withLock lock: claims = idClaims("Bad Name!")
      check login(c.providerById(org, pid)).outcome == olRefused and "not a login" in login(c.providerById(org, pid)).detail
    test "a wrong nonce is refused (an ID token of another login), and so is a state used twice, an unknown one and one that has expired":
      let began = c.beginLogin(c.providerById(org, pid), now)
      var params = initTable[string, string]()
      for k, v in decodeQuery(began.url.split('?')[1]): params[k] = v
      withLock lock:
        claims = idClaims("carl")
        lastNonce = "not-the-nonce"
      check c.finishLogin(kek, true, params["state"], "code-1", now).outcome == olRefused
      check c.finishLogin(kek, true, params["state"], "code-1", now).outcome == olBadState          # used up, whatever came of it
      check c.finishLogin(kek, true, "nope", "code-1", now).outcome == olBadState
      let late = c.beginLogin(c.providerById(org, pid), now)
      for k, v in decodeQuery(late.url.split('?')[1]): params[k] = v
      check c.finishLogin(kek, true, params["state"], "code-1", now + 601).outcome == olBadState
    test "a groups claim that the ID token lacks is read from the user info, if it is the same person":
      withLock lock:
        claims = idClaims("dana")
        claims.delete("groups")
        userinfo = %*{"sub": "sub-dana", "groups": ["dev-team"]}
      check login(c.providerById(org, pid)).outcome == olOk and c.userRoles("dana@" & slug).bindings.len == 1
      withLock lock: userinfo = %*{"sub": "someone-else", "groups": ["dev-team"]}
      discard c.execute(%*[["DELETE FROM role_bindings WHERE user_name = ?", "dana@" & slug]])
      check login(c.providerById(org, pid)).outcome == olNoRole
    test "the provider refuses the code, or is not there: the person is told which":
      withLock lock:
        claims = idClaims("erin")
        tokenStatus = 400
      check login(c.providerById(org, pid)).outcome == olRefused
      withLock lock: tokenStatus = 200
      check c.putProvider(kek, true, org, pid, %*{"issuer": "http://127.0.0.1:1"}, now).error == ""
      check c.beginLogin(c.providerById(org, pid), now).ok == false
      check c.putProvider(kek, true, org, pid, %*{"issuer": issuer, "enabled": false}, now).error == ""
      check c.finishLogin(kek, true, "x", "y", now).outcome == olBadState
    test "deleting a provider takes its secret and its map":
      check c.deleteProvider(org, pid) and c.listOidcMappings(org).len == 0 and not c.getSecrets(kek, org, @[secretNameOf(pid)]).ok and not c.deleteProvider(org, pid)
