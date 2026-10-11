## IAM-001, basic RBAC (D-50), against a real rqlite: the user `admin` made at the first start (its password has to be changed first), the users an administrator makes with a
## role each, what a token stands for, the login, the change of a password. Needs CINIM_RQLITE_URL (a scratch rqlite); otherwise the suite is skipped.
import std/[unittest, json, os, strutils, sequtils]
import common/[rqlite, sodiumpw]
import core/[schema, apiauth]

let url = getEnv("CINIM_RQLITE_URL")

suite "IAM-001 users, roles and their tokens":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    const t0 = 1_800_000_000'i64
    const pwOf = "a-long-password-of-"                  # + the user's name: 16 characters or more
    proc clean() =
      discard c.execute(%*[["DELETE FROM role_bindings"], ["DELETE FROM users"], ["DELETE FROM roles"], ["DELETE FROM api_tokens WHERE scope LIKE 'user:%'"]])
    proc who(token: string; now = t0 + 1): Principal = c.authenticate("", token, now)
    proc first(): UserCredential =
      clean()
      let made = c.bootstrapAdminUser(t0)
      doAssert made.len == 1
      made[0]
    proc makeUser(name, role: string): string =
      ## what an administrator does with POST /api/v1/users; a token for the user is what a login would give
      doAssert c.createUser(name, role, pwOf & name, t0)
      c.createApiToken("test " & name, userScope(name), 0, t0).token

    test "the first start makes the user admin, with a password and a token, and a second start makes nothing; the roles are made too":
      let a = first()
      check a.user == "admin" and a.role == "admin" and a.password.len == 64 and splitToken(a.token).ok
      check c.bootstrapAdminUser(t0 + 5).len == 0
      let roles = c.query(%*[["SELECT name FROM roles ORDER BY name"]])["results"][0]["values"].mapIt(it[0].getStr)
      check roles == @["admin", "dev", "ro", "rw"]
      check c.listRoles().mapIt(it["name"].getStr) == @["admin", "dev", "ro", "rw"]
    test "the credentials line parses back to what was made":
      let a = first()
      let p = parseCredentialLine(credentialLine(a))
      check p.ok and p.cred == a
    test "no password and no token is stored, only hashes (Argon2id for a password)":
      let a = first()
      let stored = c.query(%*[["SELECT password_hash FROM users"]])["results"][0]["values"].mapIt(it[0].getStr)
      check stored.len == 1 and stored[0].startsWith("$argon2id$") and a.password notin stored and passwordMatches(stored[0], a.password)
      check c.query(%*[["SELECT count(*) FROM api_tokens WHERE secret_hash = ?", splitToken(a.token).secret]])["results"][0]["values"][0][0].getInt == 0
    test "the administrator has to change the password first: every token of the user says so, until the password is changed":
      let a = first()
      let p = who(a.token)
      check p.ok and p.admin and p.mustChange
      let li = c.login("admin", a.password, t0 + 1)
      check li.ok and li.mustChange and who(li.token).mustChange
      check c.changePassword("admin", "a new password of the admin", t0 + 2).ok
      check not who(a.token, t0 + 3).mustChange and not who(li.token, t0 + 3).mustChange
      check not c.login("admin", "a new password of the admin", t0 + 3).mustChange
      check c.listUsers()[0]["password_change_required"].getBool == false
    test "a user an administrator makes may log in at once and has nothing to change":
      discard first()
      discard makeUser("ann", "rw")
      let li = c.login("ann", pwOf & "ann", t0 + 1)
      check li.ok and li.roles == @["rw"] and not li.mustChange
    test "a token stands for the roles of its user: admin is an administrator, rw, dev and ro are shard-wide and in every organisation":
      discard first()
      let a = who(c.createApiToken("t", userScope("admin"), 0, t0).token)
      check a.ok and a.admin and a.roles == @["admin"] and not a.shardWide and a.mayUseOrg("acme") and a.mayUseOrg("other")
      for role in ["rw", "dev", "ro"]:
        let p = who(makeUser("u-" & role, role))
        check p.ok and not p.admin and p.roles == @[role] and p.shardWide and p.user == "u-" & role and p.mayUseOrg("acme") and p.mayUseOrg("other")
    test "what a user's token may do is what its role may (the gate of the API asks rolesMay)":
      discard first()
      let rw = who(makeUser("u-rw", "rw")).roles
      let dev = who(makeUser("u-dev", "dev")).roles
      let ro = who(makeUser("u-ro", "ro")).roles
      check rolesMay(rw, "POST", "/api/v1/runs") and rolesMay(rw, "DELETE", "/api/v1/runs/x") and rolesMay(rw, "PUT", "/api/v1/profile")
      check not rolesMay(rw, "POST", "/api/v1/users") and not rolesMay(rw, "GET", "/api/v1/tokens")
      check rolesMay(dev, "POST", "/api/v1/runs") and rolesMay(dev, "POST", "/api/v1/runs/x:cancel") and not rolesMay(dev, "DELETE", "/api/v1/runs/x")
      check rolesMay(dev, "GET", "/api/v1/runs/x") and not rolesMay(dev, "PUT", "/api/v1/profile")
      check rolesMay(ro, "GET", "/api/v1/runs/x") and not rolesMay(ro, "POST", "/api/v1/runs")
    test "a user's role taken away, or the user switched off: the token stops working at once; another user is not touched":
      discard first()
      let a = makeUser("ann", "rw")
      let b = makeUser("bob", "ro")
      let d = makeUser("dan", "dev")
      discard c.execute(%*[["UPDATE users SET disabled = 1 WHERE name = 'ann'"]])
      check not who(a).ok
      discard c.execute(%*[["DELETE FROM role_bindings WHERE user_name = 'bob'"]])
      check who(b).why == "revoked"
      check who(d).ok
    test "a user is made once, with one role; a name that is taken is refused":
      discard first()
      check c.createUser("ann", "rw", pwOf & "ann", t0)
      check not c.createUser("ann", "ro", pwOf & "ann", t0)
      check not c.createUser("admin", "ro", pwOf & "admin", t0)
      check c.userRoles("ann").roles == @["rw"] and c.userRoles("admin").roles == @["admin"]
    test "a user deleted: the user, the roles, every token and every session are gone":
      discard first()
      let tok = makeUser("ann", "rw")
      let li = c.login("ann", pwOf & "ann", t0 + 1)
      check c.deleteUser("ann", t0 + 2)
      check not c.userRoles("ann").found and who(tok, t0 + 3).why == "revoked" and who(li.token, t0 + 3).why == "revoked"
      check not c.login("ann", pwOf & "ann", t0 + 3).ok
      check c.query(%*[["SELECT count(*) FROM role_bindings WHERE user_name = 'ann'"]])["results"][0]["values"][0][0].getInt == 0
      check not c.deleteUser("ann", t0 + 4)
    test "login: the right password gives a token with the roles, good for 8 hours":
      discard first()
      discard makeUser("ann", "dev")
      let li = c.login("ann", pwOf & "ann", t0 + 10)
      check li.ok and li.roles == @["dev"] and li.expiresAt == t0 + 10 + sessionSeconds
      let p = who(li.token, t0 + 20)
      check p.ok and p.user == "ann" and p.roles == @["dev"] and p.shardWide
      check who(li.token, t0 + 10 + sessionSeconds + 1).why == "expired"
    test "login: a wrong password, an unknown user, another user's password and a switched-off user are all refused":
      discard first()
      discard makeUser("ann", "rw")
      discard makeUser("bob", "ro")
      check not c.login("ann", "wrong", t0).ok
      check not c.login("ann", "", t0).ok
      check not c.login("nobody", pwOf & "ann", t0).ok
      check not c.login("ann", pwOf & "bob", t0).ok
      discard c.execute(%*[["UPDATE users SET disabled = 1 WHERE name = 'ann'"]])
      check not c.login("ann", pwOf & "ann", t0).ok
    test "a user changes the password: the new one logs in, the old one does not, and the sessions of logins are ended but the one that asked":
      discard first()
      let tok = makeUser("ann", "rw")
      discard makeUser("bob", "ro")
      let s1 = c.login("ann", pwOf & "ann", t0 + 1)
      let s2 = c.login("ann", pwOf & "ann", t0 + 1)
      let other = c.login("bob", pwOf & "bob", t0 + 1)
      check c.passwordIs("ann", pwOf & "ann") and not c.passwordIs("ann", "not the password")
      let done = c.changePassword("ann", "a brand new password", t0 + 2, keepToken = splitToken(s1.token).id)
      check done.ok and done.sessionsRevoked == 1
      check who(s1.token, t0 + 3).ok and who(s2.token, t0 + 3).why == "revoked" and who(tok, t0 + 3).ok and who(other.token, t0 + 3).ok
      check not c.login("ann", pwOf & "ann", t0 + 3).ok and c.login("ann", "a brand new password", t0 + 3).ok
      check c.query(%*[["SELECT password_hash FROM users WHERE name = 'ann'"]])["results"][0]["values"][0][0].getStr.startsWith("$argon2id$")
    test "a password of a user that does not exist is not changed, and asking is not an error":
      discard first()
      check not c.changePassword("nobody", "a brand new password", t0).ok
      check not c.passwordIs("nobody", "a brand new password")
    test "a reset (the console's way for the administrator) makes a new password and token, revokes every token of the user, and the password has to be changed again":
      let a = first()
      discard c.changePassword("admin", "a new password of the admin", t0 + 1)
      let r = c.resetUserCredentials("admin", t0 + 2)
      check r.ok and r.cred.user == "admin" and r.cred.role == "admin" and r.cred.password != a.password and r.cred.token != a.token
      check who(a.token, t0 + 3).why == "revoked"
      check not c.login("admin", "a new password of the admin", t0 + 3).ok
      let li = c.login("admin", r.cred.password, t0 + 3)
      check li.ok and li.mustChange and who(r.cred.token, t0 + 3).mustChange
      check not c.resetUserCredentials("nobody", t0).ok
    test "the list of users shows names, roles and whether the password has to be changed, and nothing secret":
      discard first()
      discard makeUser("ann", "rw")
      let l = c.listUsers()
      check l.mapIt(it["name"].getStr) == @["admin", "ann"]
      check l.mapIt(it["password_change_required"].getBool) == @[true, false]
      check l.allIt(it["roles"].len == 1 and it["scope"].getStr == "shard" and not it.hasKey("password_hash") and not it.hasKey("password"))
      check "password_hash" notin $l
    test "a token of a scope user:<name> is a valid scope; others stay as they were":
      check validScope("user:rw") and validScope("admin") and validScope("org:acme")
      check not validScope("user:") and not validScope("user:Bad") and not validScope("role:rw")
    clean()
