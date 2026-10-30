## D-97: the audit log (core/audit.nim) goes to the systems that watch it. A shard has **sinks** (`audit_sinks`): `syslog+udp://host:port` and `syslog+tcp://host:port` (one line to an event, in the
## form of RFC 3164 that Wazuh's syslog listener and most collectors read, the event as one line of JSON after the tag `cinim-audit:`), and `http://` / `https://` (the events as lines of JSON,
## `application/x-ndjson`, with a bearer token read from an environment variable of the core whose name begins `CINIM_AUDIT_TOKEN_`). Each sink has a cursor, the id of the last event it was
## given: the core sends what is newer each beat and moves the cursor when the receiver took it, so an event is delivered at least once and in order; a receiver that does not answer is tried again.
## `GET /api/v1/audit/export?after=<id>&limit=` gives the same lines to a system that fetches. The old and the new value of a variable (`before`, `after`) are not sent: a flag `changed` says there were any.
import std/[json, strutils, times, os, net, httpclient, uri, tables]
import ../common/rqlite

const
  maxBatch* = 500
  tokenEnvPrefix* = "CINIM_AUDIT_TOKEN_"
  sinkTimeoutMs = 5000

type Sink* = object
  name*, url*, tokenEnv*: string
  enabled*: bool
  cursor*, lastOkAt*: int64
  lastError*: string

func validSinkName*(n: string): bool =
  if n.len < 1 or n.len > 40 or n[0] notin {'a' .. 'z'}: return false
  for ch in n:
    if ch notin {'a' .. 'z', '0' .. '9', '-', '_'}: return false
  true

func sinkKind*(url: string): string =
  if url.startsWith("syslog+udp://"): "syslog-udp"
  elif url.startsWith("syslog+tcp://"): "syslog-tcp"
  elif url.startsWith("http://") or url.startsWith("https://"): "http"
  else: ""

func hostPort(url: string): tuple[host: string, port: int] =
  let rest = url[url.find("://") + 3 .. ^1].split('/')[0]
  let colon = rest.rfind(':')
  if colon <= 0: return
  result.host = rest[0 ..< colon].strip(chars = {'[', ']'})
  result.port = try: parseInt(rest[colon + 1 .. ^1]) except ValueError: 0

proc parseSink*(name: string; j: JsonNode): tuple[sink: Sink, error: string] =
  ## {"url": "syslog+udp://host:514" | "syslog+tcp://host:514" | "https://...", "token_env": "CINIM_AUDIT_TOKEN_X"?, "enabled": true?}
  if not validSinkName(name): return (Sink(), "a sink is named by lowercase letters, digits, - and _, starting with a letter, at most 40")
  if j == nil or j.kind != JObject or not j.hasKey("url") or j["url"].kind != JString: return (Sink(), "{\"url\": \"syslog+udp://host:514\" | \"syslog+tcp://host:514\" | \"https://...\"} is required")
  let url = j["url"].getStr.strip
  if url.len > 300 or sinkKind(url).len == 0: return (Sink(), "url is syslog+udp://host:port, syslog+tcp://host:port, http:// or https://")
  if sinkKind(url).startsWith("syslog"):
    let hp = hostPort(url)
    if hp.host.len == 0 or hp.port < 1 or hp.port > 65535: return (Sink(), "a syslog url needs a host and a port: syslog+udp://host:514")
  let tokenEnv = if j.hasKey("token_env") and j["token_env"].kind == JString: j["token_env"].getStr else: ""
  if tokenEnv.len > 0:
    if not tokenEnv.startsWith(tokenEnvPrefix) or tokenEnv.len > 60: return (Sink(), "token_env is the name of an environment variable of the core that begins " & tokenEnvPrefix)
    for ch in tokenEnv:
      if ch notin {'A' .. 'Z', '0' .. '9', '_'}: return (Sink(), "token_env is the name of an environment variable of the core that begins " & tokenEnvPrefix)
    if sinkKind(url) != "http": return (Sink(), "a token is for an http sink")
  (Sink(name: name, url: url, tokenEnv: tokenEnv, enabled: not (j.hasKey("enabled") and j["enabled"].kind == JBool and not j["enabled"].getBool)), "")

proc putSink*(c: var RqClient; s: Sink; fromStart: bool) =
  ## a new sink starts at the newest event (`fromStart` false) or at the oldest (true); a sink that exists keeps its cursor
  let top = c.query(%*[["SELECT COALESCE(max(id), 0) FROM audit_log"]])["results"][0]{"values"}[0][0].getBiggestInt
  discard c.execute(%*[["INSERT INTO audit_sinks (name, url, token_env, enabled, cursor) VALUES (?, ?, ?, ?, ?) " &
    "ON CONFLICT(name) DO UPDATE SET url = excluded.url, token_env = excluded.token_env, enabled = excluded.enabled", s.name, s.url, s.tokenEnv, (if s.enabled: 1 else: 0), (if fromStart: 0'i64 else: top)]])

proc deleteSink*(c: var RqClient; name: string): bool =
  c.execute(%*[["DELETE FROM audit_sinks WHERE name = ?", name]])["results"][0]{"rows_affected"}.getInt > 0

proc listSinks*(c: var RqClient): seq[Sink] =
  let v = c.query(%*[["SELECT name, url, token_env, enabled, cursor, last_ok_at, last_error FROM audit_sinks ORDER BY name"]])["results"][0]{"values"}
  if v != nil:
    for r in v:
      result.add Sink(name: r[0].getStr, url: r[1].getStr, tokenEnv: r[2].getStr, enabled: r[3].getInt > 0, cursor: r[4].getBiggestInt, lastOkAt: r[5].getBiggestInt, lastError: r[6].getStr)

func view*(s: Sink): JsonNode =
  result = %*{"name": s.name, "url": s.url, "kind": sinkKind(s.url), "enabled": s.enabled, "cursor": s.cursor, "last_ok_at": s.lastOkAt}
  if s.tokenEnv.len > 0: result["token_env"] = %s.tokenEnv
  if s.lastError.len > 0: result["last_error"] = %s.lastError

type Event* = object
  id*, at*: int64
  json*: string          ## the event as one line of JSON
  severity*: int

proc eventsAfter*(c: var RqClient; after: int64; limit: int): seq[Event] =
  let v = c.query(%*[["SELECT id, at, actor, action, target, outcome, detail, before <> '' OR after <> '' FROM audit_log WHERE id > ? ORDER BY id LIMIT ?", after, max(1, min(limit, maxBatch))]])["results"][0]{"values"}
  if v == nil: return
  for r in v:
    var e = %*{"id": r[0].getBiggestInt, "time": fromUnix(r[1].getBiggestInt).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"), "at": r[1].getBiggestInt, "source": "cinim", "type": "audit",
               "actor": r[2].getStr, "action": r[3].getStr, "target": r[4].getStr, "outcome": r[5].getStr, "detail": r[6].getStr}
    if r[7].getInt > 0: e["changed"] = %true
    result.add Event(id: r[0].getBiggestInt, at: r[1].getBiggestInt, json: $e, severity: (if r[5].getStr in ["ok", "no_role"]: 6 else: 4))

func ndjson*(events: seq[Event]): string =
  for e in events: result.add e.json & "\n"

proc exportLines*(c: var RqClient; after: int64; limit: int): string = ndjson(c.eventsAfter(after, limit))

proc syslogLine*(e: Event; host: string): string =
  ## RFC 3164: `<PRI>Mon dd hh:mm:ss host tag: message`, facility local0; the day is padded with a space, the time is UTC
  let t = fromUnix(e.at).utc
  let day = if t.monthday < 10: " " & $t.monthday else: $t.monthday
  "<" & $(16 * 8 + e.severity) & ">" & t.format("MMM") & " " & day & " " & t.format("HH:mm:ss") & " " & host & " cinim-audit: " & e.json

proc sendSyslog(url: string; lines: seq[string]): string =
  let hp = hostPort(url)
  try:
    if url.startsWith("syslog+udp://"):
      let s = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
      defer: s.close()
      for l in lines: s.sendTo(hp.host, Port(hp.port), l)
    else:
      let s = newSocket()
      defer: s.close()
      s.connect(hp.host, Port(hp.port), sinkTimeoutMs)
      s.send(lines.join("\n") & "\n")
    ""
  except CatchableError as e:
    e.msg

proc sendHttp(url, token: string; body: string): string =
  try:
    let client = newHttpClient(timeout = sinkTimeoutMs, headers = newHttpHeaders({"Content-Type": "application/x-ndjson", "User-Agent": "cinim-core"}))
    defer: client.close()
    if token.len > 0: client.headers["Authorization"] = "Bearer " & token
    let r = client.post(url, body)
    if r.code.int in 200 .. 299: "" else: "the receiver answered " & $r.code.int
  except CatchableError as e:
    e.msg

proc deliverAudit*(rqliteUrl: string; now: int64): int =
  ## One look: each enabled sink is given the events newer than its cursor (at most 500 at a time), and its cursor moves when the receiver took them. Returns how many events were delivered.
  var c = newRq(rqliteUrl)
  let host = block:
    let h = getEnv("HOSTNAME")
    if h.len > 0: h else: "cinim-core"
  for s in c.listSinks():
    if not s.enabled: continue
    let events = c.eventsAfter(s.cursor, maxBatch)
    if events.len == 0: continue
    let err = case sinkKind(s.url)
      of "http": sendHttp(s.url, (if s.tokenEnv.len > 0: getEnv(s.tokenEnv) else: ""), ndjson(events))
      else:
        var lines: seq[string]
        for e in events: lines.add syslogLine(e, host)
        sendSyslog(s.url, lines)
    if err.len == 0:
      discard c.execute(%*[["UPDATE audit_sinks SET cursor = ?, last_ok_at = ?, last_error = '' WHERE name = ?", events[^1].id, now, s.name]])
      result += events.len
    else:
      discard c.execute(%*[["UPDATE audit_sinks SET last_error = ? WHERE name = ?", err[0 ..< min(err.len, 200)], s.name]])
      stderr.writeLine "core: the audit sink " & s.name & " did not take the events: " & err
