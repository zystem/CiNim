## The audit of security-relevant events (IAM-001, D-52): who did what to whom, and how it ended. A row per event in `audit_log`: logins (the right password, the wrong one, a
## refusal because of too many wrong ones), the making and deleting of users, the change of a password, the making, revoking and rotation of API tokens, a request refused to
## a role (`access.denied`), and the cancel and retry of a run. It is also what the throttle of the login counts (wrong passwords of a name in a few minutes), so no table of its
## own is needed. A row never holds a password, a token or a hash. Rows older than the retention (90 days) are deleted by the watchdog's pass.
## Recording never fails a request: an audit that cannot be written is said once to stderr.
import std/[json, strutils, times]
import ../common/rqlite
import apiauth

const
  auditRetention* = 90 * 86400'i64
  loginMaxFailures* = 5                  ## wrong passwords for one name within `loginWindow` seconds, and the next attempt is refused until the oldest has aged out
  loginWindow* = 300'i64
  loginGlobalMax* = 100                  ## wrong passwords for all names within a minute: somebody is trying many names, nobody may log in until it calms down
  loginGlobalWindow* = 60'i64
  maxDetail = 300

func actorOf*(p: Principal): string =
  ## who is acting: a user by name, the operator's token, another token by its id
  if p.user.len > 0: "user:" & p.user
  elif p.operator: "operator"
  elif p.id.len > 0: "token:" & p.id
  else: "open"

func clip(s: string; n: int): string = (if s.len > n: s[0 ..< n] else: s)

proc record*(c: var RqClient; now: int64; actor, action, target, outcome: string; detail = "") =
  ## `outcome` is `ok`, `failed`, `denied` or `throttled`
  try:
    discard c.execute(%*[["INSERT INTO audit_log (at, actor, action, target, outcome, detail) VALUES (?, ?, ?, ?, ?, ?)",
                          now, clip(actor, 100), clip(action, 60), clip(target, 200), outcome, clip(detail, maxDetail)]])
  except CatchableError as e:
    stderr.writeLine "core: the audit could not be written: " & e.msg

proc list*(c: var RqClient; limit: int; actor = ""; action = ""; target = ""): JsonNode =
  ## the newest first
  var where = ""
  var args: seq[JsonNode]
  for (col, v) in [("actor", actor), ("action", action), ("target", target)]:
    if v.len > 0:
      where.add (if where.len == 0: " WHERE " else: " AND ") & col & " = ?"
      args.add %v
  var stmt = %*["SELECT id, at, actor, action, target, outcome, detail FROM audit_log" & where & " ORDER BY id DESC LIMIT ?"]
  for a in args: stmt.add a
  stmt.add %max(1, min(limit, 1000))
  result = newJArray()
  let vals = c.query(%*[stmt])["results"][0]{"values"}
  if vals != nil:
    for v in vals:
      result.add %*{"id": v[0].getBiggestInt, "at": v[1].getBiggestInt, "actor": v[2].getStr, "action": v[3].getStr, "target": v[4].getStr, "outcome": v[5].getStr,
                    "detail": v[6].getStr}

proc prune*(c: var RqClient; now: int64) =
  discard c.execute(%*[["DELETE FROM audit_log WHERE at < ?", now - auditRetention]])

func loginBlocked*(nameFailures, allFailures: int): bool =
  nameFailures >= loginMaxFailures or allFailures >= loginGlobalMax

proc loginFailures*(c: var RqClient; name: string; since: int64): tuple[count: int, oldest: int64] =
  ## the wrong passwords for this name since `since`, and when the oldest was
  let v = c.query(%*[["SELECT count(*), COALESCE(min(at), 0) FROM audit_log WHERE action = 'login' AND outcome = 'failed' AND target = ? AND at >= ?", clip(name, 200), since]])["results"][0]{"values"}[0]
  (v[0].getInt, v[1].getBiggestInt)

proc loginFailuresAll*(c: var RqClient; since: int64): int =
  c.query(%*[["SELECT count(*) FROM audit_log WHERE action = 'login' AND outcome = 'failed' AND at >= ?", since]])["results"][0]{"values"}[0][0].getInt

proc loginRetryAfter*(c: var RqClient; name: string; now: int64): tuple[blocked: bool, seconds: int] =
  ## whether a login of this name is refused now, and for how long (at least a second)
  let n = c.loginFailures(name, now - loginWindow)
  let all = c.loginFailuresAll(now - loginGlobalWindow)
  if not loginBlocked(n.count, all): return (false, 0)
  let byName = if n.count >= loginMaxFailures: int(n.oldest + loginWindow - now) else: 0
  let byAll = if all >= loginGlobalMax: int(loginGlobalWindow) else: 0
  (true, max(1, max(byName, byAll)))
