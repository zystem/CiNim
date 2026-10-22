## A master key that lives on another machine (core/kekprovider.nim): a key service next to a token (a SmartCard-HSM, docs/hardware-key.md), spoken to over HTTP(S) in
## the **Transit API** of Vault and OpenBao. The core never holds the key; it sends a data key to be sealed or a sealed one to be opened, and the service (hsmgate, or a
## Vault/OpenBao Transit engine) does it. The service is a project of its own: github.com/zystem/hsmgate.
##
## What the core asks (JSON; `mount` is `transit` unless set, `name` is the key's name in the service):
##   GET  /v1/<mount>/keys/<name>                                  -> {"data": {"latest_version": 1, "keys": {"1": {"fingerprint": "..."}}, ...}}   (once, when the provider is made)
##   PUT  /v1/<mount>/encrypt/<name> {"plaintext": b64, "context": b64}   -> {"data": {"ciphertext": "vault:v1:..."}}
##   PUT  /v1/<mount>/decrypt/<name> {"ciphertext": "...", "context": b64} -> {"data": {"plaintext": b64}}
## The `context` is the additional data of the data key (`cinim/dek/v1|<tenant>`): the service binds the ciphertext to it, and may allow only contexts of that form.
## A failure is `{"errors": ["..."]}`. Whether it may pass is told by the header `X-Hsmgate-Retryable` (hsmgate); without it: 429, 5xx and no answer at all may pass, other statuses
## (a wrong key or context is 400, a key not granted 403) are final. The sealed text is the service's own; the core keeps it and gives it back.
## With `https://` the connection is mutual TLS: the core checks the service's certificate against `ca` and shows its own (`cert`, `key`); this needs a core built with -d:ssl
## (the image is). Through a proxy (`proxy`, CONNECT) the TLS still runs from the core to the service; the proxy sees only the address and the bytes (needs Nim >= 2.2.8: the httpclient of 2.2.6 writes a wrong request line inside the tunnel, nim-lang/Nim#25319). The service ignores the token a Vault client sends; a Vault or an OpenBao wants one (`tokenFile`).
import std/[json, httpclient, strutils, net, base64]
import kekprovider

static:
  # the request line of an https request through an HTTP proxy is wrong in 2.2.6 (the server answers 400); keep it out of the build
  doAssert NimVersion != "2.2.6", "Nim 2.2.6 cannot be used: its httpclient is wrong for https through a proxy (nim-lang/Nim#25319); use >= 2.2.8"

type
  TransitConfig* = object
    url*: string                     ## http://host:port or https://host:port
    mount*: string                   ## the mount of the Transit engine ("transit" when empty)
    keyName*: string                 ## the key in the service
    ca*, cert*, key*: string         ## files of PEM, for https
    tokenFile*: string               ## a file with a Vault token, sent as X-Vault-Token (empty: none)
    proxy*: string                   ## an HTTP proxy that takes CONNECT, http://host:port (empty: none); the TLS and the certificates are still the core's and the service's, end to end
    timeoutMs*: int

proc newClient(cfg: TransitConfig): HttpClient =
  let timeout = if cfg.timeoutMs > 0: cfg.timeoutMs else: 5000
  let proxy = if cfg.proxy.len > 0: newProxy(cfg.proxy) else: nil
  when defined(ssl):
    if cfg.url.startsWith("https://"):
      let ctx = newContext(verifyMode = CVerify_Peer, caFile = cfg.ca, certFile = cfg.cert, keyFile = cfg.key)
      return newHttpClient(timeout = timeout, sslContext = ctx, proxy = proxy)
  else:
    if cfg.url.startsWith("https://"): raise newException(ValueError, "https needs a core built with -d:ssl")
  newHttpClient(timeout = timeout, proxy = proxy)

type Answer = tuple[code: int, body: JsonNode, retryHeader, error, raw: string]       ## code 0: no answer at all; raw: the start of the body as it came

func path(cfg: TransitConfig; op: string): string =
  "/v1/" & (if cfg.mount.len > 0: cfg.mount else: "transit") & "/" & op & "/" & cfg.keyName

proc call(cfg: TransitConfig; meth: HttpMethod; path: string; body: JsonNode = nil): Answer =
  var c: HttpClient
  try:
    c = newClient(cfg)
    c.headers = newHttpHeaders({"Content-Type": "application/json"})
    if cfg.tokenFile.len > 0:
      try: c.headers["X-Vault-Token"] = readFile(cfg.tokenFile).strip
      except IOError: return (0, nil, "", "cannot read the token file " & cfg.tokenFile, "")
    let r = c.request(cfg.url.strip(chars = {'/'}) & path, httpMethod = meth, body = (if body == nil: "" else: $body))
    result.code = r.code.int
    result.raw = r.body[0 ..< min(r.body.len, 400)]
    result.body = try: parseJson(r.body) except JsonParsingError: newJObject()
    result.retryHeader = r.headers.getOrDefault("X-Hsmgate-Retryable")
  except CatchableError as e:
    result.error = e.msg
  finally:
    if c != nil: c.close()

func failure(a: Answer): tuple[retry: bool, error: string] =
  if a.code == 0: return (true, "the key service does not answer (" & a.error & ")")
  var what = "error " & $a.code
  let errors = a.body{"errors"}
  if errors != nil and errors.kind == JArray and errors.len > 0: what = errors[0].getStr(what)
  else:
    # not the service's own words (a proxy's page, a gateway): say what it says, as text, so that a person can tell who answered
    var text = ""
    var inTag = false
    for c in a.raw:
      if c == '<': inTag = true; text.add ' '
      elif c == '>': inTag = false
      elif not inTag: text.add (if c in {'\n', '\r', '\t'}: ' ' else: c)
    text = text.splitWhitespace.join(" ")
    if text.len > 0: what &= ": " & text[0 ..< min(text.len, 160)]
  # the service says whether it may pass; one that does not (Vault, OpenBao): a throttle and a server error may, the rest is final
  let retry = case a.retryHeader.toLowerAscii
    of "true": true
    of "false": false
    else: a.code == 429 or a.code >= 500
  (retry, "the key service says " & what)

proc transitInfo*(cfg: TransitConfig): tuple[ok, retry: bool, keyId, error: string] =
  ## the key's name, with the fingerprint of its latest version when the service gives one (hsmgate does)
  let r = call(cfg, HttpGet, path(cfg, "keys"))
  if r.code != 200:
    let f = failure(r)
    return (false, f.retry, "", f.error)
  let d = r.body{"data"}
  if d == nil or d.kind != JObject or d{"latest_version"}.getInt(0) < 1: return (false, false, "", "the key service did not describe the key " & cfg.keyName)
  let fp = d{"keys"}{$d{"latest_version"}.getInt}{"fingerprint"}.getStr
  (true, false, "transit:" & cfg.keyName & (if fp.len > 0: "@" & fp[0 ..< min(fp.len, 16)] else: ""), "")

proc httpKek*(cfg: TransitConfig): tuple[ok, retry: bool, kek: KekProvider, error: string] =
  ## The provider. It asks the service about the key, once, now; if the service is down the answer is `retry` and the caller tries again later.
  let info = transitInfo(cfg)
  if not info.ok: return (false, info.retry, KekProvider(), info.error)
  let c = cfg
  let kek = KekProvider(id: info.keyId,
    wrap: proc (plain: seq[byte]; aad: string): WrapResult {.gcsafe.} =
      var raw = newString(plain.len)
      if plain.len > 0: copyMem(addr raw[0], unsafeAddr plain[0], plain.len)
      let r = call(c, HttpPut, path(c, "encrypt"), %*{"plaintext": encode(raw), "context": encode(aad)})
      let text = r.body{"data"}{"ciphertext"}.getStr
      if r.code == 200 and text.len > 0: return (true, false, "", text)
      let f = failure(r)
      (false, f.retry, f.error, ""),
    unwrap: proc (wrapped: string; aad: string): UnwrapResult {.gcsafe.} =
      let r = call(c, HttpPut, path(c, "decrypt"), %*{"ciphertext": wrapped, "context": encode(aad)})
      if r.code == 200:
        var plain = ""
        try: plain = decode(r.body{"data"}{"plaintext"}.getStr)
        except ValueError: discard
        if plain.len > 0: return (true, false, "", @(plain.toOpenArrayByte(0, plain.high)))
        return refused("the key service answered with something that is not a key")
      let f = failure(r)
      (false, f.retry, f.error, @[]),
    rewrap: proc (wrapped: string; aad: string): WrapResult {.gcsafe.} =
      let r = call(c, HttpPut, path(c, "rewrap"), %*{"ciphertext": wrapped, "context": encode(aad)})
      let text = r.body{"data"}{"ciphertext"}.getStr
      if r.code == 200 and text.len > 0: return (true, false, "", text)
      let f = failure(r)
      (false, f.retry, f.error, ""))
  (true, false, kek, "")
