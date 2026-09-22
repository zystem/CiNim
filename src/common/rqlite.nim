## Minimal rqlite HTTP client (spike 1). Not a StateStore yet: raw statements in,
## parsed JSON out. One client per thread.

import std/[httpclient, json, strutils]

type
  RqClient* = object
    http: HttpClient
    base: string

  RqError* = object of CatchableError

proc newRq*(base: string; timeoutMs = 15000): RqClient =
  RqClient(http: newHttpClient(timeout = timeoutMs), base: base.strip(chars = {'/'}))

proc post(c: var RqClient; path: string; body: JsonNode): JsonNode =
  c.http.headers = newHttpHeaders({"Content-Type": "application/json"})
  let r = c.http.request(c.base & path, httpMethod = HttpPost, body = $body)
  if not r.code.is2xx:
    raise newException(RqError, "HTTP " & $r.code & ": " & r.body[0 ..< min(200, r.body.len)])
  result = parseJson(r.body)
  # 200 does not mean success: during a leadership change rqlite answers
  # {"results":[],"error":"leadership transfer in progress"} with HTTP 200.
  if result.hasKey("error"):
    raise newException(RqError, result["error"].getStr)
  for item in result{"results"}:
    if item.hasKey("error"):
      raise newException(RqError, item["error"].getStr)

proc execute*(c: var RqClient; stmts: JsonNode; transaction = false): JsonNode =
  ## Write path: always linearizable through Raft. `stmts` is an array of
  ## strings or [sql, param, ...] arrays. `transaction` makes the batch atomic.
  c.post("/db/execute" & (if transaction: "?transaction" else: ""), stmts)

proc query*(c: var RqClient; stmts: JsonNode; level = "strong"): JsonNode =
  c.post("/db/query?level=" & level, stmts)

proc leaderId*(c: var RqClient): string =
  let r = c.http.getContent(c.base & "/nodes")
  for id, n in parseJson(r):
    if n{"leader"}.getBool: return id
