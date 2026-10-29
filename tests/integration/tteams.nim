## D-91, against a real rqlite: the teams of an organisation - made by hand, with members by hand, roles given to the team (in the organisation and below), what every member comes to,
## and what follows when a member, a team, a user or an organisation goes. Needs CINIM_RQLITE_URL. (A team that takes its members from a group of a directory is in tldap.nim.)
import std/[unittest, json, os, strutils, times, sequtils]
import common/rqlite
import core/[schema, apiauth, teams]

let url = getEnv("CINIM_RQLITE_URL")

suite "D-91 teams":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    c.ensureRoles()
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let now = getTime().toUnix()
    let slug = "tm" & sfx
    let other = "to" & sfx
    let orgId = c.addOrganization(slug, "T")
    let otherId = c.addOrganization(other, "O")
    let pw = "a-long-password-of-the-team-tests"
    proc mk(name: string; org = slug) = doAssert c.createUser(name & sfx, "ro", pw, now, "org:" & org)
    proc u(name: string): string = name & sfx
    proc rightsOf(name: string): Principal =
      let tok = c.createApiToken("t", userScope(u(name)), 0, now).token
      c.authenticate("", tok, now + 1)
    proc bindingsOf(name: string): seq[string] =
      for b in c.userRoles(u(name)).bindings: result.add b.role & "|" & b.scope & "|" & b.source
    let subject = teamSubject(slug, "qa")

    test "a team is made with a name, a description and no members; a second time changes the description; a bad name or an overlong text is refused":
      check c.putTeam(orgId, "qa", %*{"description": "the testers"}, now).created
      check not c.putTeam(orgId, "qa", %*{"description": "the testers of the product"}, now).created
      let l = c.listTeams(orgId, slug)
      check l.len == 1 and l[0]["name"].getStr == "qa" and l[0]["description"].getStr == "the testers of the product" and l[0]["members"].len == 0 and not l[0].hasKey("ldap")
      for bad in ["Qa", "1x", "a b", "", "x".repeat(41), "../x"]: check c.putTeam(orgId, bad, %*{}, now).status == 400
      check c.putTeam(orgId, "qa", %*{"description": "x".repeat(301)}, now).status == 400 and c.putTeam(orgId, "qa", %*[1], now).status == 400
      check c.putTeam(orgId, "qa", %*{"ldap": {"group_dn": "garbage"}}, now).status == 400 and c.putTeam(orgId, "qa", %*{"ldap": {"group_dn": "cn=a,dc=b", "directory": "none"}}, now).status == 404
    test "the same name in another organisation is another team":
      check c.putTeam(otherId, "qa", %*{}, now).created
      check c.listTeams(otherId, other).len == 1 and c.listTeams(orgId, slug).len == 1
      check c.teamId(orgId, "qa") != c.teamId(otherId, "qa")
      check c.deleteTeam(otherId, other, "qa")
    test "members by hand: an account that exists, once; one that is not there is refused; taking one away":
      mk("ann"); mk("bob")
      check c.addTeamMember(orgId, "qa", u("ann")).error == "" and c.addTeamMember(orgId, "qa", u("ann")).error == ""      # again: still one
      check c.addTeamMember(orgId, "qa", u("bob")).error == ""
      check c.addTeamMember(orgId, "qa", "nobody" & sfx).status == 404 and c.addTeamMember(orgId, "none", u("ann")).status == 404
      check c.listTeams(orgId, slug)[0]["members"].mapIt(it["user"].getStr) == @[u("ann"), u("bob")]
      check c.removeTeamMember(orgId, "qa", u("bob")) == (true, "") and c.removeTeamMember(orgId, "qa", u("bob")).found == false
      check c.listTeams(orgId, slug)[0]["members"].len == 1
    test "the roles of a team are given at the organisation or on a group of it, and every member comes to them, with the team named as the source":
      check c.setMember("org:" & slug, subject, @["dev"]) == ""
      check c.setMember("org:" & slug & "/ci", subject, @["rw"]) == ""
      check bindingsOf("ann").len == 3 and ("dev|org:" & slug & "|" & subject) in bindingsOf("ann") and ("rw|org:" & slug & "/ci|" & subject) in bindingsOf("ann") and ("ro|org:" & slug & "|") in bindingsOf("ann")
      let ann = rightsOf("ann")
      check ann.ok and ann.mayIn("run.start", slug) and ann.mayIn("trigger.write", slug, "ci") and not ann.mayIn("trigger.write", slug, "other") and not ann.mayIn("run.start", other)
      check not rightsOf("ann").mayCall("PUT", "/api/v1/organizations/" & slug & "/members/x")
      mk("cyd")                                                             # not a member: only her own ro
      let cyd = rightsOf("cyd")
      check cyd.mayIn("run.read", slug) and not cyd.mayIn("run.start", slug)
      check c.listTeams(orgId, slug)[0]["roles"].len == 2
      check c.listMembers("org:" & slug).anyIt(it["user"].getStr == subject)
    test "a team has roles in its own organisation and below only, and a team that is not there has none":
      check c.setMember("org:" & other, subject, @["dev"]).len > 0 and c.setMember("shard", subject, @["admin"]).len > 0
      check c.setMember("org:" & slug, teamSubject(slug, "ghost"), @["dev"]).len > 0 and c.setMember("org:" & slug, teamSubject(other, "qa"), @["dev"]).len > 0
      check c.setMember("org:" & slug, subject, @["no-such-role"]).len > 0
    test "the rights follow the team at once: a member added gets them, one taken away loses them, a role taken from the team goes from every member":
      check rightsOf("bob").mayIn("run.start", slug) == false
      check c.addTeamMember(orgId, "qa", u("bob")).error == ""
      check rightsOf("bob").mayIn("run.start", slug)
      check c.removeTeamMember(orgId, "qa", u("bob")).found
      check not rightsOf("bob").mayIn("run.start", slug)
      check c.setMember("org:" & slug & "/ci", subject, @[]) == ""
      check not rightsOf("ann").mayIn("trigger.write", slug, "ci") and rightsOf("ann").mayIn("run.start", slug)
    test "a user with no role of their own but a team\\'s is let in; /me says where each role comes from":
      doAssert c.createUser(u("dee"), "ro", pw, now, "org:" & slug)
      check c.setMember("org:" & slug, u("dee"), @[]) == ""                                   # nothing of her own is left
      check c.userRoles(u("dee")).bindings.len == 0 and not rightsOf("dee").ok
      check c.addTeamMember(orgId, "qa", u("dee")).error == ""
      let dee = rightsOf("dee")
      check dee.ok and dee.mayIn("run.start", slug)
      let me = c.whoAmI(dee, @[slug])
      check me["bindings"] == %*[{"role": "dev", "scope": "org:" & slug, "source": subject}]
    test "a team\\'s binding outside its organisation (put there by hand in the table) is no right":
      discard c.execute(%*[["INSERT INTO role_bindings (user_name, role, scope, source) VALUES (?, 'admin', ?, '')", subject, "org:" & other]])
      check not rightsOf("ann").mayIn("run.start", other)
      discard c.execute(%*[["DELETE FROM role_bindings WHERE user_name = ? AND scope = ?", subject, "org:" & other]])
    test "deleting a user takes them out of their teams; deleting a team takes its roles and members; the organisation\\'s purge takes all":
      check c.deleteUser(u("dee"), now)
      check c.query(%*[["SELECT count(*) FROM team_members WHERE user_name = ?", u("dee")]])["results"][0]["values"][0][0].getInt == 0
      check c.putTeam(orgId, "ops", %*{}, now).created and c.addTeamMember(orgId, "ops", u("ann")).error == "" and c.setMember("org:" & slug, teamSubject(slug, "ops"), @["rw"]) == ""
      check rightsOf("ann").mayIn("secret.write", slug)
      check c.deleteTeam(orgId, slug, "ops") and not c.deleteTeam(orgId, slug, "ops")
      check not rightsOf("ann").mayIn("secret.write", slug)
      check c.query(%*[["SELECT count(*) FROM role_bindings WHERE user_name = ?", teamSubject(slug, "ops")]])["results"][0]["values"][0][0].getInt == 0
      c.deleteOrganization(slug)
      check c.query(%*[["SELECT count(*) FROM teams WHERE tenant_id = ?", orgId]])["results"][0]["values"][0][0].getInt == 0
      check c.query(%*[["SELECT count(*) FROM role_bindings WHERE user_name LIKE ?", "team:" & slug & "/%"]])["results"][0]["values"][0][0].getInt == 0
      c.deleteOrganization(other)
