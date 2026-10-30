## D-101: a second factor at the login, TOTP. A person sets it up (`POST /api/v1/me/mfa/totp:enroll` gives the secret and the address for an authenticator app, `:confirm` with the first code turns it on and gives ten
## recovery codes once); from then the login asks for `code` after the password: the six digits of the app, or a recovery code (each good once). The secret is sealed in the vault of the core (as a secret of the
## pseudo organisation `~mfa`), the recovery codes are kept as hashes. The shard may require it (`CINIM_MFA_REQUIRE_FOR=admin|all`): a person who must have it and has not is allowed nothing but to set it up.
## It applies to the password and to the directory (LDAP) alike; a token already made is not asked again.
## D-103: security keys (WebAuthn, `webauthn.nim`) are a second factor of their own or beside the app: `POST /me/mfa/webauthn:begin` gives the options for the browser, `:finish` keeps the key (and, for a
## person who has no recovery codes yet, makes them); a login that is asked for the second factor is given the options for a key (`webauthn` in the answer), and the browser's answer goes in `assertion`.
import std/[json, strutils, sets]
import ../common/rqlite
import secretvault, apiauth, totp, webauthn

const
  mfaTenant* = "~mfa"
  recoveryCodes* = 10

type MfaCheck* = enum mcNotNeeded, mcMissing, mcWrong, mcOk

const
  challengeSeconds = 300
  maxKeys = 10
  ticketSeconds = 300
  ticketTries = 5

proc totpEnabled*(c: var RqClient; user: string): bool =
  let v = c.query(%*[["SELECT enabled FROM user_mfa WHERE user_name = ?", user]])["results"][0]{"values"}
  v != nil and v.len > 0 and v[0][0].getInt > 0

proc keyCount*(c: var RqClient; user: string): int =
  c.query(%*[["SELECT count(*) FROM webauthn_credentials WHERE user_name = ?", user]])["results"][0]["values"][0][0].getInt

proc mfaEnabled*(c: var RqClient; user: string): bool =
  ## some second factor is on: the app, a key, or both
  c.totpEnabled(user) or c.keyCount(user) > 0

func mfaRequired*(policy: string; admin: bool): bool = policy == "all" or (policy == "admin" and admin)

proc enrollTotp*(c: var RqClient; kek: KekProvider; user, issuer: string; now: int64): tuple[ok: bool, error, secret, uri: string] =
  ## a new secret (the old, not yet confirmed, one is replaced); refused when it is on already
  if c.totpEnabled(user): return (false, "the authenticator app is on already: turn two-step login off first", "", "")
  let raw = newSecret()
  let put = c.putSecret(kek, mfaTenant, user, base32Encode(raw), now)
  if not put.ok: return (false, "the secrets of the core are not available: " & put.error, "", "")
  discard c.execute(%*[["INSERT INTO user_mfa (user_name, enabled, last_counter, recovery, created_at) VALUES (?, 0, 0, '', ?) ON CONFLICT(user_name) DO UPDATE SET enabled = 0, last_counter = 0, created_at = excluded.created_at", user, now]])
  (true, "", base32Encode(raw), otpauthUri(issuer, user, raw))

proc secretOf(c: var RqClient; kek: KekProvider; user: string): string =
  let got = c.getSecrets(kek, mfaTenant, @[user])
  if got.ok and got.values.len > 0: base32Decode(got.values[0][1]) else: ""

proc confirmTotp*(c: var RqClient; kek: KekProvider; user, code: string; now: int64): tuple[ok: bool, error: string, recovery: seq[string]] =
  let v = c.query(%*[["SELECT enabled FROM user_mfa WHERE user_name = ?", user]])["results"][0]{"values"}
  if v == nil or v.len == 0: return (false, "set it up first: POST /api/v1/me/mfa/totp:enroll", @[])
  if v[0][0].getInt > 0: return (false, "two-step login is on already", @[])
  let secret = c.secretOf(kek, user)
  if secret.len == 0: return (false, "the secret is not available", @[])
  let ok = verifyTotp(secret, code, now, 0)
  if not ok.ok: return (false, "that code is not right: the six digits the app shows now", @[])
  var codes, hashes: seq[string]
  for _ in 0 ..< recoveryCodes:
    let r = newRecoveryCode()
    codes.add r
    hashes.add secretHash(r.replace("-", ""))
  discard c.execute(%*[["UPDATE user_mfa SET enabled = 1, last_counter = ?, recovery = ? WHERE user_name = ?", ok.counter, hashes.join("\n"), user]])
  (true, "", codes)

proc disableMfa*(c: var RqClient; user: string) =
  ## every second factor of the person: the app, the keys and the recovery codes
  discard c.execute(%*[["DELETE FROM user_mfa WHERE user_name = ?", user], ["DELETE FROM webauthn_credentials WHERE user_name = ?", user], ["DELETE FROM webauthn_challenges WHERE user_name = ?", user]])

proc spendChallenge(c: var RqClient; user, kind, challenge: string; now: int64): bool =
  ## a challenge is good once, for the person it was made for and for the thing it was made for
  let r = c.execute(%*[["DELETE FROM webauthn_challenges WHERE challenge = ? AND user_name = ? AND kind = ? AND expires_at >= ?", challenge, user, kind, now]])
  r["results"][0]{"rows_affected"}.getInt > 0

proc newChallenge(c: var RqClient; user, kind: string; now: int64): string =
  result = randomChallenge()
  discard c.execute(%*[["DELETE FROM webauthn_challenges WHERE expires_at < ?", now],
                       ["INSERT INTO webauthn_challenges (challenge, user_name, kind, expires_at) VALUES (?, ?, ?, ?)", result, user, kind, now + challengeSeconds]])

proc keyIds(c: var RqClient; user: string): seq[string] =
  let v = c.query(%*[["SELECT id FROM webauthn_credentials WHERE user_name = ? ORDER BY created_at, id", user]])["results"][0]{"values"}
  if v != nil:
    for r in v: result.add r[0].getStr

proc loginOptions*(c: var RqClient; cfg: WebauthnConfig; user: string; now: int64): JsonNode =
  ## the options for `navigator.credentials.get`, with a challenge made now; nil when the person has no key or the shard is not set up for keys
  if not cfg.enabled: return nil
  let ids = c.keyIds(user)
  if ids.len == 0: return nil
  requestOptions(cfg, c.newChallenge(user, "get", now), ids)

proc assertionOk(c: var RqClient; cfg: WebauthnConfig; user: string; a: JsonNode; now: int64): bool =
  if not cfg.enabled or a.kind != JObject: return false
  let id = a{"id"}.getStr
  let v = c.query(%*[["SELECT public_key, sign_count FROM webauthn_credentials WHERE id = ? AND user_name = ?", id, user]])["results"][0]{"values"}
  if v == nil or v.len == 0: return false
  let pk = unb64url(v[0][0].getStr)
  if not pk.ok or pk.data.len != 64: return false
  let cd = unb64url(a{"clientDataJSON"}.getStr)
  let ad = unb64url(a{"authenticatorData"}.getStr)
  let sig = unb64url(a{"signature"}.getStr)
  if not (cd.ok and ad.ok and sig.ok): return false
  let cred = Credential(id: id, x: pk.data[0 ..< 32], y: pk.data[32 ..< 64], signCount: uint32(v[0][1].getBiggestInt))
  let r = checkAssertion(cfg, cred, cd.data, ad.data, sig.data)
  if not r.ok or not c.spendChallenge(user, "get", r.challenge, now): return false
  # the counter moves with a compare-and-swap, so two logins with one answer cannot both pass
  let u = c.execute(%*[["UPDATE webauthn_credentials SET sign_count = ?, last_used_at = ? WHERE id = ? AND sign_count = ?", int64(r.authData.signCount), now, id, v[0][1].getBiggestInt]])
  u["results"][0]{"rows_affected"}.getInt > 0

proc checkSecondFactor*(c: var RqClient; kek: KekProvider; user, code: string; now: int64; assertion: JsonNode = nil; cfg = WebauthnConfig()): MfaCheck =
  ## after the password (or the directory) has said yes: nothing more is asked of a person who has not turned it on. A person may give the code of the app, a recovery code, or (`assertion`) the
  ## answer of a key to the challenge they were given
  let v = c.query(%*[["SELECT enabled, last_counter, recovery FROM user_mfa WHERE user_name = ?", user]])["results"][0]{"values"}
  let totpOn = v != nil and v.len > 0 and v[0][0].getInt > 0
  if not totpOn and c.keyCount(user) == 0: return mcNotNeeded
  if assertion != nil and assertion.kind == JObject and assertion.len > 0:
    return if c.assertionOk(cfg, user, assertion, now): mcOk else: mcWrong
  let given = code.strip
  if given.len == 0: return mcMissing
  if given.len == digits and given.allCharsInSet({'0' .. '9'}):
    if not totpOn: return mcWrong
    let secret = c.secretOf(kek, user)
    if secret.len == 0: return mcWrong
    let ok = verifyTotp(secret, given, now, v[0][1].getBiggestInt)
    if not ok.ok: return mcWrong
    # the code is spent: moving the counter is a compare-and-swap, so two logins with one code cannot both pass
    let r = c.execute(%*[["UPDATE user_mfa SET last_counter = ? WHERE user_name = ? AND last_counter = ?", ok.counter, user, v[0][1].getBiggestInt]])
    return if r["results"][0]{"rows_affected"}.getInt > 0: mcOk else: mcWrong
  if v == nil or v.len == 0: return mcWrong
  let h = secretHash(given.toUpperAscii.replace("-", "").replace(" ", ""))
  var left: seq[string]
  var found = false
  for x in v[0][2].getStr.split('\n'):
    if x.len == 0: continue
    if x == h and not found: found = true
    else: left.add x
  if not found: return mcWrong
  let r = c.execute(%*[["UPDATE user_mfa SET recovery = ? WHERE user_name = ? AND recovery = ?", left.join("\n"), user, v[0][2].getStr]])
  if r["results"][0]{"rows_affected"}.getInt > 0: mcOk else: mcWrong

proc recoveryLeft*(c: var RqClient; user: string): int =
  let v = c.query(%*[["SELECT recovery FROM user_mfa WHERE user_name = ?", user]])["results"][0]{"values"}
  if v != nil and v.len > 0:
    for x in v[0][0].getStr.split('\n'):
      if x.len > 0: inc result

# ---- D-103: the keys ---------------------------------------------------------------------------------------------------------------------------------

proc beginKey*(c: var RqClient; cfg: WebauthnConfig; user: string; now: int64): tuple[ok: bool, error: string, options: JsonNode] =
  ## the options for `navigator.credentials.create`, with a challenge made now; the keys the person has are listed so that the browser does not make a second credential on one of them
  if not cfg.enabled: return (false, "this shard is not set up for security keys (CINIM_WEBAUTHN_RP_ID and CINIM_WEBAUTHN_ORIGINS)", nil)
  let ids = c.keyIds(user)
  if ids.len >= maxKeys: return (false, "at most " & $maxKeys & " keys: remove one first", nil)
  (true, "", creationOptions(cfg, user, c.newChallenge(user, "create", now), ids))

proc issueRecovery(c: var RqClient; user: string; now: int64): seq[string] =
  var hashes: seq[string]
  for _ in 0 ..< recoveryCodes:
    let r = newRecoveryCode()
    result.add r
    hashes.add secretHash(r.replace("-", ""))
  discard c.execute(%*[["INSERT INTO user_mfa (user_name, enabled, last_counter, recovery, created_at) VALUES (?, 0, 0, ?, ?) ON CONFLICT(user_name) DO UPDATE SET recovery = excluded.recovery", user, hashes.join("\n"), now]])

func cleanName(name: string): string =
  for ch in name:
    if ch >= ' ' and ch != '\x7f' and result.len < 40: result.add ch
  result = result.strip

proc finishKey*(c: var RqClient; cfg: WebauthnConfig; user, name: string; answer: JsonNode; now: int64): tuple[ok: bool, error: string, recovery: seq[string]] =
  ## the answer of the browser to :begin. A person who has no recovery codes yet (no app, no key before) is given them now, once.
  if not cfg.enabled: return (false, "this shard is not set up for security keys", @[])
  if answer.kind != JObject: return (false, "the answer of the browser is required", @[])
  let cd = unb64url(answer{"clientDataJSON"}.getStr)
  let att = unb64url(answer{"attestationObject"}.getStr)
  if not (cd.ok and att.ok): return (false, "clientDataJSON and attestationObject are base64url", @[])
  let r = checkRegistration(cfg, cd.data, att.data)
  if not r.ok: return (false, r.error, @[])
  if not c.spendChallenge(user, "create", r.challenge, now): return (false, "the challenge is not one that was given to you for this (or it is too old): start again", @[])
  if c.keyCount(user) >= maxKeys: return (false, "at most " & $maxKeys & " keys: remove one first", @[])
  let label = block:
    let n = cleanName(name)
    if n.len > 0: n else: "key " & r.credential.id[0 ..< min(6, r.credential.id.len)]
  let put = c.execute(%*[["INSERT OR IGNORE INTO webauthn_credentials (id, user_name, public_key, sign_count, name, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                          r.credential.id, user, b64url(r.credential.x & r.credential.y), int64(r.credential.signCount), label, now]])
  if put["results"][0]{"rows_affected"}.getInt == 0: return (false, "that key is registered already", @[])
  let hadRecovery = c.recoveryLeft(user) > 0
  (true, "", (if hadRecovery: @[] else: c.issueRecovery(user, now)))

proc listKeys*(c: var RqClient; user: string): JsonNode =
  result = newJArray()
  let v = c.query(%*[["SELECT id, name, created_at, last_used_at FROM webauthn_credentials WHERE user_name = ? ORDER BY created_at, id", user]])["results"][0]{"values"}
  if v != nil:
    for r in v: result.add %*{"id": r[0].getStr, "name": r[1].getStr, "created_at": r[2].getBiggestInt, "last_used_at": r[3].getBiggestInt}

proc removeKey*(c: var RqClient; user, id: string): bool =
  ## when it was the last factor, the recovery codes go with it
  let r = c.execute(%*[["DELETE FROM webauthn_credentials WHERE id = ? AND user_name = ?", id, user]])
  result = r["results"][0]{"rows_affected"}.getInt > 0
  if result and not c.totpEnabled(user) and c.keyCount(user) == 0:
    discard c.execute(%*[["DELETE FROM user_mfa WHERE user_name = ?", user]])

# ---- D-103: the ticket between the password and the second factor ---------------------------------------------------------------------------------

proc issueTicket*(c: var RqClient; user: string; now: int64): string =
  ## the password was right and a second factor is to come: the answer to the login holds this, and the second step is `{"ticket", "code" | "assertion"}`, with no password again.
  ## It is good for five minutes and five tries (a six-digit code is guessable otherwise), and only the hash of it is kept.
  result = randomChallenge()
  discard c.execute(%*[["DELETE FROM login_tickets WHERE expires_at < ?", now],
                       ["INSERT INTO login_tickets (hash, user_name, expires_at, attempts) VALUES (?, ?, ?, 0)", secretHash(result), user, now + ticketSeconds]])

proc ticketUser*(c: var RqClient; ticket: string; now: int64): string =
  ## the person a ticket was made for, and one try is counted; "" for a ticket that is unknown, old or out of tries
  let h = secretHash(ticket)
  let u = c.execute(%*[["UPDATE login_tickets SET attempts = attempts + 1 WHERE hash = ? AND expires_at >= ? AND attempts < ?", h, now, ticketTries]])
  if u["results"][0]{"rows_affected"}.getInt == 0: return ""
  let v = c.query(%*[["SELECT user_name FROM login_tickets WHERE hash = ?", h]])["results"][0]{"values"}
  if v != nil and v.len > 0: v[0][0].getStr else: ""

proc spendTicket*(c: var RqClient; ticket: string): bool =
  let r = c.execute(%*[["DELETE FROM login_tickets WHERE hash = ?", secretHash(ticket)]])
  r["results"][0]{"rows_affected"}.getInt > 0
