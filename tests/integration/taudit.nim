## IAM-001, D-52: the audit log and the throttle of the login that counts it (core/audit.nim), against a real rqlite. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times]
import common/rqlite
import core/[schema, audit, apiauth]

let url = getEnv("CINIM_RQLITE_URL")

suite "IAM-001 the audit and the throttle of the login":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let sfx = newId()[^8 .. ^1].toLowerAscii
    let t0 = getTime().toUnix()
    proc clear() = discard c.execute(%*[["DELETE FROM audit_log WHERE actor LIKE ? OR target LIKE ?", "%" & sfx & "%", "%" & sfx & "%"]])

    test "an event is kept with who, what, whom and how it ended, and is listed newest first, with filters":
      clear()
      c.record(t0, "user:admin-" & sfx, "user.create", "ann-" & sfx, "ok", "role dev")
      c.record(t0 + 1, "user:admin-" & sfx, "user.delete", "ann-" & sfx, "ok")
      c.record(t0 + 2, "user:bob-" & sfx, "access", "DELETE /api/v1/runs/x", "denied", "roles ro")
      let all = c.list(10, actor = "user:admin-" & sfx)
      check all.len == 2 and all[0]["action"].getStr == "user.delete" and all[1]["action"].getStr == "user.create"
      check all[1]["detail"].getStr == "role dev" and all[1]["outcome"].getStr == "ok"
      check c.list(10, action = "user.create", target = "ann-" & sfx).len == 1
      check c.list(1, actor = "user:admin-" & sfx).len == 1                      # the limit
      let denied = c.list(10, actor = "user:bob-" & sfx)
      check denied.len == 1 and denied[0]["outcome"].getStr == "denied"
    test "a detail that is too long, and an actor that is, are cut; nothing breaks":
      clear()
      c.record(t0, "a".repeat(500) & sfx, "x", "y-" & sfx, "ok", "d".repeat(5000))
      let r = c.list(1, target = "y-" & sfx)
      check r.len == 1 and r[0]["detail"].getStr.len <= 300 and r[0]["actor"].getStr.len <= 100
    test "rows older than the retention are deleted, newer ones stay":
      clear()
      c.record(t0 - auditRetention - 100, "old-" & sfx, "x", "t", "ok")
      c.record(t0 - 100, "new-" & sfx, "x", "t", "ok")
      c.prune(t0)
      check c.list(10, actor = "old-" & sfx).len == 0 and c.list(10, actor = "new-" & sfx).len == 1
    test "five wrong passwords for a name within five minutes, and the sixth attempt is refused, for as long as the oldest has to age out":
      clear()
      let name = "victim-" & sfx
      for i in 0 ..< 4: c.record(t0 - 100 + i, "login", "login", name, "failed")
      check not c.loginRetryAfter(name, t0).blocked
      c.record(t0 - 90, "login", "login", name, "failed")
      let w = c.loginRetryAfter(name, t0)
      check w.blocked and w.seconds >= 190 and w.seconds <= 200          # the oldest failure (100 s ago) leaves the window of 300 s in 200 s
      check not c.loginRetryAfter("someone-else-" & sfx, t0).blocked        # another name is not affected
    test "failures older than the window do not count":
      clear()
      let name = "slow-" & sfx
      for i in 0 ..< 8: c.record(t0 - 400 + i, "login", "login", name, "failed")
      check not c.loginRetryAfter(name, t0).blocked
    test "successful logins and throttled attempts are not wrong passwords":
      clear()
      let name = "good-" & sfx
      for i in 0 ..< 8: c.record(t0 - 10 + i, "user:" & name, "login", name, "ok")
      for i in 0 ..< 8: c.record(t0 - 10 + i, "login", "login", name, "throttled")
      check not c.loginRetryAfter(name, t0).blocked
    test "the rule is pure: the limits":
      check not loginBlocked(loginMaxFailures - 1, 0) and loginBlocked(loginMaxFailures, 0)
      check not loginBlocked(0, loginGlobalMax - 1) and loginBlocked(0, loginGlobalMax)
    test "who is acting: a user by name, the operator, another token by its id":
      check actorOf(Principal(ok: true, user: "ann")) == "user:ann"
      check actorOf(Principal(ok: true, operator: true, id: "admin")) == "operator"
      check actorOf(Principal(ok: true, id: "abc123")) == "token:abc123"
      check actorOf(Principal(ok: true, admin: true, name: "open API")) == "open"
    clear()
