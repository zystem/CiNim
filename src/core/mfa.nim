## D-101: a second factor at the login, TOTP. A person sets it up (`POST /api/v1/me/mfa/totp:enroll` gives the secret and the address for an authenticator app, `:confirm` with the first code turns it on and gives ten
## recovery codes once); from then the login asks for `code` after the password: the six digits of the app, or a recovery code (each good once). The secret is sealed in the vault of the core (as a secret of the
## pseudo organisation `~mfa`), the recovery codes are kept as hashes. The shard may require it (`CINIM_MFA_REQUIRE_FOR=admin|all`): a person who must have it and has not is allowed nothing but to set it up.
## It applies to the password and to the directory (LDAP) alike; a token already made is not asked again. WebAuthn is not built.
import std/[json, strutils, sets]
import ../common/rqlite
import secretvault, apiauth, totp

const
  mfaTenant* = "~mfa"
  recoveryCodes* = 10

type MfaCheck* = enum mcNotNeeded, mcMissing, mcWrong, mcOk

proc mfaEnabled*(c: var RqClient; user: string): bool =
  let v = c.query(%*[["SELECT enabled FROM user_mfa WHERE user_name = ?", user]])["results"][0]{"values"}
  v != nil and v.len > 0 and v[0][0].getInt > 0

func mfaRequired*(policy: string; admin: bool): bool = policy == "all" or (policy == "admin" and admin)

proc enrollTotp*(c: var RqClient; kek: KekProvider; user, issuer: string; now: int64): tuple[ok: bool, error, secret, uri: string] =
  ## a new secret (the old, not yet confirmed, one is replaced); refused when it is on already
  if c.mfaEnabled(user): return (false, "two-step login is on already: turn it off first", "", "")
  let raw = newSecret()
  let put = c.putSecret(kek, mfaTenant, user, base32Encode(raw), now)
  if not put.ok: return (false, "the secrets of the core are not available: " & put.error, "", "")
  discard c.execute(%*[["INSERT INTO user_mfa (user_name, enabled, last_counter, recovery, created_at) VALUES (?, 0, 0, '', ?) ON CONFLICT(user_name) DO UPDATE SET enabled = 0, last_counter = 0, recovery = '', created_at = excluded.created_at", user, now]])
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
  discard c.execute(%*[["DELETE FROM user_mfa WHERE user_name = ?", user]])

proc checkSecondFactor*(c: var RqClient; kek: KekProvider; user, code: string; now: int64): MfaCheck =
  ## after the password (or the directory) has said yes: nothing more is asked of a person who has not turned it on
  let v = c.query(%*[["SELECT enabled, last_counter, recovery FROM user_mfa WHERE user_name = ?", user]])["results"][0]{"values"}
  if v == nil or v.len == 0 or v[0][0].getInt == 0: return mcNotNeeded
  let given = code.strip
  if given.len == 0: return mcMissing
  if given.len == digits and given.allCharsInSet({'0' .. '9'}):
    let secret = c.secretOf(kek, user)
    if secret.len == 0: return mcWrong
    let ok = verifyTotp(secret, given, now, v[0][1].getBiggestInt)
    if not ok.ok: return mcWrong
    # the code is spent: moving the counter is a compare-and-swap, so two logins with one code cannot both pass
    let r = c.execute(%*[["UPDATE user_mfa SET last_counter = ? WHERE user_name = ? AND last_counter = ?", ok.counter, user, v[0][1].getBiggestInt]])
    return if r["results"][0]{"rows_affected"}.getInt > 0: mcOk else: mcWrong
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
