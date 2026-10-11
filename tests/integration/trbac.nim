## IAM-001, basic RBAC (D-50), against a real rqlite: the users admin, rw, ro made at the first start with a password and a token each, what a token
## stands for, the login, the reset. Needs CINIM_RQLITE_URL (a scratch rqlite); otherwise the suite is skipped.
import std/[unittest, json, os, strutils, sequtils]
import common/rqlite
import common/sodiumpw
import core/[schema, apiauth]

let url = getEnv("CINIM_RQLITE_URL")

suite "IAM-001 users, roles and their tokens":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    const t0 = 1_800_000_000'i64
    proc clean() =
      discard c.execute(%*[["DELETE FROM role_bindings"], ["DELETE FROM users"], ["DELETE FROM roles"], ["DELETE FROM api_tokens WHERE scope LIKE 'user:%'"]])
    proc who(token: string; now = t0 + 1): Principal = c.authenticate("", token, now)

    test "the first start makes a user for each role, with a password and a token, and a second start makes nothing":
      clean()
      let made = c.bootstrapShardUsers(t0)
      check made.mapIt(it.user) == @["admin", "rw", "ro"]
      check made.mapIt(it.role) == @["admin", "rw", "ro"]
      check made.allIt(it.password.len == 64 and splitToken(it.token).ok)
      check made.mapIt(it.password).deduplicate.len == 3 and made.mapIt(it.token).deduplicate.len == 3
      check c.bootstrapShardUsers(t0 + 5).len == 0
      let roles = c.query(%*[["SELECT name FROM roles ORDER BY name"]])["results"][0]["values"].mapIt(it[0].getStr)
      check roles == @["admin", "ro", "rw"]
    test "the credentials line of each user parses and holds what was made":
      clean()
      for m in c.bootstrapShardUsers(t0):
        let p = parseCredentialLine(credentialLine(m))
        check p.ok and p.cred == m
    test "no password and no token is stored, only hashes (Argon2id for a password)":
      clean()
      let made = c.bootstrapShardUsers(t0)
      let stored = c.query(%*[["SELECT password_hash FROM users"]])["results"][0]["values"].mapIt(it[0].getStr)
      check stored.allIt(it.startsWith("$argon2id$"))
      for m in made:
        check m.password notin stored and stored.anyIt(passwordMatches(it, m.password))
        let t = splitToken(m.token)
        check c.query(%*[["SELECT count(*) FROM api_tokens WHERE secret_hash = ?", t.secret]])["results"][0]["values"][0][0].getInt == 0
    test "a token stands for the roles of its user: admin is an administrator, rw and ro are shard-wide and in every organisation":
      clean()
      let made = c.bootstrapShardUsers(t0)
      let a = who(made[0].token)
      check a.ok and a.admin and a.roles == @["admin"] and not a.shardWide and a.mayUseOrg("acme") and a.mayUseOrg("other")
      let rw = who(made[1].token)
      check rw.ok and not rw.admin and rw.roles == @["rw"] and rw.shardWide and rw.user == "rw" and rw.mayUseOrg("acme") and rw.mayUseOrg("other")
      let ro = who(made[2].token)
      check ro.ok and not ro.admin and ro.roles == @["ro"] and ro.shardWide and ro.mayUseOrg("acme")
    test "what a user's token may do is what its role may (the gate of the API asks rolesMay)":
      clean()
      let made = c.bootstrapShardUsers(t0)
      check rolesMay(who(made[0].token).roles, "PUT", "/api/v1/storage")
      check rolesMay(who(made[1].token).roles, "POST", "/api/v1/runs") and not rolesMay(who(made[1].token).roles, "PUT", "/api/v1/profile")
      check rolesMay(who(made[2].token).roles, "GET", "/api/v1/runs/x") and not rolesMay(who(made[2].token).roles, "POST", "/api/v1/runs")
    test "a user's role taken away, or the user switched off: the token stops working at once":
      clean()
      let made = c.bootstrapShardUsers(t0)
      discard c.execute(%*[["UPDATE users SET disabled = 1 WHERE name = 'rw'"]])
      check not who(made[1].token).ok
      discard c.execute(%*[["DELETE FROM role_bindings WHERE user_name = 'ro'"]])
      check who(made[2].token).why == "revoked"
      check who(made[0].token).ok                          # the other user is not touched
    test "login: the right password gives a token with the roles, good for 8 hours":
      clean()
      let made = c.bootstrapShardUsers(t0)
      let li = c.login("rw", made[1].password, t0 + 10)
      check li.ok and li.roles == @["rw"] and li.expiresAt == t0 + 10 + sessionSeconds
      let p = who(li.token, t0 + 20)
      check p.ok and p.user == "rw" and p.roles == @["rw"] and p.shardWide
      check who(li.token, t0 + 10 + sessionSeconds + 1).why == "expired"
    test "login: a wrong password, an unknown user, another user's password and a switched-off user are all refused":
      clean()
      let made = c.bootstrapShardUsers(t0)
      check not c.login("rw", "wrong", t0).ok
      check not c.login("rw", "", t0).ok
      check not c.login("nobody", made[1].password, t0).ok
      check not c.login("rw", made[2].password, t0).ok
      discard c.execute(%*[["UPDATE users SET disabled = 1 WHERE name = 'rw'"]])
      check not c.login("rw", made[1].password, t0).ok
    test "a reset makes a new password and a new token and revokes every token of the user, also the ones from a login":
      clean()
      let made = c.bootstrapShardUsers(t0)
      let li = c.login("ro", made[2].password, t0 + 1)
      let r = c.resetUserCredentials("ro", t0 + 2)
      check r.ok and r.cred.user == "ro" and r.cred.role == "ro" and r.cred.password != made[2].password and r.cred.token != made[2].token
      check who(made[2].token, t0 + 3).why == "revoked" and who(li.token, t0 + 3).why == "revoked"
      check not c.login("ro", made[2].password, t0 + 3).ok
      check c.login("ro", r.cred.password, t0 + 3).ok
      check who(r.cred.token, t0 + 3).ok and who(r.cred.token, t0 + 3).roles == @["ro"]
      check who(made[0].token, t0 + 3).ok                  # the others stay
    test "a user changes the password: the new one logs in, the old one does not, and the sessions of logins are ended but the one that asked":
      clean()
      let made = c.bootstrapShardUsers(t0)
      let s1 = c.login("rw", made[1].password, t0 + 1)
      let s2 = c.login("rw", made[1].password, t0 + 1)
      let other = c.login("ro", made[2].password, t0 + 1)
      check c.passwordIs("rw", made[1].password) and not c.passwordIs("rw", "not the password")
      let done = c.changePassword("rw", "a brand new password", t0 + 2, keepToken = splitToken(s1.token).id)
      check done.ok and done.sessionsRevoked == 1
      check who(s1.token, t0 + 3).ok                        # the session that asked
      check who(s2.token, t0 + 3).why == "revoked"          # another session of the user
      check who(made[1].token, t0 + 3).ok                   # the token made for the user is not a session
      check who(other.token, t0 + 3).ok                     # another user's session is not touched
      check not c.login("rw", made[1].password, t0 + 3).ok
      check c.login("rw", "a brand new password", t0 + 3).ok
      check c.passwordIs("rw", "a brand new password") and not c.passwordIs("rw", made[1].password)
      check c.query(%*[["SELECT password_hash FROM users WHERE name = 'rw'"]])["results"][0]["values"][0][0].getStr.startsWith("$argon2id$")
    test "a password of a user that does not exist is not changed, and asking is not an error":
      clean()
      discard c.bootstrapShardUsers(t0)
      check not c.changePassword("nobody", "a brand new password", t0).ok
      check not c.passwordIs("nobody", "a brand new password")
    test "a reset of a user that does not exist is refused":
      clean()
      discard c.bootstrapShardUsers(t0)
      check not c.resetUserCredentials("nobody", t0).ok
    test "the list of users shows names and roles and nothing secret":
      clean()
      discard c.bootstrapShardUsers(t0)
      let l = c.listUsers()
      check l.mapIt(it["name"].getStr) == @["admin", "ro", "rw"]
      check l.allIt(it["roles"].len == 1 and it["scope"].getStr == "shard" and not it.hasKey("password_hash") and not it.hasKey("password"))
      check "password_hash" notin $l
    test "a token of a scope user:<name> may be asked for through the token route's rules":
      check validScope("user:rw") and validScope("admin") and validScope("org:acme")
      check not validScope("user:") and not validScope("user:Bad") and not validScope("role:rw")
    clean()
