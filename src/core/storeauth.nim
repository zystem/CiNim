## The tokens that the core's calls to an HTTP store node carry (docs/store.md, D-57): a store node is Caddy with the WebDAV module (docs/store.md "The node"); it keeps no secret
## and no list of users. Every request carries `Authorization: Bearer v1.<expires>.<mac>`, and Caddy's `forward_auth` asks the core `GET /api/v1/internal/store-auth?node=<id>`
## before it lets the request in; the core checks the token with the secret of the store (the token of the settings), which it alone has.
##
## The MAC is HMAC-SHA256 under that secret of the node's id, the method, the **decoded path** and the time the token stops being good, so a token made for one request is no
## good for another path, another method, another node, or after `tokenLifetime` seconds: a node that is read or bent cannot do more with what it sees than repeat that one request
## to itself, for a minute or two. The path is decoded on both sides, so how it was written (`%41` or `A`) and what Caddy makes of it do not matter; the query is not signed.
import std/[strutils, uri]
import crunchy

const
  tokenLifetime* = 120        ## seconds a token is good for
  clockSkew* = 30             ## seconds a token may be from the future (the clocks of the core and of a node are not the same)

func hexOf(a: array[32, uint8]): string =
  const digits = "0123456789abcdef"
  for b in a:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

func samePath(rawPath: string): string =
  ## the path of a request line as the bytes it stands for, without the query
  let q = rawPath.find('?')
  decodeUrl(if q >= 0: rawPath[0 ..< q] else: rawPath, decodePlus = false)

proc macOf(secret, node, meth, path: string; expires: int64): string =
  hexOf(hmacSha256(secret, "cinim/store/v1|" & $node.len & "|" & node & "|" & meth.toUpperAscii & "|" & $path.len & "|" & path & "|" & $expires))

func equalConstTime(a, b: string): bool =
  var diff = a.len xor b.len
  for i in 0 ..< min(a.len, b.len): diff = diff or (ord(a[i]) xor ord(b[i]))
  diff == 0

proc signRequest*(secret, node, meth, rawPath: string; now: int64): string =
  ## the value of the Authorization header (without `Bearer `) for one request to `node`
  let expires = now + tokenLifetime
  "v1." & $expires & "." & macOf(secret, node, meth, samePath(rawPath), expires)

proc verifyRequest*(secret, node, meth, rawUri, token: string; now: int64): bool =
  ## `rawUri` is what the node says the request was for (`X-Forwarded-Uri` of Caddy), `meth` the method (`X-Forwarded-Method`)
  if secret.len == 0 or node.len == 0: return false
  let parts = token.split('.')
  if parts.len != 3 or parts[0] != "v1" or parts[1].len == 0 or parts[1].len > 12: return false
  var expires: int64
  try: expires = parseBiggestInt(parts[1])
  except ValueError: return false
  if expires < now or expires > now + tokenLifetime + clockSkew: return false
  equalConstTime(parts[2], macOf(secret, node, meth, samePath(rawUri), expires))

# ------------------------------------------------------------------ the answer to the node's forward_auth

const authPath* = "/api/v1/internal/store-auth"      ## what a node's `forward_auth` asks (docs/store.md): `GET <authPath>?node=<id of the node>`

func headerOf*(rawRequest, name: string): string =
  ## the value of a header of a raw HTTP request, "" when there is none; only the header part is looked at, the name is case-insensitive
  let headEnd = rawRequest.find("\r\n\r\n")
  let head = if headEnd >= 0: rawRequest[0 ..< headEnd] else: rawRequest
  let want = name.toLowerAscii
  for line in head.split("\r\n"):
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].strip.toLowerAscii == want: return line[colon + 1 .. ^1].strip

func queryParam(uri, name: string): string =
  let q = uri.find('?')
  if q < 0: return ""
  for pair in uri[q + 1 .. ^1].split('&'):
    let eq = pair.find('=')
    if eq > 0 and pair[0 ..< eq] == name: return decodeUrl(pair[eq + 1 .. ^1], decodePlus = false)

proc storeAuthOk*(rawRequest, uri, secret: string; now: int64): bool =
  ## (answer with a body that is not empty - "ok", "no": GuildenStern puts a stray CRLF after an empty one, and Caddy logs an "unsolicited response" for every request)
  ## Caddy's `forward_auth` sent the request to `uri` (with `?node=<id>`), carrying the original Authorization header and, as `X-Forwarded-Method` and `X-Forwarded-Uri`, what the
  ## original request was for
  let auth = rawRequest.headerOf("authorization")
  if auth.len < 8 or auth[0 ..< 7].toLowerAscii != "bearer ": return false
  verifyRequest(secret, uri.queryParam("node"), rawRequest.headerOf("x-forwarded-method"), rawRequest.headerOf("x-forwarded-uri"), auth[7 .. ^1].strip, now)
