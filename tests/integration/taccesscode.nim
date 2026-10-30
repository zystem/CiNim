## D-98, against a real rqlite: the roles of an organisation as a document: exported, checked whole, applied (dry run says what would change), pruned, and a prune never takes the caller's own roles.
## Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, tables, sequtils, algorithm]
import common/[rqlite]
import core/[schema, apiauth, groups, teams, accesscode]

let url = getEnv("CINIM_RQLITE_URL")

suite "D-98 the roles of an organisation as a document":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let slug = "ac" & sfx
    let org = c.addOrganization(slug, "A")
    let now = getTime().toUnix()
    check c.createGroup(org, "ci", now).error.len == 0
    check c.createProject(org, "ci/app", "https://example.test/app.git", now).error.len == 0
    proc person(role: string): string =
      let name = "p" & sfx & $(c.query(%*[["SELECT count(*) FROM users"]])["results"][0]["values"][0][0].getInt)
      check c.createUser(name, role, "a-long-password-of-" & name, now, "org:" & slug)
      name
    let boss = person("admin")
    let ann = person("ro")
    let bob = person("ro")
    proc reset() =
      discard c.execute(%*[["DELETE FROM role_bindings WHERE scope = ? OR scope LIKE ?", "org:" & slug, "org:" & slug & "/%"], ["DELETE FROM team_members WHERE team_id IN (SELECT id FROM teams WHERE tenant_id = ?)", org], ["DELETE FROM teams WHERE tenant_id = ?", org]])
      check c.setMember("org:" & slug, boss, @["admin"]) == ""
      check c.setMember("org:" & slug, ann, @["ro"]) == ""

    test "the document of an organisation: the hand-given bindings with their conditions, the teams with their hand-made members":
      reset()
      check c.setMember("org:" & slug & "/ci/app", ann, @["dev"], {"dev": BindingCondition(onlyOwn: true, refs: @["main"], expiresAt: now + 100000)}.toTable) == ""
      check c.putTeam(org, "ops", %*{"description": "the operators"}, now).error == ""
      check c.addTeamMember(org, "ops", bob).error == ""
      check c.setMember("org:" & slug, "team:" & slug & "/ops", @["rw"]) == ""
      let d = c.exportAccess(org, slug)
      check d["version"].getInt == 1 and d["organization"].getStr == slug
      let ms = d["members"].elems.mapIt(it["scope"].getStr & " " & it["subject"].getStr)
      check "org:" & slug & " " & boss in ms and "org:" & slug & "/ci/app " & ann in ms and "org:" & slug & " team:ops" in ms
      let annApp = d["members"].elems.filterIt(it["scope"].getStr.endsWith("/ci/app") and it["subject"].getStr == ann)[0]["roles"][0]
      check annApp["role"].getStr == "dev" and annApp["only_own"].getBool and annApp["refs"] == %*["main"] and annApp["expires_at"].getBiggestInt == now + 100000
      check d["teams"][0]["name"].getStr == "ops" and d["teams"][0]["members"] == %*[bob] and d["teams"][0]["ldap"].kind == JNull
    test "the same document applied again changes nothing; a changed one changes only what differs, and a dry run changes nothing":
      reset()
      check c.setMember("org:" & slug & "/ci/app", ann, @["dev"]) == ""
      var d = c.exportAccess(org, slug)
      check c.applyAccess(org, slug, d, false, false, boss, now).changes.filterIt(it["op"].getStr != "team").len == 0
      d["members"].add %*{"scope": "org:" & slug, "subject": bob, "roles": ["dev", {"role": "ro", "only_own": true}]}
      let dry = c.applyAccess(org, slug, d, false, true, boss, now)
      check dry.errors.len == 0 and dry.changes.filterIt(it["op"].getStr == "set").len == 1 and c.userRoles(bob).bindings.len == 0
      let done = c.applyAccess(org, slug, d, false, false, boss, now)
      check done.errors.len == 0 and c.userRoles(bob).bindings.len == 2
      check c.userRoles(bob).grants.holds("run.start", slug)
    test "prune takes away the hand-given roles the document does not name, and leaves the caller\'s own and the ones a directory gives":
      reset()
      check c.setMember("org:" & slug, bob, @["dev"]) == ""
      discard c.execute(%*[["INSERT INTO role_bindings (user_name, role, scope, source) VALUES (?, 'ro', ?, 'ldap:x')", bob, "org:" & slug & "/ci"]])
      let d = %*{"version": 1, "members": [{"scope": "org:" & slug, "subject": boss, "roles": ["admin"]}]}
      check c.applyAccess(org, slug, d, true, true, boss, now).errors.len == 0          # a dry run of a prune: nothing is changed
      check c.userRoles(bob).bindings.len == 2
      let done = c.applyAccess(org, slug, d, true, false, boss, now)
      check done.errors.len == 0 and done.changes.filterIt(it["op"].getStr == "remove").len == 2          # ann\'s ro and bob\'s dev
      check c.userRoles(ann).bindings.len == 0 and c.userRoles(bob).bindings.mapIt(it.source) == @["ldap:x"]
      check c.userRoles(boss).bindings.len == 1
    test "a prune that would take away the caller\'s own roles is refused, and nothing is done":
      reset()
      let d = %*{"version": 1, "members": [{"scope": "org:" & slug, "subject": ann, "roles": ["ro"]}]}
      let r = c.applyAccess(org, slug, d, true, false, boss, now)
      check r.errors.len == 1 and "your own roles" in r.errors[0] and r.changes.len == 0 and c.userRoles(boss).bindings.len == 1
    test "a document with a mistake is refused whole: a role, a user, a team, a scope, a condition":
      reset()
      for (bad, why) in [(%*{"version": 2}, "document is"), (%*{"version": 1, "members": [{"scope": "org:other", "subject": ann, "roles": ["ro"]}]}, "not in the organisation"),
                         (%*{"version": 1, "members": [{"scope": "org:" & slug & "/nope", "subject": ann, "roles": ["ro"]}]}, "no group or project"),
                         (%*{"version": 1, "members": [{"scope": "org:" & slug, "subject": "ghost-" & sfx, "roles": ["ro"]}]}, "no user"),
                         (%*{"version": 1, "members": [{"scope": "org:" & slug, "subject": "team:nobody", "roles": ["ro"]}]}, "no team"),
                         (%*{"version": 1, "members": [{"scope": "org:" & slug, "subject": ann, "roles": ["nosuchrole"]}]}, "no role"),
                         (%*{"version": 1, "members": [{"scope": "org:" & slug, "subject": ann, "roles": [{"role": "ro", "refs": ["a b"]}]}]}, "is a branch or tag") ]:
        let r = c.applyAccess(org, slug, bad, false, false, boss, now)
        check r.errors.len > 0 and r.changes.len == 0
        if r.errors.len > 0: check why in r.errors.join(";") or why == "is a branch or tag"
      check c.userRoles(ann).bindings.len == 1
    test "a team in the document is made, takes its hand-made members, and a team can be the subject of a binding in the same document":
      reset()
      let d = %*{"version": 1, "teams": [{"name": "release", "description": "d", "members": [ann, bob]}], "members": [{"scope": "org:" & slug & "/ci/app", "subject": "team:release", "roles": ["dev"]}]}
      let r = c.applyAccess(org, slug, d, false, false, boss, now)
      check r.errors.len == 0
      check c.userRoles(bob).grants.holds("run.start", slug, "ci/app") and not c.userRoles(bob).grants.holds("run.start", slug, "other")
      let again = c.exportAccess(org, slug)
      check again["teams"][0]["members"].elems.mapIt(it.getStr).sorted == @[ann, bob].sorted
