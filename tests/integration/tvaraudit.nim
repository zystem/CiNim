## VAR-006: the audit of changes of variables and secrets (core/varaudit.nim), against a real rqlite. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, options]
import common/rqlite
import core/[schema, scheduler, audit, apiauth, varaudit, retrypolicy, orgvars]

let url = getEnv("CINIM_RQLITE_URL")

suite "VAR-006 the audit of variables":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let sfx = newId()[^8 .. ^1].toLowerAscii
    let now = getTime().toUnix()
    let who = Principal(ok: true, user: "ann-" & sfx)
    let master = "a-master-key-" & sfx
    let org = c.addOrganization("va" & sfx, "VA")
    let profile = c.ensureOrganizationProfile(org, "cinim-001-va" & sfx)
    let secondOrg = c.addOrganization("vb" & sfx, "VB")
    discard c.ensureOrganizationProfile(secondOrg, "cinim-001-vb" & sfx)
    proc events(action = ""): JsonNode = c.list(50, actor = actorOf(who), action = action)
    proc setMode(m: string) = discard c.execute(%*[["UPDATE execution_profiles SET audit_variables = ? WHERE id = ?", m, profile]])

    test "VAR-006 the audit is off by default: nothing is written for a variable or a secret":
      check c.variableAuditMode(org) == "off"
      c.recordVariable(c.variableAuditMode(org), master, org, now, who, "organization va", "REGION", none(string), some("eu"))
      c.recordSecret(c.variableAuditMode(org), master, org, now, who, "va", "TOKEN", 1, some("s3cret"))
      check events().len == 0
    test "VAR-006 the shard's variables have no organisation and are written in full":
      check c.variableAuditMode("") == "full"
    test "VAR-006 full: the old and the new value of a plain variable are in the record, a delete has the old one":
      setMode("full")
      check c.variableAuditMode(org) == "full"
      c.recordVariable("full", master, org, now, who, "organization va" & sfx, "REGION", none(string), some("eu"))
      c.recordVariable("full", master, org, now + 1, who, "organization va" & sfx, "REGION", some("eu"), some("us"))
      c.recordVariable("full", master, org, now + 2, who, "organization va" & sfx, "REGION", some("us"), none(string))
      let ev = events()
      check ev.len == 3
      check ev[2]["action"].getStr == "variable.set" and ev[2]["after"].getStr == "eu" and not ev[2].hasKey("before")
      check ev[1]["before"].getStr == "eu" and ev[1]["after"].getStr == "us"
      check ev[0]["action"].getStr == "variable.delete" and ev[0]["before"].getStr == "us" and not ev[0].hasKey("after")
      check ev[0]["target"].getStr == "organization va" & sfx & "/REGION"
    test "VAR-006 digest: a short plain value is written, a long one as a digest only":
      let long = 'x'.repeat(300)
      c.recordVariable("digest", master, org, now + 10, who, "group va" & sfx & "/team", "SHORT", none(string), some("abc"))
      c.recordVariable("digest", master, org, now + 11, who, "group va" & sfx & "/team", "LONG", none(string), some(long))
      let ev = events("variable.set")
      var short, longEv: JsonNode
      for e in ev:
        if e["target"].getStr.endsWith("/SHORT"): short = e
        if e["target"].getStr.endsWith("/LONG"): longEv = e
      check short["after"].getStr == "abc"
      check longEv["after"].getStr.startsWith("hmac:") and long notin longEv["after"].getStr and longEv["after"].getStr.len == 5 + 12
    test "VAR-006 a secret is never written: the version and a keyed digest, in both modes; a delete is the fact":
      for m in ["digest", "full"]:
        c.recordSecret(m, master, org, now + 20, who, "va" & sfx, "TOKEN-" & m, 3, some("hunter2"))
      c.recordSecret("full", master, org, now + 21, who, "va" & sfx, "TOKEN-full", 0, none(string))
      let ev = events()
      var sawSet = 0
      for e in ev:
        check "hunter2" notin $e
        if e["action"].getStr == "secret.set":
          inc sawSet
          check e["detail"].getStr == "version 3" and e["after"].getStr.startsWith("hmac:") and not e.hasKey("before")
      check sawSet == 2
      check events("secret.delete").len == 1
    test "VAR-006 the digest is keyed: another tenant, another name, another key give another digest, the same input the same":
      let a = valueDigest(master, org, "TOKEN", "hunter2")
      check a == valueDigest(master, org, "TOKEN", "hunter2")
      check a != valueDigest(master, secondOrg, "TOKEN", "hunter2")
      check a != valueDigest(master, org, "OTHER", "hunter2")
      check a != valueDigest(master & "x", org, "TOKEN", "hunter2")
      check a != valueDigest(master, org, "TOKEN", "hunter3")
    test "VAR-006 the setting is read, validated and saved with the others":
      let co = Core(rqliteUrl: url, profileId: profile, namespace: "cinim-001-va" & sfx)
      var s = loadSettings(c, profile)
      check s.auditVariables == "full"
      s.auditVariables = "sometimes"
      check validate(s).len > 0 and "audit_variables" in validate(s)
      s.auditVariables = "digest"
      check validate(s) == ""
      co.setProfileSettings(s, profile)
      check c.variableAuditMode(org) == "digest"
      check co.getProfileSettings(profile)["audit_variables"].getStr == "digest"
    test "VAR-006 one variable of a level is read before it changes":
      check c.setScopeVariable(vsOrganization, org, "WAS", "one", now) == ""
      check c.scopeVariable(vsOrganization, org, "WAS") == some("one")
      check c.scopeVariable(vsOrganization, org, "NOPE").isNone
