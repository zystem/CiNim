## What the UI knows of the core: three calls, and what they say in the terms of a page (docs/ui.md). `login` is POST /api/v1/login; `get` is a GET of any path of the API with the token of the user; `post` is a POST of an action.
## They are closures so that the tests give the UI a core that says what the test wants (tests/unit/tui.nim); `httpCoreApi` is the real one, over std/httpclient (plain HTTP inside the cluster).
import std/[json, httpclient, strutils]

type
  ApiStatus* = enum
    asOk, asUnauthorized, asForbidden, asNotFound, asUnavailable, asRefused

  ApiResult* = object
    status*: ApiStatus
    code*: int                       ## the HTTP status of the core's answer (0: there was none)
    body*: JsonNode                  ## the JSON of an answer that was asOk
    message*: string                 ## what the core said (its `code` or `detail`) or why there was no answer; shown to a person, so plain words

  CoreApi* = object
    login*: proc (user, password: string): ApiResult {.gcsafe.}
    get*: proc (token, pathAndQuery: string): ApiResult {.gcsafe.}
    post*: proc (token, path, body: string): ApiResult {.gcsafe.}      ## a POST of an action (abort, retry) with the token of the user

proc problemText(body: string): string =
  ## the words of a problem+json answer of the core: `detail` first, then `code`
  try:
    let j = parseJson(body)
    if j.kind == JObject:
      let d = j{"detail"}.getStr
      return if d.len > 0: d else: j{"code"}.getStr
  except JsonParsingError:
    discard

proc resultOf(code: int; retryAfter, body: string): ApiResult =
  result.code = code
  case code
  of 200, 201:
    result.status = asOk
    result.body = try: parseJson(body) except JsonParsingError: newJObject()
  of 401: (result.status = asUnauthorized; result.message = problemText(body))
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
  proc call(meth: HttpMethod; path, token, body: string): ApiResult =
    var c: HttpClient
    try:
      c = newHttpClient(timeout = timeoutMs)
      c.headers = newHttpHeaders({"Accept": "application/json", "Content-Type": "application/json"})
      if token.len > 0: c.headers["Authorization"] = "Bearer " & token
      let r = c.request(base & path, httpMethod = meth, body = body)
      result = resultOf(r.code.int, r.headers.getOrDefault("Retry-After"), r.body)
    except CatchableError as e:
      result = ApiResult(status: asUnavailable, message: "the core does not answer (" & e.msg & ")")
    finally:
      if c != nil: c.close()
  result.login = proc (user, password: string): ApiResult {.gcsafe.} =
    call(HttpPost, "/api/v1/login", "", $(%*{"user": user, "password": password}))
  result.get = proc (token, pathAndQuery: string): ApiResult {.gcsafe.} =
    call(HttpGet, pathAndQuery, token, "")
  result.post = proc (token, path, body: string): ApiResult {.gcsafe.} =
    call(HttpPost, path, token, body)
