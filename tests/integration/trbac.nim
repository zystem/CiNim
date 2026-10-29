## IAM-001, basic RBAC (D-50), against a real rqlite: the user `admin` made at the first start (its password has to be changed first), the users an administrator makes with a
## role each, what a token stands for, the login, the change of a password. Needs CINIM_RQLITE_URL (a scratch rqlite); otherwise the suite is skipped.
import std/[unittest, json, os, strutils, sequtils, tables]
import common/[rqlite, sodiumpw]
import core/[schema, apiauth, permissions]

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
      ## what an administrator does with POST /api/v1/users: a person of the organisation `acme` (D-90: the shard has no users but its administrators); a token for the user is what a login would give
      doAssert c.createUser(name, role, pwOf & name, t0, "org:acme")
      c.createApiToken("test " & name, userScope(name), 0, t0).token

    proc baseUser(name, role: string): string =
      ## a person whose role is in an organisation of its own (`base`), so that a test can take the roles of `acme` away and see what is left
      doAssert c.createUser(name, role, pwOf & name, t0, "org:base")
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
      check li.ok and li.roles.len == 0 and not li.mustChange
    test "D-90 a token stands for the roles of its user: admin is the shard\'s administrator and sees every organisation; rw, dev and ro are an organisation\'s and see that one only":
      discard first()
      let a = who(c.createApiToken("t", userScope("admin"), 0, t0).token)
      check a.ok and a.admin and a.roles == @["admin"] and a.mayUseOrg("acme") and a.mayUseOrg("other")
      for role in ["rw", "dev", "ro"]:
        let p = who(makeUser("u-" & role, role))
        check p.ok and not p.admin and p.roles.len == 0 and p.user == "u-" & role and p.mayUseOrg("acme") and not p.mayUseOrg("other")
    test "D-90 the shard has no users but its administrators: a role other than admin given there is no right, the user is listed with it ignored, and the start warns":
      discard first()
      discard c.execute(%*[["INSERT INTO users (name, password_hash, created_at) VALUES ('legacy', ?, ?)", passwordHash(pwOf & "legacy"), t0], ["INSERT INTO role_bindings (user_name, role, scope) VALUES ('legacy', 'rw', 'shard')"]])
      let token = c.createApiToken("t", userScope("legacy"), 0, t0).token
      let gone = who(token)
      check not gone.ok and gone.why == "revoked"                                                         # nothing is left of them: the user has no right at all
      check c.legacyShardBindings() == @[("legacy", "rw")]
      check c.listUsers().filterIt(it["name"].getStr == "legacy")[0]["ignored_shard_roles"] == %*["rw"] and c.listUsers().filterIt(it["name"].getStr == "legacy")[0]["roles"].len == 0
      check not c.login("legacy", pwOf & "legacy", t0).ok
      # given a role in an organisation the same user is a person of that organisation, and the shard role stays ignored
      check c.setMember("org:acme", "legacy", @["dev"]) == ""
      let p = who(token)
      check p.ok and p.roles.len == 0 and p.mayIn("run.start", "acme") and not p.mayCall("GET", "/api/v1/components") and not p.mayCall("GET", "/api/v1/variables")
      check c.login("legacy", pwOf & "legacy", t0).ok
      check allowedAtShard("admin") and not allowedAtShard("dev")
    test "what a user's token may do is what its role may (the gate of the API asks rolesMay)":
      discard first()
      let rw = @["rw"]
      let dev = @["dev"]
      let ro = @["ro"]
      check rolesMay(rw, "POST", "/api/v1/runs") and rolesMay(rw, "DELETE", "/api/v1/runs/x") and not rolesMay(rw, "PUT", "/api/v1/profile")
      check not rolesMay(rw, "POST", "/api/v1/users") and not rolesMay(rw, "GET", "/api/v1/tokens")
      check rolesMay(dev, "POST", "/api/v1/runs") and rolesMay(dev, "POST", "/api/v1/runs/x:abort") and not rolesMay(dev, "DELETE", "/api/v1/runs/x")
      check rolesMay(dev, "GET", "/api/v1/runs/x") and not rolesMay(dev, "PUT", "/api/v1/profile")
      check rolesMay(ro, "GET", "/api/v1/runs/x") and not rolesMay(ro, "POST", "/api/v1/runs")
    test "IAM-001 the actions the page of a run offers (mayCall of the principal of a real token): ro none, dev and rw stop and run again, an organisation's token the same on its own runs":
      discard first()
      let abortPath = "/api/v1/runs/s1_a:abort"
      let retryPath = "/api/v1/runs/s1_a:retry"
      let ro = who(makeUser("u-ro", "ro"))
      check not ro.mayCall("POST", abortPath) and not ro.mayCall("POST", retryPath) and ro.mayCall("GET", "/api/v1/runs/s1_a")
      for role in ["dev", "rw"]:
        let p = who(makeUser("u-" & role, role))
        check p.mayCall("POST", abortPath) and p.mayCall("POST", retryPath)
      let adm = who(c.createApiToken("t", userScope("admin"), 0, t0).token)
      check adm.mayCall("POST", abortPath)
      let org = who(c.createApiToken("acme", "org:acme", 0, t0).token)
      check org.ok and org.org == "acme" and org.mayCall("POST", abortPath) and org.mayUseOrg("acme") and not org.mayUseOrg("other")
      check not org.mayCall("POST", "/api/v1/users") and not org.mayCall("PUT", "/api/v1/profile")
    test "D-84 a role of one's own is a set of permissions: made, changed, listed, and refused when it names a permission that is not one or takes a built-in name":
      discard first()
      check c.putRole("deployer", "starts and stops", @["run.read", "run.start", "run.abort"]) == ""
      check c.rolePermissions("deployer") == @["run.abort", "run.read", "run.start"]
      check c.putRole("deployer", "starts only", @["run.read", "run.start"]) == ""           # replaces
      check c.rolePermissions("deployer") == @["run.read", "run.start"]
      check c.putRole("deployer", "", @["run.fly"]).len > 0 and c.putRole("deployer", "", @[]).len > 0
      check c.putRole("admin", "", @["run.read"]).len > 0 and c.putRole("Bad Name", "", @["run.read"]).len > 0
      let listed = c.listRoles()
      check listed.mapIt(it["name"].getStr) == @["admin", "deployer", "dev", "ro", "rw"]
      check listed.filterIt(it["name"].getStr == "admin")[0]["builtin"].getBool and not listed.filterIt(it["name"].getStr == "deployer")[0]["builtin"].getBool
      check listed.filterIt(it["name"].getStr == "ro")[0]["permissions"].len == builtinPermissions("ro").len
    test "D-84 a user whose only roles are in an organisation holds there and nowhere else, the token works, and the roles of the shard are not touched":
      discard first()
      check c.createUser("olga", "dev", pwOf & "olga", t0, "org:acme")
      let token = c.createApiToken("t", userScope("olga"), 0, t0).token
      let p = who(token)
      check p.ok and p.user == "olga" and p.roles.len == 0 and not p.admin
      check p.mayIn("run.start", "acme") and not p.mayIn("run.start", "beta") and not p.mayIn("run.start", "")
      check p.mayCall("POST", "/api/v1/runs") and p.mayCall("POST", "/api/v1/runs/s1_x:abort") and p.mayCall("GET", "/api/v1/organizations/acme/triggers")
      check not p.mayCall("GET", "/api/v1/organizations/beta/triggers") and not p.mayCall("GET", "/api/v1/components") and not p.mayCall("GET", "/api/v1/users")
      check not p.mayCall("POST", "/api/v1/organizations/acme/triggers") and not p.mayCall("PUT", "/api/v1/organizations/acme/members/ann")
      let li = c.login("olga", pwOf & "olga", t0 + 1)
      check li.ok and li.roles.len == 0
      check c.listUsers().filterIt(it["name"].getStr == "olga")[0]["organizations"]["acme"] == %*["dev"]
    test "D-84 the roles in an organisation are replaced and taken away by its members routes; the others' are not touched; an unknown user or role is refused":
      discard first()
      discard baseUser("ann", "ro")
      check c.createUser("olga", "ro", pwOf & "olga", t0, "org:acme")
      check c.setMember("org:acme", "ann", @["dev", "ro"]) == ""
      check c.setMember("org:beta", "ann", @["ro"]) == ""
      check c.listMembers("org:acme").mapIt(it["user"].getStr) == @["ann", "olga"]
      check c.listMembers("org:acme")[0]["roles"] == %*["dev", "ro"]
      check c.setMember("org:acme", "ann", @["rw"]) == ""                                          # replaces what ann had in acme
      check c.listMembers("org:acme")[0]["roles"] == %*["rw"] and c.listMembers("org:beta")[0]["roles"] == %*["ro"]
      check c.setMember("org:acme", "nobody", @["ro"]).len > 0 and c.setMember("org:acme", "ann", @["no-such-role"]).len > 0
      check c.setMember("org:acme", "ann", @[]) == ""
      check c.listMembers("org:acme").mapIt(it["user"].getStr) == @["olga"]
      let ann = who(c.createApiToken("t", userScope("ann"), 0, t0).token)
      check ann.roles.len == 0 and ann.mayIn("run.read", "base") and not ann.mayIn("run.start", "base") and not ann.mayIn("run.read", "acme")       # what is left is the ro of the other organisation
    test "D-84 a role on a group or a project: held for that node and under it, listed and replaced at exactly that scope, and the other scopes of the user are not touched":
      discard first()
      discard baseUser("ann", "ro")
      check c.setMember("org:acme/ci", "ann", @["dev"]) == ""
      check c.setMember("org:acme", "ann", @["ro"]) == ""
      check c.listMembers("org:acme/ci") == %*[{"user": "ann", "roles": ["dev"]}] and c.listMembers("org:acme") == %*[{"user": "ann", "roles": ["ro"]}]
      let ann = who(c.createApiToken("t", userScope("ann"), 0, t0).token)
      check ann.mayIn("run.start", "acme", "ci") and ann.mayIn("run.start", "acme", "ci/cinim") and not ann.mayIn("run.start", "acme", "team") and not ann.mayIn("run.start", "acme")
      check ann.mayIn("run.read", "acme", "team")                                    # the role of the organisation
      check ann.mayCall("POST", "/api/v1/organizations/acme/triggers/t1:fire") and ann.mayCall("GET", "/api/v1/organizations/acme/groups")
      check not ann.mayCall("POST", "/api/v1/organizations/beta/triggers/t1:fire")
      check c.setMember("org:acme/ci", "ann", @[]) == ""
      check c.listMembers("org:acme/ci").len == 0 and c.listMembers("org:acme").len == 1
      check not who(c.createApiToken("t", userScope("ann"), 0, t0).token).mayIn("run.start", "acme", "ci")
      check c.userRoles("ann").bindings.len == 2          # the ro of base and the ro of acme
    test "GET /api/v1/me: who, the roles with where they are given, what they come to at the shard, in organisations and on groups, and which organisations are seen":
      discard first()
      let adm = who(c.createApiToken("t", userScope("admin"), 0, t0).token)
      let am = c.whoAmI(adm, @["acme", "beta"])
      check am["kind"].getStr == "user" and am["administrator"].getBool and am["permissions"]["shard"].len == catalogue.len and am["organizations"]["all"].getBool
      let ro = who(makeUser("rita", "ro"))
      let rm = c.whoAmI(ro, @["acme", "beta"])
      check rm["user"].getStr == "rita" and not rm["administrator"].getBool and rm["bindings"] == %*[{"role": "ro", "scope": "org:acme", "source": ""}]
      check rm["permissions"]["shard"].len == 0 and "run.read" in $rm["permissions"]["organizations"]["acme"] and "run.start" notin $rm["permissions"]["organizations"]["acme"]
      check rm["organizations"]["all"].getBool == false and rm["organizations"]["slugs"] == %*["acme"]
      check c.createUser("olga", "dev", pwOf & "olga", t0, "org:acme")
      check c.setMember("org:acme/ci", "olga", @["ro"]) == ""
      check c.setMember("org:beta/qa/web", "olga", @["admin"]) == ""
      let om = c.whoAmI(who(c.createApiToken("t", userScope("olga"), 0, t0).token), @["acme", "beta", "gamma"])
      check om["permissions"]["shard"].len == 0 and "run.start" in $om["permissions"]["organizations"]["acme"] and not om["permissions"]["organizations"].hasKey("beta")
      check om["permissions"]["groups"]["beta"][0]["path"].getStr == "qa/web" and "run.start" in $om["permissions"]["groups"]["beta"][0]["permissions"] and "cache.delete" notin $om["permissions"]["groups"]["beta"][0]["permissions"]
      check om["organizations"]["all"].getBool == false and om["organizations"]["slugs"] == %*["acme", "beta"]
      let ot = c.whoAmI(c.authenticate("", c.createApiToken("acme", "org:acme", 0, t0).token, t0 + 1), @[])
      check ot["kind"].getStr == "organization token" and ot["organization"].getStr == "acme" and ot["organizations"]["slugs"] == %*["acme"]
      check not ($am).contains("secret_hash") and not ($rm).contains("password_hash") and not ($rm).contains("token")
    test "GET /api/v1/me/can: allowed or not, which permission and where, which of the caller\'s roles give it, and why not":
      discard first()
      discard makeUser("rita", "ro")
      discard makeUser("dan", "dev")
      let ro = who(c.createApiToken("t", userScope("rita"), 0, t0).token)
      let dev = who(c.createApiToken("t", userScope("dan"), 0, t0).token)
      let abortPath = "/api/v1/runs/s1_x:abort"
      let no = c.explainCall(ro, "POST", abortPath, "acme", "")
      check not no["allowed"].getBool and no["permission"].getStr == "run.abort" and no["granted_by"].len == 0 and "run.abort" in no["reason"].getStr
      let yes = c.explainCall(dev, "post".toUpperAscii, abortPath, "acme", "ci")
      check yes["allowed"].getBool and yes["granted_by"] == %*[{"role": "dev", "scope": "org:acme"}]
      check c.explainCall(ro, "GET", "/api/v1/runs/s1_x", "", "")["allowed"].getBool
      # a role in an organisation, a thing in another one, and a thing of the shard
      check c.createUser("olga", "dev", pwOf & "olga", t0, "org:acme")
      let og = who(c.createApiToken("t", userScope("olga"), 0, t0).token)
      check c.explainCall(og, "POST", abortPath, "acme", "")["allowed"].getBool and c.explainCall(og, "POST", abortPath, "acme", "")["granted_by"] == %*[{"role": "dev", "scope": "org:acme"}]
      check not c.explainCall(og, "POST", abortPath, "beta", "")["allowed"].getBool and c.explainCall(og, "POST", abortPath, "", "")["allowed"].getBool      # anywhere: she has it somewhere
      let shardThing = c.explainCall(og, "GET", "/api/v1/components", "", "")
      check not shardThing["allowed"].getBool and "at the shard" in shardThing["needs"].getStr and "does not count" in shardThing["reason"].getStr
      check c.explainCall(og, "GET", "/api/v1/organizations/acme/triggers", "", "")["allowed"].getBool and not c.explainCall(og, "GET", "/api/v1/organizations/beta/triggers", "", "")["allowed"].getBool
      let unnamed = c.explainCall(dev, "GET", "/api/v1/nothing-like-it", "", "")
      check not unnamed["allowed"].getBool and unnamed["permission"].getStr == "" and "only an administrator" in unnamed["reason"].getStr
      check c.explainCall(who(c.createApiToken("t", userScope("admin"), 0, t0).token), "DELETE", "/api/v1/users/x", "", "")["allowed"].getBool
      check c.explainCall(dev, "GET", "/api/v1/me", "", "")["allowed"].getBool and c.explainCall(dev, "PUT", "/api/v1/users/dan/password", "", "")["allowed"].getBool
      check not c.explainCall(dev, "PUT", "/api/v1/users/rita/password", "", "")["allowed"].getBool
      check dev.mayCall("GET", "/api/v1/me") and dev.mayCall("GET", "/api/v1/me/can") and not dev.mayCall("POST", "/api/v1/me")
    test "D-84 a role of one's own works in the token of a user, at the shard and in an organisation, and cannot be deleted while it is given":
      discard first()
      check c.putRole("deployer", "", @["run.read", "run.start", "trigger.fire"]) == ""
      check c.createUser("dan", "deployer", pwOf & "dan", t0, "org:acme")
      let dan = who(c.createApiToken("t", userScope("dan"), 0, t0).token)
      check dan.roles.len == 0 and dan.mayCall("POST", "/api/v1/runs") and dan.mayCall("POST", "/api/v1/organizations/acme/triggers/t1:fire")
      check not dan.mayCall("POST", "/api/v1/runs/s1_x:abort") and not dan.mayCall("GET", "/api/v1/runs/s1_x/log")
      check c.deleteRole("deployer") == rdInUse and c.deleteRole("ro") == rdBuiltin and c.deleteRole("nope") == rdNotFound
      check c.deleteUser("dan", t0 + 1)
      check c.deleteRole("deployer") == rdDeleted and c.rolePermissions("deployer").len == 0
      # a role changed later changes what the token of its user may do at once
      check c.putRole("qa", "", @["run.read"]) == ""
      discard c.createUser("quinn", "qa", pwOf & "quinn", t0, "org:acme")
      let quinnToken = c.createApiToken("t", userScope("quinn"), 0, t0).token
      check not who(quinnToken).mayCall("POST", "/api/v1/runs")
      check c.putRole("qa", "", @["run.read", "run.start"]) == ""
      check who(quinnToken).mayCall("POST", "/api/v1/runs")
    test "D-84 a user with no binding at all is refused as one whose roles were taken away":
      discard first()
      discard makeUser("zed", "ro")
      let token = c.createApiToken("t", userScope("zed"), 0, t0).token
      check who(token).ok
      discard c.execute(%*[["DELETE FROM role_bindings WHERE user_name = ?", "zed"]])
      check not who(token).ok and who(token).why == "revoked"
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
      check c.createUser("ann", "rw", pwOf & "ann", t0, "org:acme")
      check not c.createUser("ann", "ro", pwOf & "ann", t0, "org:acme")
      check not c.createUser("admin", "ro", pwOf & "admin", t0, "org:acme")
      check c.userRoles("ann").bindings == @[(role: "rw", scope: "org:acme", source: "", cond: BindingCondition())] and c.userRoles("admin").roles == @["admin"]
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
      check li.ok and li.roles.len == 0 and li.expiresAt == t0 + 10 + sessionSeconds
      let p = who(li.token, t0 + 20)
      check p.ok and p.user == "ann" and p.roles.len == 0 and p.mayIn("run.start", "acme")
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
      check l[0]["roles"] == %*["admin"] and l[1]["roles"].len == 0 and l[1]["organizations"]["acme"] == %*["rw"]            # the administrator\'s role is the shard\'s, the person\'s is an organisation\'s
      check l.allIt(it["scope"].getStr == "shard" and not it.hasKey("password_hash") and not it.hasKey("password"))
      check "password_hash" notin $l
    test "a token of a scope user:<name> is a valid scope; others stay as they were":
      check validScope("user:rw") and validScope("admin") and validScope("org:acme")
      check not validScope("user:") and not validScope("user:Bad") and not validScope("role:rw")
    test "D-92 a binding with a term gives nothing after it, and is listed as expired; a new term is a new binding":
      discard first()
      discard makeUser("ann", "ro")
      let tok = c.createApiToken("t", userScope("ann"), 0, t0).token
      check c.setMember("org:acme", "ann", @["dev"], {"dev": BindingCondition(expiresAt: t0 + 100)}.toTable, t0) == ""
      check who(tok, t0 + 50).grants.holds("run.start", "acme") and who(tok, t0 + 50).bindings.len == 1
      let late = who(tok, t0 + 100)
      check not late.ok and late.why == "revoked" and c.userRoles("ann", t0 + 100).found and c.userRoles("ann", t0 + 100).bindings.len == 0          # a user with no role left is refused, as when a role is taken away
      let listed = c.listMembers("org:acme", t0 + 100)[0]
      check listed["roles"] == %*["dev"] and listed["conditions"]["dev"]["expired"].getBool and listed["conditions"]["dev"]["expires_at"].getInt == t0 + 100
      check c.listMembers("org:acme", t0 + 50)[0]["conditions"]["dev"].hasKey("expired") == false
      check c.setMember("org:acme", "ann", @["dev"], {"dev": BindingCondition(expiresAt: t0 + 10)}.toTable, t0 + 20) == "the term of dev is in the past"
      check c.setMember("org:acme", "ann", @["dev"], {"dev": BindingCondition(expiresAt: t0 + 500)}.toTable, t0 + 200) == ""
      check who(tok, t0 + 300).grants.holds("run.start", "acme")
    test "D-92 own runs and refs are kept on the binding and read back into the grants":
      discard first()
      discard makeUser("ann", "ro")
      let tok = c.createApiToken("t", userScope("ann"), 0, t0).token
      check c.setMember("org:acme", "ann", @["dev"], {"dev": BindingCondition(onlyOwn: true, refs: @["main", "release/*"])}.toTable, t0) == ""
      let p = who(tok)
      check p.bindings.len == 1 and p.bindings[0].cond.onlyOwn and p.bindings[0].cond.refs == @["main", "release/*"]
      check not p.grants.holds("run.abort", "acme") and p.grants.holdsRun("run.abort", "acme", "ci", RunFacts(own: true, ref0: "release/1"))
      check not p.grants.holdsRun("run.abort", "acme", "ci", RunFacts(own: false, ref0: "main")) and not p.grants.holdsRun("run.abort", "acme", "ci", RunFacts(own: true, ref0: "x"))
      check p.grants.holds("trigger.fire", "acme")
      let run = %*{"organization": "acme", "project": "ci", "started_by": "user:ann", "source": {"ref": "main"}}
      var pp = p
      pp.need = needOf("POST", "/api/v1/runs/x:abort")
      check pp.mayUseRun(run) and pp.mayInRun("run.abort", run) and not pp.mayInRun("run.abort", %*{"organization": "acme", "project": "ci", "started_by": "user:bob", "source": {"ref": "main"}})
      check pp.mayStart("run.start", "acme", "ci", "release/2") and not pp.mayStart("run.start", "acme", "ci", "") and not pp.mayStart("run.start", "acme", "ci", "dev")
      check pp.mayFireOn("acme", "ci", "main") and not pp.mayFireOn("acme", "ci", "dev")
      check c.listMembers("org:acme")[0]["conditions"]["dev"]["refs"] == %*["main", "release/*"]
      let me = c.whoAmI(p, @[])
      check me["bindings"][0]["condition"]["only_own"].getBool and me["permissions"]["conditional"]["acme"][0]["refs"].len == 2
    test "D-92 a condition is refused where it means nothing or is not well formed":
      discard first()
      discard makeUser("ann", "ro")
      check c.setMember("org:acme", "ann", @["dev"], {"dev": BindingCondition(refs: @["a*b"])}.toTable, t0).startsWith("a ref is a branch or tag name")
      check c.setMember("org:acme", "ann", @["dev"], {"dev": BindingCondition(refs: @["a b"])}.toTable, t0).startsWith("a ref is")
      check c.setMember("shard", "ann", @["dev"], {"dev": BindingCondition(onlyOwn: true)}.toTable, t0) == "a condition is for a role in an organisation"
      let parsed = bindingConditionOf(%*{"role": "dev", "expires_at": "2027-01-15T08:00:00Z", "only_own": true, "refs": ["main"]})
      check parsed.error == "" and parsed.cond.expiresAt == 1_800_000_000'i64 and parsed.cond.onlyOwn and parsed.cond.refs == @["main"]
      check bindingConditionOf(%*{"expires_at": "tomorrow"}).error.len > 0 and bindingConditionOf(%*{"only_own": "yes"}).error.len > 0 and bindingConditionOf(%*{"refs": "main"}).error.len > 0
      check bindingConditionOf(%*{"expires_at": 1_900_000_000}).cond.expiresAt == 1_900_000_000'i64
    clean()
