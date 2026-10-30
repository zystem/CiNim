## What the UI knows of the core: three calls, and what they say in the terms of a page (docs/ui.md). `login` is POST /api/v1/login; `get` is a GET of any path of the API with the token of the user; `post` is a POST of an action.
## They are closures so that the tests give the UI a core that says what the test wants (tests/unit/tui.nim); `httpCoreApi` is the real one, over std/httpclient (plain HTTP inside the cluster).
import std/[json, httpclient, strutils, os]

proc clientAddrHeader*(): string = getEnv("CINIM_CLIENT_ADDR_HEADER")          ## D-97: the header in which a trusted proxy puts the address of the person; the UI passes it on to the core with the login (empty: none)

type
  ApiStatus* = enum
    asOk, asUnauthorized, asForbidden, asNotFound, asUnavailable, asRefused

  ApiResult* = object
    status*: ApiStatus
    code*: int                       ## the HTTP status of the core's answer (0: there was none)
    body*: JsonNode                  ## the JSON of an answer that was asOk
    problem*: string                 ## the `code` of a problem+json answer of the core (mfa_required, ...), "" when there was none
    message*: string                 ## what the core said (its `code` or `detail`) or why there was no answer; shown to a person, so plain words

  CoreApi* = object
    login*: proc (user, password, client, code: string): ApiResult {.gcsafe.}          ## `client` is the address of the person (D-97), "" when the UI is not told one
    loginSecond*: proc (ticket, code, assertion, client: string): ApiResult {.gcsafe.}          ## D-103: the second step of a login that answered `mfa_required` with a ticket: the code, or the JSON answer of a security key
    loginOptions*: proc (): ApiResult {.gcsafe.}                       ## GET /api/v1/login/options: the organisations a person can choose at the login (D-87), asked with no token
    get*: proc (token, pathAndQuery: string): ApiResult {.gcsafe.}
    post*: proc (token, path, body: string): ApiResult {.gcsafe.}      ## a POST of an action (abort, retry) with the token of the user
    send*: proc (meth, token, path, body: string): ApiResult {.gcsafe.}   ## any call of the API with the token of the user: PUT and DELETE of roles, members, mappings

proc problemText(body: string): string =
  ## the words of a problem+json answer of the core: `detail` first, then `code`
  try:
    let j = parseJson(body)
    if j.kind == JObject:
      let d = j{"detail"}.getStr
      return if d.len > 0: d else: j{"code"}.getStr
  except JsonParsingError:
    discard

proc problemCode(body: string): string =
  try:
    let j = parseJson(body)
    if j.kind == JObject: return j{"code"}.getStr
  except JsonParsingError:
    discard

proc resultOf(code: int; retryAfter, body: string): ApiResult =
  result.code = code
  if code >= 400 and code < 500: result.problem = problemCode(body)
  case code
  of 200, 201:
    result.status = asOk
    result.body = try: parseJson(body) except JsonParsingError: newJObject()
  of 401:
    result.status = asUnauthorized
    result.message = problemText(body)
    if result.problem == "mfa_required":                                  # D-103: the ticket and the options for a key are in the body
      result.body = try: parseJson(body) except JsonParsingError: newJObject()
  of 403: (result.status = asForbidden; result.message = problemText(body))
  of 404: (result.status = asNotFound; result.message = problemText(body))
  of 429:
    result.status = asRefused
    result.message = "retry after " & (if retryAfter.len > 0: retryAfter else: "a while") & " s"
  elif code >= 500:
    result.status = asUnavailable
    result.message = "the core answered " & $code
  else:
    result.status = asRefused
    result.message = problemText(body)

proc httpCoreApi*(url: string; timeoutMs = 10000): CoreApi =
  ## the core at `url` (http://host:port, no trailing slash)
  let base = url.strip(chars = {'/'}, leading = false)
  proc call(meth: HttpMethod; path, token, body: string; client = ""): ApiResult =
    var c: HttpClient
    try:
      c = newHttpClient(timeout = timeoutMs)
      c.headers = newHttpHeaders({"Accept": "application/json", "Content-Type": "application/json"})
      if token.len > 0: c.headers["Authorization"] = "Bearer " & token
      if client.len > 0 and clientAddrHeader().len > 0: c.headers[clientAddrHeader()] = client
      let r = c.request(base & path, httpMethod = meth, body = body)
      result = resultOf(r.code.int, r.headers.getOrDefault("Retry-After"), r.body)
    except CatchableError as e:
      result = ApiResult(status: asUnavailable, message: "the core does not answer (" & e.msg & ")")
    finally:
      if c != nil: c.close()
  result.login = proc (user, password, client, code: string): ApiResult {.gcsafe.} =
    var body = %*{"user": user, "password": password}
    if code.len > 0: body["code"] = %code
    call(HttpPost, "/api/v1/login", "", $body, client)
  result.loginSecond = proc (ticket, code, assertion, client: string): ApiResult {.gcsafe.} =
    var body = %*{"ticket": ticket}
    if code.len > 0: body["code"] = %code
    if assertion.len > 0:
      try: body["assertion"] = parseJson(assertion)
      except JsonParsingError: body["assertion"] = newJObject()
    call(HttpPost, "/api/v1/login", "", $body, client)
  result.loginOptions = proc (): ApiResult {.gcsafe.} =
    call(HttpGet, "/api/v1/login/options", "", "")
  result.get = proc (token, pathAndQuery: string): ApiResult {.gcsafe.} =
    call(HttpGet, pathAndQuery, token, "")
  result.post = proc (token, path, body: string): ApiResult {.gcsafe.} =
    call(HttpPost, path, token, body)
  result.send = proc (meth, token, path, body: string): ApiResult {.gcsafe.} =
    case meth
    of "PUT": call(HttpPut, path, token, body)
    of "DELETE": call(HttpDelete, path, token, body)
    of "POST": call(HttpPost, path, token, body)
    else: call(HttpGet, path, token, "")
