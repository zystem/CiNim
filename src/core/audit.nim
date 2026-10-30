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
  loginAddrMax* = 20                     ## D-97: wrong passwords from one address within `loginWindow` seconds (all names together)
  loginGlobalMax* = 100                  ## wrong passwords for all names within a minute: somebody is trying many names, nobody may log in until it calms down
  loginGlobalWindow* = 60'i64
  maxDetail = 300
  maxChange = 16384                      ## the old or the new value of a variable (VAR-006): a value is at most 8 KiB

func actorOf*(p: Principal): string =
  ## who is acting: a user by name, the operator's token, another token by its id
  if p.limited: "token:" & p.id                      # D-99: a token with a subset of permissions acts as itself, though it stands for a user
  elif p.user.len > 0: "user:" & p.user
  elif p.operator: "operator"
  elif p.id.len > 0: "token:" & p.id
  else: "open"

func clip(s: string; n: int): string = (if s.len > n: s[0 ..< n] else: s)

proc record*(c: var RqClient; now: int64; actor, action, target, outcome: string; detail = ""; before = ""; after = "") =
  ## `outcome` is `ok`, `failed`, `denied` or `throttled`. `before` and `after` are the old and the new value of a variable, or their digests (VAR-006, core/varaudit.nim)
  try:
    discard c.execute(%*[["INSERT INTO audit_log (at, actor, action, target, outcome, detail, before, after) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                          now, clip(actor, 100), clip(action, 60), clip(target, 200), outcome, clip(detail, maxDetail), clip(before, maxChange), clip(after, maxChange)]])
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
  var stmt = %*["SELECT id, at, actor, action, target, outcome, detail, before, after FROM audit_log" & where & " ORDER BY id DESC LIMIT ?"]
  for a in args: stmt.add a
  stmt.add %max(1, min(limit, 1000))
  result = newJArray()
  let vals = c.query(%*[stmt])["results"][0]{"values"}
  if vals != nil:
    for v in vals:
      var e = %*{"id": v[0].getBiggestInt, "at": v[1].getBiggestInt, "actor": v[2].getStr, "action": v[3].getStr, "target": v[4].getStr, "outcome": v[5].getStr,
                 "detail": v[6].getStr}
      if v[7].getStr.len > 0: e["before"] = v[7]
      if v[8].getStr.len > 0: e["after"] = v[8]
      result.add e

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

func validAddress*(a: string): bool =
  ## an IPv4 or IPv6 address as text (digits, hex digits, dots, colons, a %zone is not taken), at most 45 characters: what a proxy puts in a header, checked before it is kept or looked up
  if a.len < 2 or a.len > 45 or not (a.contains('.') or a.contains(':')): return false
  for ch in a:
    if ch notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F', '.', ':'}: return false
  true

func clientAddressOf*(headerValue: string): string =
  ## D-97: the address in the header the shard names (`CINIM_CLIENT_ADDR_HEADER`, set by the proxy in front, which overwrites what a client sends); a list takes its first, one that is not an address is none
  let first = headerValue.split(',')[0].strip
  if validAddress(first): first else: ""

proc loginFailuresFrom*(c: var RqClient; address: string; since: int64): tuple[count: int, oldest: int64] =
  ## the wrong passwords from this address since `since` (the failed rows carry `addr=<address>` in their detail)
  if address.len == 0: return
  let v = c.query(%*[["SELECT count(*), COALESCE(min(at), 0) FROM audit_log WHERE action = 'login' AND outcome = 'failed' AND at >= ? AND detail LIKE ?", since, "%addr=" & address & "%"]])["results"][0]{"values"}[0]
  (v[0].getInt, v[1].getBiggestInt)

proc loginRetryAfter*(c: var RqClient; name: string; now: int64; address = ""): tuple[blocked: bool, seconds: int] =
  ## whether a login of this name (or from this address) is refused now, and for how long (at least a second)
  let n = c.loginFailures(name, now - loginWindow)
  let a = c.loginFailuresFrom(address, now - loginWindow)
  let all = c.loginFailuresAll(now - loginGlobalWindow)
  if not loginBlocked(n.count, all) and a.count < loginAddrMax: return (false, 0)
  let byName = if n.count >= loginMaxFailures: int(n.oldest + loginWindow - now) else: 0
  let byAddr = if a.count >= loginAddrMax: int(a.oldest + loginWindow - now) else: 0
  let byAll = if all >= loginGlobalMax: int(loginGlobalWindow) else: 0
  (true, max(1, max(byName, max(byAddr, byAll))))
