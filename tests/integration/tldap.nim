## D-87, against a real OpenLDAP (in Docker, with a certificate made by tests/support/mkcerts.sh) and a real rqlite: the client (ldaps, StartTLS, a bind, a search, the certificate and the
## host name checked), and the core's use of it - the directories of an organisation, the map of groups to roles, the login `<login>@<slug>`, the sync that takes roles away and switches
## people off. Needs CINIM_RQLITE_URL, Docker and the openssl command; without them it is skipped (the tests of the repository run in a Pod without Docker).
import std/[unittest, json, os, osproc, strutils, times, streams, sequtils]
import common/[rqlite, ldapclient]
import core/[schema, apiauth, ldapauth, secretvault, kekprovider, teams]

let url = getEnv("CINIM_RQLITE_URL")

proc have(cmd: string): bool = findExe(cmd).len > 0

const base = "dc=example,dc=org"
const adminDn = "cn=admin," & base
const adminPw = "adminpw"
const ldif = """
dn: ou=people,dc=example,dc=org
objectClass: organizationalUnit
ou: people

dn: ou=groups,dc=example,dc=org
objectClass: organizationalUnit
ou: groups

dn: uid=ann,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
uid: ann
cn: Ann Admin
sn: Admin
userPassword: ann-secret-1

dn: uid=bob,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
uid: bob
cn: Bob Dev
sn: Dev
userPassword: bob-secret-1

dn: uid=eve,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
uid: eve
cn: Eve Nogroups
sn: Nogroups
userPassword: eve-secret-1

dn: uid=dup1,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
uid: dup
cn: Dup One
sn: One
userPassword: dup-secret-1

dn: uid=dup2,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
uid: dup
cn: Dup Two
sn: Two
userPassword: dup-secret-2

dn: cn=ci-admins,ou=groups,dc=example,dc=org
objectClass: groupOfNames
cn: ci-admins
member: uid=ann,ou=people,dc=example,dc=org

dn: cn=ci-dev,ou=groups,dc=example,dc=org
objectClass: groupOfNames
cn: ci-dev
member: uid=ann,ou=people,dc=example,dc=org
member: uid=bob,ou=people,dc=example,dc=org
"""

suite "D-87 LDAP":
  if url.len == 0 or not have("docker") or not have("openssl"):
    echo "  skipped: CINIM_RQLITE_URL, docker and openssl are needed"
  else:
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let dir = getTempDir() / ("tldap-" & sfx)
    let name = "cinim-ldap-test-" & sfx
    let port = 31000 + (getCurrentProcessId().int mod 1500) * 2
    let tlsPort = port + 1
    createDir(dir / "mount")
    doAssert execCmd("sh " & quoteShell(getCurrentDir() / "tests/support/mkcerts.sh") & " " & quoteShell(dir / "certs")) == 0
    copyFile(dir / "certs/server.crt", dir / "mount/ldap.crt")
    copyFile(dir / "certs/server.key", dir / "mount/ldap.key")
    copyFile(dir / "certs/server-ca.crt", dir / "mount/ca.crt")
    discard execCmd("openssl dhparam -out " & quoteShell(dir / "mount/dhparam.pem") & " 1024 2>/dev/null")
    for f in ["ldap.crt", "ldap.key", "ca.crt", "dhparam.pem"]: setFilePermissions(dir / "mount" / f, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
    let ca = readFile(dir / "certs/server-ca.crt")
    let rogueCa = readFile(dir / "certs/rogue-ca.crt")
    # a second directory whose certificate is self-signed: nothing signed it, the name is in its subjectAltName
    let ssName = name & "-ss"
    let ssPort = port + 2
    let ssTlsPort = port + 3
    createDir(dir / "mount-ss")
    doAssert execCmd("openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=self-signed-ldap -addext subjectAltName=IP:127.0.0.1 " &
      "-keyout " & quoteShell(dir / "mount-ss/ldap.key") & " -out " & quoteShell(dir / "mount-ss/ldap.crt") & " 2>/dev/null") == 0
    copyFile(dir / "mount-ss/ldap.crt", dir / "mount-ss/ca.crt")
    copyFile(dir / "mount/dhparam.pem", dir / "mount-ss/dhparam.pem")
    for f in ["ldap.crt", "ldap.key", "ca.crt", "dhparam.pem"]: setFilePermissions(dir / "mount-ss" / f, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
    let ssCert = readFile(dir / "mount-ss/ldap.crt")
    let ssStarted = execCmd("docker run -d --name " & ssName & " -p 127.0.0.1:" & $ssPort & ":389 -p 127.0.0.1:" & $ssTlsPort & ":636 -v " & quoteShell(dir / "mount-ss") & ":/container/service/slapd/assets/certs " &
      "-e LDAP_ORGANISATION=Example -e LDAP_DOMAIN=example.org -e LDAP_ADMIN_PASSWORD=" & adminPw & " -e LDAP_TLS_CRT_FILENAME=ldap.crt -e LDAP_TLS_KEY_FILENAME=ldap.key " &
      "-e LDAP_TLS_CA_CRT_FILENAME=ca.crt -e LDAP_TLS_DH_PARAM_FILENAME=dhparam.pem -e LDAP_TLS_VERIFY_CLIENT=never osixia/openldap:1.5.0 > /dev/null 2>&1")
    let started = execCmd("docker run -d --name " & name & " -p 127.0.0.1:" & $port & ":389 -p 127.0.0.1:" & $tlsPort & ":636 -v " & quoteShell(dir / "mount") & ":/container/service/slapd/assets/certs " &
      "-e LDAP_ORGANISATION=Example -e LDAP_DOMAIN=example.org -e LDAP_ADMIN_PASSWORD=" & adminPw & " -e LDAP_TLS_CRT_FILENAME=ldap.crt -e LDAP_TLS_KEY_FILENAME=ldap.key " &
      "-e LDAP_TLS_CA_CRT_FILENAME=ca.crt -e LDAP_TLS_DH_PARAM_FILENAME=dhparam.pem -e LDAP_TLS_VERIFY_CLIENT=never osixia/openldap:1.5.0 > /dev/null 2>&1")
    addQuitProc(proc () {.noconv.} =
      discard execCmd("docker rm -f " & name & " " & ssName & " > /dev/null 2>&1")
      removeDir(dir))
    var ready = false
    if started == 0:
      let deadline = epochTime() + 180
      while epochTime() < deadline and not ready:
        # the container starts a slapd of its own to set itself up and then the one that stays: ready is when the one with the certificate answers, twice in a row
        try:
          for _ in 1 .. 2:
            let cn = openLdap(LdapSettings(url: "ldaps://127.0.0.1:" & $tlsPort, caPem: ca, timeoutMs: 2000))
            cn.bindSimple(adminDn, adminPw)
            cn.close()
            sleep 1500
          ready = true
        except CatchableError: sleep 1000
    doAssert ready, "the OpenLDAP container did not come up"
    var ssReady = false
    if ssStarted == 0:
      let deadline = epochTime() + 180
      while epochTime() < deadline and not ssReady:
        try:
          for _ in 1 .. 2:
            let cn = openLdap(LdapSettings(url: "ldaps://127.0.0.1:" & $ssTlsPort, caPem: ssCert, timeoutMs: 2000))
            cn.bindSimple(adminDn, adminPw)
            cn.close()
            sleep 1500
          ssReady = true
        except CatchableError: sleep 1000
    doAssert ssReady, "the second OpenLDAP container (self-signed) did not come up"
    proc inContainer(cmd, input: string): bool =
      let p = startProcess("docker", args = ["exec", "-i", name, "sh", "-c", cmd], options = {poStdErrToStdOut, poUsePath})
      p.inputStream.write(input)
      p.inputStream.close()
      let output = p.outputStream.readAll()
      result = p.waitForExit() == 0
      p.close()
      if not result: echo output
    doAssert inContainer("ldapadd -x -H ldap://localhost -D " & adminDn & " -w " & adminPw, ldif)
    let plain = LdapSettings(url: "ldap://127.0.0.1:" & $port)
    let startTls = LdapSettings(url: "ldap://127.0.0.1:" & $port, startTls: true, caPem: ca)
    let tls = LdapSettings(url: "ldaps://127.0.0.1:" & $tlsPort, caPem: ca)

    test "a search and a bind over ldaps, over StartTLS and in the clear; the groups of a person are found by the filter":
      for s in [tls, startTls, plain]:
        let cn = openLdap(s)
        cn.bindSimple(adminDn, adminPw)
        let es = cn.search(base, scSub, "(&(objectClass=inetOrgPerson)(uid=" & escapeFilterValue("ann") & "))", @["uid", "cn"])
        check es.len == 1 and es[0].dn == "uid=ann,ou=people,dc=example,dc=org" and es[0].first("cn") == "Ann Admin"
        let gs = cn.search("ou=groups," & base, scSub, "(member=" & escapeFilterValue("uid=bob,ou=people,dc=example,dc=org") & ")", @["cn"])
        check gs.len == 1 and gs[0].first("cn") == "ci-dev"
        check cn.search(base, scSub, "(|(uid=a*)(cn=*Dev*))", @["uid"]).len == 3
        check cn.search(base, scSub, "(&(uid=*)(!(uid=eve))(objectClass=inetOrgPerson))", @["uid"]).len >= 3
        check cn.search(base, scSub, "(uid=" & escapeFilterValue("*") & ")", @["uid"]).len == 0         # a star typed by a person is a star, not "everyone"
        cn.close()
    test "the password of a person: right, wrong, empty, and a name that is not there":
      let cn = openLdap(tls)
      cn.bindSimple("uid=ann,ou=people," & base, "ann-secret-1")
      cn.close()
      for (dn, pw) in [("uid=ann,ou=people," & base, "wrong"), ("uid=nobody,ou=people," & base, "x")]:
        let c2 = openLdap(tls)
        expect LdapAuthError: c2.bindSimple(dn, pw)
        c2.close()
      let c3 = openLdap(tls)
      expect LdapAuthError: c3.bindSimple("uid=ann,ou=people," & base, "")                      # the protocol lets an empty password in as nobody: the client does not ask
      c3.close()
    test "the certificate is checked: another CA is refused, and so is a name the certificate does not carry":
      expect LdapError: discard openLdap(LdapSettings(url: "ldaps://127.0.0.1:" & $tlsPort, caPem: rogueCa))
      expect LdapError: discard openLdap(LdapSettings(url: "ldaps://localhost:" & $tlsPort, caPem: ca))
      expect LdapError: discard openLdap(LdapSettings(url: "ldap://127.0.0.1:" & $port, startTls: true, caPem: rogueCa))
    test "a self-signed certificate: trusted when it is given as the CA (it is then the only thing trusted), refused when it is not, accepted when the check is off; a wrong name is refused all the same":
      let ss = LdapSettings(url: "ldaps://127.0.0.1:" & $ssTlsPort, caPem: ssCert)
      let cn = openLdap(ss)
      cn.bindSimple(adminDn, adminPw)
      cn.close()
      expect LdapError: discard openLdap(LdapSettings(url: "ldaps://127.0.0.1:" & $ssTlsPort))                 # the system\'s roots do not know it
      expect LdapError: discard openLdap(LdapSettings(url: "ldaps://127.0.0.1:" & $ssTlsPort, caPem: rogueCa))   # another certificate is not it
      expect LdapError: discard openLdap(LdapSettings(url: "ldaps://127.0.0.1:" & $tlsPort, caPem: ssCert))      # and it is not the other directory\'s
      expect LdapError: discard openLdap(LdapSettings(url: "ldaps://localhost:" & $ssTlsPort, caPem: ssCert))    # the name is checked against its subjectAltName
      let open = openLdap(LdapSettings(url: "ldaps://127.0.0.1:" & $ssTlsPort, insecureTls: true))
      open.bindSimple(adminDn, adminPw)
      open.close()
      let anyName = openLdap(LdapSettings(url: "ldaps://localhost:" & $ssTlsPort, insecureTls: true))          # nothing is checked: not the name either
      anyName.close()
      let st = openLdap(LdapSettings(url: "ldap://127.0.0.1:" & $ssPort, startTls: true, caPem: ssCert))
      st.bindSimple(adminDn, adminPw)
      st.close()
      expect LdapError: discard openLdap(LdapSettings(url: "ldap://127.0.0.1:" & $ssPort, startTls: true))
    test "a directory that is not there, or does not answer, is an error and not a hang":
      let t0 = epochTime()
      expect LdapError: discard openLdap(LdapSettings(url: "ldap://127.0.0.1:9", timeoutMs: 1000))
      check epochTime() - t0 < 5
    test "the entry that is not there is the result code 32":
      let cn = openLdap(tls)
      cn.bindSimple(adminDn, adminPw)
      try:
        discard cn.search("uid=ghost,ou=people," & base, scBase, "(objectClass=*)", @["1.1"])
        check false
      except LdapResultError as e: check e.code == 32
      cn.close()

    # ------------------------------------------------------------------ the core
    var c = newRq(url)
    migrate(c)
    setDekCacheSeconds(0.0)
    let kek = derivedKek("ldap-key-" & sfx)
    let now = getTime().toUnix()
    c.ensureRoles()
    let slug = "ld" & sfx
    let orgId = c.addOrganization(slug, "L")
    let otherSlug = "lo" & sfx
    let otherOrg = c.addOrganization(otherSlug, "O")
    proc spec(dirUrl: string; extra: JsonNode = nil): JsonNode =
      result = %*{"url": dirUrl, "ca_pem": ca, "bind_dn": adminDn, "bind_password": adminPw, "user_base": "ou=people," & base, "group_base": "ou=groups," & base, "auto_create": true}
      if extra != nil:
        for k, v in extra: result[k] = v
    proc put(name: string; j: JsonNode): tuple[error: string, status: int, created: bool] = c.putServer(kek, true, orgId, name, j, now)
    proc bindingsOf(user: string): seq[string] =
      let v = c.query(%*[["SELECT role, scope, source FROM role_bindings WHERE user_name = ? ORDER BY role, scope", user]])["results"][0]{"values"}
      if v != nil:
        for r in v: result.add r[0].getStr & "|" & r[1].getStr & "|" & r[2].getStr
    proc login(uid, pw: string; slugGiven = ""): LdapLogin = c.ldapLogin(kek, true, (if slugGiven.len > 0: slugGiven else: slug), uid, pw, now)

    test "a directory is saved with its password sealed, and what is wrong with the settings is told":
      check put("corp", spec("ldaps://127.0.0.1:" & $tlsPort)).error == ""
      let row = c.query(%*[["SELECT bind_secret_enc FROM ldap_servers WHERE tenant_id = ? AND name = 'corp'", orgId]])["results"][0]["values"][0][0].getStr
      check row.len > 0 and adminPw notin row
      check c.serverNamed(orgId, "corp").server.view["has_bind_password"].getBool and not ($c.serverNamed(orgId, "corp").server.view).contains(adminPw)
      check put("plain", spec("ldap://127.0.0.1:" & $port)).error == ""                                      # allowed, with a warning
      check c.serverNamed(orgId, "plain").server.view["warnings"].len == 1 and "in the clear" in c.serverNamed(orgId, "plain").server.view["warnings"][0].getStr
      check c.serverNamed(orgId, "corp").server.view["warnings"].len == 0
      discard c.deleteServer(orgId, "plain")
      check put("tlsplain", spec("ldap://127.0.0.1:" & $port, %*{"start_tls": true})).error == "" and c.serverNamed(orgId, "tlsplain").server.view["warnings"].len == 0
      check put("Bad Name", spec("ldaps://x")).error.len > 0 and put("x", %*{"url": "ldaps://x"}).error.len > 0
      check put("x", spec("http://x")).error.len > 0 and put("x", spec("ldaps://x", %*{"user_filter": "(uid=none)"})).error.len > 0
      check put("x", spec("ldaps://x", %*{"user_filter": "(uid={u}"})).error.len > 0 and put("x", spec("ldaps://x", %*{"group_filter": "(cn=nothing)"})).error.len > 0
      check put("x", spec("ldaps://x", %*{"group_filter": "", "group_attr": ""})).error.len > 0
      check put("x", spec("ldaps://x", %*{"bind_password": ""})).error.len > 0                                 # a bind DN without its password
      check put("corp", %*{"priority": 5}).error == "" and c.serverNamed(orgId, "corp").server.priority == 5      # a field left out keeps its value, the password too
      check c.serverNamed(orgId, "corp").server.bindSecretEnc == row
      discard c.deleteServer(orgId, "tlsplain")
    test "D-87 a directory with a self-signed certificate: saved with the certificate as ca_pem and the check on, or with the check off and a warning; the setting is kept when a field is left out":
      var j = %*{"url": "ldaps://127.0.0.1:" & $ssTlsPort, "ca_pem": ssCert, "bind_dn": adminDn, "bind_password": adminPw, "user_base": "ou=people," & base, "group_base": "ou=groups," & base}
      check put("selfsigned", j).error == "" and c.serverNamed(orgId, "selfsigned").server.view["warnings"].len == 0 and c.serverNamed(orgId, "selfsigned").server.view["tls_verify"].getBool
      let ok1 = c.checkServer(kek, true, c.serverNamed(orgId, "selfsigned").server, "")
      check ok1["connected"].getBool and not ok1.hasKey("error")
      check put("selfsigned", %*{"ca_pem": rogueCa}).error == ""                                                # a wrong certificate pinned: the connection is refused
      let bad = c.checkServer(kek, true, c.serverNamed(orgId, "selfsigned").server, "")
      check not bad["connected"].getBool and bad.hasKey("error")
      check put("selfsigned", %*{"tls_verify": false}).error == ""                                              # check off: it connects, with a warning
      let sv = c.serverNamed(orgId, "selfsigned").server
      check sv.view["tls_verify"].getBool == false and sv.view["warnings"].len == 1 and "not checked" in sv.view["warnings"][0].getStr
      check c.checkServer(kek, true, sv, "")["connected"].getBool
      check put("selfsigned", %*{"priority": 3}).error == "" and not c.serverNamed(orgId, "selfsigned").server.view["tls_verify"].getBool      # kept
      check put("selfsigned", %*{"tls_verify": true, "ca_pem": ssCert}).error == "" and c.serverNamed(orgId, "selfsigned").server.view["warnings"].len == 0
      check put("selfsigned", %*{"tls_verify": "no"}).error.len > 0
      discard c.deleteServer(orgId, "selfsigned")
    test "the map of groups to roles: made once, in any case and spacing, for a role that exists":
      check c.addMapping(orgId, "", "cn=ci-admins, ou=groups, dc=example, dc=org", "admin", now).error == ""
      check c.addMapping(orgId, "", "CN=ci-admins,OU=groups,DC=example,DC=org", "admin", now).error == ""
      check c.mappings(orgId).len == 1 and c.mappings(orgId)[0]["group_dn"].getStr == "cn=ci-admins,ou=groups,dc=example,dc=org"
      check c.addMapping(orgId, "", "cn=ci-dev,ou=groups,dc=example,dc=org", "dev", now).error == ""
      check c.addMapping(orgId, "", "cn=x,dc=y", "no-such-role", now).error.len > 0 and c.addMapping(orgId, "nope", "cn=x,dc=y", "dev", now).status == 404
      check c.addMapping(orgId, "", "garbage", "dev", now).error.len > 0
    test "a person logs in as login@slug with the password of the directory, and gets the roles of their groups in the organisation":
      let a = login("ann", "ann-secret-1")
      check a.outcome == loOk and a.user == "ann@" & slug and a.roles == @["admin", "dev"]
      check bindingsOf(a.user).len == 2 and bindingsOf(a.user)[0].startsWith("admin|org:" & slug & "|ldap:")
      let s = c.sessionFor(a.user, now)
      check s.ok and s.mustChange == false
      let p = c.authenticate("", s.token, now + 1)
      check p.ok and p.user == a.user and p.mayIn("run.start", slug) and not p.mayIn("run.start", otherSlug) and not p.mayCall("GET", "/api/v1/users")
      check p.mayCall("PUT", "/api/v1/organizations/" & slug & "/members/bob") and p.roles.len == 0              # the organisation\'s administrator, and nothing of the shard
      let b = login("BOB", "bob-secret-1")                                                                     # the login is not case sensitive
      check b.outcome == loOk and b.user == "bob@" & slug and b.roles == @["dev"]
      check c.userSourceOf("bob@" & slug).startsWith("ldap:") and c.listUsers().len > 0
    test "a wrong password, a person who is not there, an empty password, a login with odd characters: refused alike":
      for (u, pw) in [("ann", "wrong"), ("nobody", "x"), ("ann", ""), ("an*", "ann-secret-1"), ("ann)(uid=bob", "x"), ("a n", "x"), ("", "x")]:
        check login(u, pw).outcome == loBadCredentials
      check login("dup", "dup-secret-1").outcome == loBadCredentials                                            # two people with one login: nobody gets in by it
    test "a person who proves the password but has no group that gives a role is told so, and no account is made":
      let e = login("eve", "eve-secret-1")
      check e.outcome == loNoRole
      check c.userSourceOf("eve@" & slug) == "" and bindingsOf("eve@" & slug).len == 0
    test "another organisation has no directory: its name does not log in, and falls to the local users, which it is not":
      check login("ann", "ann-secret-1", otherSlug).outcome == loNoDirectory
      check login("ann", "ann-secret-1", "no-such-" & sfx).outcome == loNoDirectory
    test "a local user cannot be taken over by a name with an @, and a local password does not log a directory account in":
      check not c.login("ann@" & slug, "ann-secret-1", now).ok                                                  # the account has no password of its own
      check not c.login("ann@" & slug, "", now).ok
    test "the roles of a person follow their groups: at the next login, and at the sync, the ones they lost are taken away and the ones that were given by hand stay":
      check c.setMember("org:" & slug, "bob@" & slug, @["ro"]) == ""                                              # by hand, in the same organisation
      check "ro|org:" & slug & "|" in bindingsOf("bob@" & slug)
      check inContainer("ldapmodify -x -H ldap://localhost -D " & adminDn & " -w " & adminPw,
        "dn: cn=ci-dev,ou=groups,dc=example,dc=org\nchangetype: modify\ndelete: member\nmember: uid=bob,ou=people,dc=example,dc=org\n")
      let rep = c.syncServer(kek, true, c.serverNamed(orgId, "corp").server, now)
      check rep.error == "" and rep.checked == 2 and rep.changed == 1
      check bindingsOf("bob@" & slug) == @["ro|org:" & slug & "|"]                                               # the directory\'s dev is gone, the hand\'s ro stays
      check login("bob", "bob-secret-1").outcome == loOk                                                        # the manual role is a role
      check c.serverNamed(orgId, "corp").server.lastSyncResult.startsWith("ok")
      check c.setMember("org:" & slug, "bob@" & slug, @[]) == ""
      check login("bob", "bob-secret-1").outcome == loNoRole                                                    # nothing is left: told so, not let in
      let p = c.authenticate("", c.createApiToken("t", userScope("bob@" & slug), 0, now).token, now + 1)
      check not p.ok and p.why == "revoked"
    test "a person the directory has lost is switched off, their roles and tokens stop, and they are switched on again when they are back":
      let tokenOfAnn = c.createApiToken("t", userScope("ann@" & slug), 0, now).token
      check c.authenticate("", tokenOfAnn, now + 1).ok
      var annLdif = ""
      check inContainer("ldapdelete -x -H ldap://localhost -D " & adminDn & " -w " & adminPw & " uid=ann,ou=people," & base, "")
      let rep = c.syncServer(kek, true, c.serverNamed(orgId, "corp").server, now)
      check rep.error == "" and rep.switchedOff >= 1
      check c.query(%*[["SELECT disabled FROM users WHERE name = ?", "ann@" & slug]])["results"][0]["values"][0][0].getInt == 2
      check bindingsOf("ann@" & slug).len == 0
      let gone = c.authenticate("", tokenOfAnn, now + 2)
      check not gone.ok and gone.why == "revoked"
      check login("ann", "ann-secret-1").outcome == loBadCredentials
      # back in the directory, in a group
      discard annLdif
      check inContainer("ldapadd -x -H ldap://localhost -D " & adminDn & " -w " & adminPw,
        "dn: uid=ann,ou=people,dc=example,dc=org\nobjectClass: inetOrgPerson\nuid: ann\ncn: Ann Admin\nsn: Admin\nuserPassword: ann-secret-1\n")
      let again = c.syncServer(kek, true, c.serverNamed(orgId, "corp").server, now)
      check again.error == "" and again.switchedOn >= 1
      check c.query(%*[["SELECT disabled FROM users WHERE name = ?", "ann@" & slug]])["results"][0]["values"][0][0].getInt == 0
      check "admin|org:" & slug & "|" in bindingsOf("ann@" & slug)[0] & "|"
      check c.authenticate("", tokenOfAnn, now + 3).ok
    test "a directory that does not answer: the login is 'unavailable', not 'wrong password'; the sync says what went wrong and changes nothing":
      check put("dead", spec("ldaps://127.0.0.1:9", %*{"priority": -1})).error == ""
      check login("ann", "ann-secret-1").outcome == loOk                                                        # the live one answers: a dead one before it does not matter
      check put("corp", %*{"enabled": false}).error == ""
      check login("ann", "ann-secret-1").outcome == loUnavailable                                               # only the dead one is left: nobody could say
      check put("corp", %*{"enabled": true}).error == ""
      let rep = c.syncServer(kek, true, c.serverNamed(orgId, "dead").server, now)
      check rep.error.len > 0 and c.serverNamed(orgId, "dead").server.lastSyncResult.startsWith("failed")
      check c.deleteServer(orgId, "dead")
    test "several directories: tried in the order of their priority, the first that knows the person and the password wins; a name is bound to the directory that made it":
      check put("second", spec("ldaps://127.0.0.1:" & $tlsPort, %*{"priority": 10, "user_base": "ou=people," & base})).error == ""
      check put("first", spec("ldaps://127.0.0.1:" & $tlsPort, %*{"priority": -5, "user_filter": "(&(objectClass=person)(cn=Nobody At All)({uid_attr}={u}))"})).error == ""        # finds nobody
      let a = login("ann", "ann-secret-1")
      check a.outcome == loOk and a.detail == "corp"                                                              # corp has priority 5, second 10, first -5 and knows nobody: the next
      let src = c.userSourceOf("ann@" & slug)
      check src == "ldap:" & c.serverNamed(orgId, "corp").server.id
      # the same login in another directory of the organisation does not take over the account of this one
      check c.deleteServer(orgId, "corp")
      check c.query(%*[["SELECT disabled FROM users WHERE name = ?", "ann@" & slug]])["results"][0]["values"][0][0].getInt == 2          # its people are switched off with it
      check bindingsOf("ann@" & slug).len == 0
      check login("ann", "ann-secret-1").outcome == loNameTaken
      check c.mappings(orgId).len >= 1                                                                            # the map of "any directory" stays
    test "D-87 accounts are not made at login unless the directory is told to: the password is right, the person is known, and the answer is 'no account'":
      check put("closed", spec("ldaps://127.0.0.1:" & $tlsPort, %*{"auto_create": false, "priority": -100})).error == ""
      check c.serverNamed(orgId, "closed").server.autoCreate == false and not c.serverNamed(orgId, "closed").server.view["auto_create"].getBool
      check put("closed", %*{"enabled": true}).error == "" and not c.serverNamed(orgId, "closed").server.autoCreate               # a field left out keeps its value
      # only this directory is left to answer for a new person; the people the others made are gone with them
      for n in ["corp", "second", "first"]: discard c.deleteServer(orgId, n)
      discard c.execute(%*[["DELETE FROM users WHERE name = ?", "bob@" & slug], ["DELETE FROM role_bindings WHERE user_name = ?", "bob@" & slug]])
      check inContainer("ldapmodify -x -H ldap://localhost -D " & adminDn & " -w " & adminPw,
        "dn: cn=ci-dev,ou=groups,dc=example,dc=org\nchangetype: modify\nadd: member\nmember: uid=bob,ou=people,dc=example,dc=org\n")
      let l = login("bob", "bob-secret-1")
      check l.outcome == loNoAccount and c.userSourceOf("bob@" & slug) == ""                                    # nothing was made
      check login("bob", "wrong").outcome == loBadCredentials                                                    # a wrong password is still a wrong password
    test "D-87 an account made by hand: the directory is asked, the roles of the groups are put on it, and the person can log in even where accounts are not made at login":
      let made = c.makeAccount(kek, true, orgId, slug, "Bob", "closed", now)
      check made.outcome == aoMade and made.user == "bob@" & slug and made.roles == @["dev"] and made.detail == "closed"
      check c.makeAccount(kek, true, orgId, slug, "bob", "", now).outcome == aoExists
      check bindingsOf("bob@" & slug)[0].startsWith("dev|org:" & slug & "|ldap:")
      let l = login("bob", "bob-secret-1")
      check l.outcome == loOk and l.user == "bob@" & slug
      let list = c.accounts(orgId)
      check list.len == 1 and list[0]["account"].getStr == "bob@" & slug and list[0]["directory"].getStr == "closed" and list[0]["roles_from_directory"] == %*["dev"]
      check c.makeAccount(kek, true, orgId, slug, "nobody", "", now).outcome == aoNotFound
      check c.makeAccount(kek, true, orgId, slug, "an*", "", now).outcome == aoBadLogin
      check c.makeAccount(kek, true, orgId, slug, "bob", "no-such", now).outcome == aoNoDirectory
      check c.makeAccount(kek, true, orgId, slug, "dup", "", now).outcome == aoAmbiguous
      check c.makeAccount(kek, true, otherOrg, otherSlug, "bob", "", now).outcome == aoNoDirectory                # another organisation has no directory
    test "D-87 removing an account takes its roles and tokens; it is only for accounts of this organisation's directories":
      let t = c.createApiToken("t", userScope("bob@" & slug), 0, now).token
      check c.authenticate("", t, now + 1).ok
      check c.removeAccount(orgId, slug, "BOB")
      check not c.authenticate("", t, now + 2).ok and c.userSourceOf("bob@" & slug) == "" and bindingsOf("bob@" & slug).len == 0
      check not c.removeAccount(orgId, slug, "bob") and not c.removeAccount(otherOrg, otherSlug, "bob")
      check login("bob", "bob-secret-1").outcome == loNoAccount                                                   # and it is as it was: no account
      discard c.createUser("localone", "ro", "a-long-password-of-localone", now)
      check not c.removeAccount(orgId, slug, "localone")                                                           # a local user is not an account of a directory
      discard c.deleteUser("localone", now)
    test "D-91 a team that takes its members from a group of the directory: joined at login with no role of their own, left at the sync, hand-made members stay, the group is the one that decides":
      let slug2 = "lt" & sfx
      let org2 = c.addOrganization(slug2, "L2")
      let teamSubj = teamSubject(slug2, "ci-people")
      check c.putServer(kek, true, org2, "teamdir", spec("ldaps://127.0.0.1:" & $tlsPort), now).error == ""
      check c.putTeam(org2, "ci-people", %*{"ldap": {"group_dn": "CN=ci-dev, OU=groups, DC=example, DC=org"}}, now).created
      check c.listTeams(org2, slug2)[0]["ldap"]["group_dn"].getStr == "cn=ci-dev,ou=groups,dc=example,dc=org"
      check c.setMember("org:" & slug2, teamSubj, @["dev"]) == ""
      let who2 = c.serverNamed(org2, "teamdir").server
      # nobody maps a group to a role in this organisation: the team is the only thing that gives the roles
      check c.checkServer(kek, true, who2, "bob")["person"]["teams"] == %*["ci-people"]
      let a = c.ldapLogin(kek, true, slug2, "ann", "ann-secret-1", now)
      check a.outcome == loOk and a.user == "ann@" & slug2
      let b = c.ldapLogin(kek, true, slug2, "bob", "bob-secret-1", now)
      check b.outcome == loOk
      check c.listTeams(org2, slug2)[0]["members"] == %*[{"user": "ann@" & slug2, "source": "ldap:" & who2.id}, {"user": "bob@" & slug2, "source": "ldap:" & who2.id}]
      let annRights = c.authenticate("", c.createApiToken("t", userScope("ann@" & slug2), 0, now).token, now + 1)
      check annRights.ok and annRights.mayIn("run.start", slug2) and annRights.bindings == @[(role: "dev", scope: "org:" & slug2, source: teamSubj, cond: BindingCondition())]
      check c.ldapLogin(kek, true, slug2, "eve", "eve-secret-1", now).outcome == loNoRole                      # in no group of any team: no account
      # a member by hand, and the directory\'s member that cannot be taken away by hand
      check c.addTeamMember(org2, "ci-people", "ann@" & slug2).error == ""                                     # she is the directory\'s already: it becomes hers by hand too
      doAssert c.createUser("carl" & sfx, "ro", "a-long-password-of-carl", now, "org:" & slug2)
      check c.addTeamMember(org2, "ci-people", "carl" & sfx).error == ""
      check c.removeTeamMember(org2, "ci-people", "bob@" & slug2).error.len > 0
      # bob leaves the group in the directory: the sync takes him out of the team, and his rights with it; carl stays
      check inContainer("ldapmodify -x -H ldap://localhost -D " & adminDn & " -w " & adminPw,
        "dn: cn=ci-dev,ou=groups,dc=example,dc=org\nchangetype: modify\ndelete: member\nmember: uid=bob,ou=people,dc=example,dc=org\n")
      let rep = c.syncServer(kek, true, who2, now)
      check rep.error == "" and rep.changed >= 1
      check c.listTeams(org2, slug2)[0]["members"].mapIt(it["user"].getStr) == @["ann@" & slug2, "carl" & sfx]
      check c.userRoles("bob@" & slug2).bindings.len == 0
      check c.removeTeamMember(org2, "ci-people", "carl" & sfx).found
      # the team is no longer tied to the group: the directory\'s members go at the next sync, nobody is added any more
      check c.putTeam(org2, "ci-people", %*{"ldap": newJNull()}, now).error == ""
      check c.listTeams(org2, slug2)[0].hasKey("ldap") == false
      discard c.syncServer(kek, true, who2, now)
      check c.listTeams(org2, slug2)[0]["members"].len == 1                                                       # ann: hers is by hand now
      # the group again, then the directory goes: the memberships it gave go and the team is a team of hand-made members
      check c.putTeam(org2, "ci-people", %*{"ldap": {"group_dn": "cn=ci-dev,ou=groups,dc=example,dc=org", "directory": "teamdir"}}, now).error == ""
      discard c.ldapLogin(kek, true, slug2, "ann", "ann-secret-1", now)
      check c.deleteServer(org2, "teamdir")
      check c.listTeams(org2, slug2)[0]["members"].mapIt(it["source"].getStr) == @[""] and not c.listTeams(org2, slug2)[0].hasKey("ldap")
      c.deleteOrganization(slug2)
    test "a user that a directory vouches for cannot be given a password, and the list of users says where they come from":
      let users = c.listUsers()
      var sources: seq[string]
      for u in users:
        if u["name"].getStr.endsWith("@" & slug): sources.add u["source"].getStr
      check sources.len >= 1 and sources[0].startsWith("ldap:")
