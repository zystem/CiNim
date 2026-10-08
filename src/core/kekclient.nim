## A master key that lives on another machine (core/kekprovider.nim): a small service `kekd` next to a token (a SmartCard-HSM, docs/hardware-key.md), spoken to over
## HTTP(S). The core never holds the key; it sends a data key to be wrapped or a wrapped one to be opened, and the token does the private operation.
##
## The protocol (version 1), JSON:
##   GET  /v1/info                              -> {"key_id": "<fingerprint of the master key>", "version": 1}
##   POST /v1/wrap   {"plain": "<hex>", "aad": "<text>"}      -> {"wrapped": "<opaque text>"}
##   POST /v1/unwrap {"wrapped": "<text>", "aad": "<text>"}   -> {"plain": "<hex>"}
##   an error is {"error": "<code>"} with 409 (`wrong_key`: it was not wrapped by this key), 422 (`damaged`) - both final - or 423 (`locked`: the token wants
##   a PIN or is blocked), 429, 5xx - which may pass; a connection that fails or times out may pass too.
## The wrapped text is the service's own (an ECIES blob for a card); the core keeps it and gives it back. With `https://` the connection is mutual TLS: the core
## checks the service's certificate against `ca` and shows its own (`cert`, `key`); this needs a core built with -d:ssl (the image is).
import std/[json, httpclient, strutils, net]
import kekprovider

type
  KekdConfig* = object
    url*: string                     ## http://host:port or https://host:port
    ca*, cert*, key*: string         ## files of PEM, for https
    timeoutMs*: int

proc hexOf(b: seq[byte]): string =
  const digits = "0123456789abcdef"
  for x in b:
    result.add digits[int(x shr 4)]
    result.add digits[int(x and 15)]

proc bytesOfHex(s: string): tuple[ok: bool, bytes: seq[byte]] =
  if s.len mod 2 != 0: return
  var i = 0
  while i < s.len:
    let v = try: parseHexInt(s[i .. i + 1]) except ValueError: return
    result.bytes.add byte(v)
    i += 2
  result.ok = true

proc newClient(cfg: KekdConfig): HttpClient =
  let timeout = if cfg.timeoutMs > 0: cfg.timeoutMs else: 5000
  when defined(ssl):
    if cfg.url.startsWith("https://"):
      let ctx = newContext(verifyMode = CVerify_Peer, caFile = cfg.ca, certFile = cfg.cert, keyFile = cfg.key)
      return newHttpClient(timeout = timeout, sslContext = ctx)
  else:
    if cfg.url.startsWith("https://"): raise newException(ValueError, "https needs a core built with -d:ssl")
  newHttpClient(timeout = timeout)

proc call(cfg: KekdConfig; meth: HttpMethod; path: string; body: JsonNode = nil): tuple[code: int, body: JsonNode, error: string] =
  ## code 0: no answer at all
  var c: HttpClient
  try:
    c = newClient(cfg)
    c.headers = newHttpHeaders({"Content-Type": "application/json"})
    let r = c.request(cfg.url.strip(chars = {'/'}) & path, httpMethod = meth, body = (if body == nil: "" else: $body))
    let text = r.body
    result.code = r.code.int
    result.body = try: parseJson(text) except JsonParsingError: newJObject()
  except CatchableError as e:
    result.error = e.msg
  finally:
    if c != nil: c.close()

func failure(code: int; body: JsonNode; netError: string): tuple[retry: bool, error: string] =
  if code == 0: return (true, "the key service does not answer (" & netError & ")")
  let what = body{"error"}.getStr("error " & $code)
  # 409 and 422 are final; everything else (locked, throttled, a server error) may pass
  (code notin [409, 422], "the key service says " & what)

proc kekdInfo*(cfg: KekdConfig): tuple[ok, retry: bool, keyId, error: string] =
  let r = call(cfg, HttpGet, "/v1/info")
  if r.code != 200:
    let f = failure(r.code, r.body, r.error)
    return (false, f.retry, "", f.error)
  let id = r.body{"key_id"}.getStr
  if id.len == 0: return (false, false, "", "the key service did not say which key it holds")
  (true, false, id, "")

proc httpKek*(cfg: KekdConfig): tuple[ok, retry: bool, kek: KekProvider, error: string] =
  ## The provider. It asks the service which key it holds, once, now; if the service is down the answer is `retry` and the caller tries again later.
  let info = kekdInfo(cfg)
  if not info.ok: return (false, info.retry, KekProvider(), info.error)
  let c = cfg
  let kek = KekProvider(id: "kekd:" & info.keyId,
    wrap: proc (plain: seq[byte]; aad: string): WrapResult {.gcsafe.} =
      let r = call(c, HttpPost, "/v1/wrap", %*{"plain": hexOf(plain), "aad": aad})
      if r.code == 200 and r.body{"wrapped"}.getStr.len > 0: return (true, false, "", r.body["wrapped"].getStr)
      let f = failure(r.code, r.body, r.error)
      (false, f.retry, f.error, ""),
    unwrap: proc (wrapped: string; aad: string): UnwrapResult {.gcsafe.} =
      let r = call(c, HttpPost, "/v1/unwrap", %*{"wrapped": wrapped, "aad": aad})
      if r.code == 200:
        let h = bytesOfHex(r.body{"plain"}.getStr)
        if h.ok and h.bytes.len > 0: return (true, false, "", h.bytes)
        return refused("the key service answered with something that is not a key")
      let f = failure(r.code, r.body, r.error)
      (false, f.retry, f.error, @[]))
  (true, false, kek, "")
