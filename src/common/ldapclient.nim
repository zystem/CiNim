## A small LDAP client (RFC 4511): a simple bind and a search, over TCP, with TLS from the start (`ldaps://`) or after StartTLS (RFC 4511 4.14). Nothing else: no SASL, no writes,
## no paging, no referrals. It is written here because the only Nim package for LDAP (nimldap) is a binding to the C library libldap, which the static images of the core do not carry,
## and what the core needs from a directory is two requests: is this the password of that person, and which groups is that person in.
##
## The messages are BER (ITU X.690) with the definite lengths LDAP uses. A connection is used by one thread. Every wait has a deadline (`timeoutMs`). The words of a filter that a person
## typed are escaped by `escapeFilterValue` (RFC 4515) before they go in a filter.
##
## An LDAP bind with a name and an EMPTY password is, by the protocol, an anonymous bind that succeeds (RFC 4513 5.1.2): `bindSimple` refuses an empty password, so that "the password is
## right" can never mean "the server let anyone in".
import std/[net, strutils, os, hashes, nativesockets]
when defined(ssl):
  import std/openssl

type
  LdapError* = object of CatchableError
  LdapAuthError* = object of LdapError                 ## the server refused the credentials (resultCode 49) - the one error that is an answer about the person, not about the directory
  LdapResultError* = object of LdapError               ## the server answered with a result code that is not success; 32 is "no such object"
    code*: int

  LdapSettings* = object
    url*: string                                       ## ldap://host[:port] or ldaps://host[:port]
    startTls*: bool                                    ## upgrade an ldap:// connection with StartTLS before anything is sent
    caPem*: string                                     ## the CA that signed the server's certificate, or the server's own certificate when it is self-signed; "" = the system's roots
    insecureTls*: bool                                 ## do not check the server's certificate at all (anyone on the network can then pose as the directory); for a directory that has nothing better
    timeoutMs*: int                                    ## for the connection and for each answer (default 10 000)

  LdapEntry* = object
    dn*: string
    attrs*: seq[(string, seq[string])]

  LdapConn* = ref object
    sock: Socket
    msgId: int
    timeoutMs: int

  Scope* = enum
    scBase = 0, scOne = 1, scSub = 2

const
  maxMessage = 8 * 1024 * 1024
  startTlsOid = "1.3.6.1.4.1.1466.20037"
  # BER tags
  tInt = 0x02'u8
  tOctets = 0x04'u8
  tBool = 0x01'u8
  tEnum = 0x0a'u8
  tSeq = 0x30'u8
  tSet = 0x31'u8
  tBindReq = 0x60'u8
  tBindResp = 0x61'u8
  tUnbindReq = 0x42'u8
  tSearchReq = 0x63'u8
  tSearchEntry = 0x64'u8
  tSearchDone = 0x65'u8
  tSearchRef = 0x73'u8
  tExtReq = 0x77'u8
  tExtResp = 0x78'u8

# ------------------------------------------------------------------ BER

func berLen(n: int): string =
  if n < 0x80: return $char(n)
  var bytes: string
  var v = n
  while v > 0:
    bytes = $char(v and 0xff) & bytes
    v = v shr 8
  $char(0x80 or bytes.len) & bytes

func tlv*(tag: uint8; value: string): string = $char(tag) & berLen(value.len) & value

func berInt*(v: int): string =
  ## the shortest two's complement form
  var bytes: seq[char]
  var x = v
  while true:
    bytes.add char(x and 0xff)
    x = x shr 8                                         # arithmetic shift: the sign is kept
    if (x == 0 and (ord(bytes[^1]) and 0x80) == 0) or (x == -1 and (ord(bytes[^1]) and 0x80) != 0): break
  var s: string
  for i in countdown(bytes.high, 0): s.add bytes[i]
  tlv(tInt, s)

func berEnum(v: int): string = tlv(tEnum, berInt(v)[2 .. ^1])
func berOctets(s: string): string = tlv(tOctets, s)
func berBool(b: bool): string = tlv(tBool, if b: "\xff" else: "\x00")

type Reader = object
  data: string
  pos: int

func atEnd(r: Reader): bool = r.pos >= r.data.len

proc readTlv(r: var Reader): tuple[tag: uint8, value: string] =
  if r.pos + 2 > r.data.len: raise newException(LdapError, "a short LDAP message")
  result.tag = uint8(r.data[r.pos])
  inc r.pos
  var n = ord(r.data[r.pos])
  inc r.pos
  if n >= 0x80:
    let k = n and 0x7f
    if k == 0 or k > 4 or r.pos + k > r.data.len: raise newException(LdapError, "a bad LDAP length")
    n = 0
    for i in 0 ..< k:
      n = (n shl 8) or ord(r.data[r.pos])
      inc r.pos
  if n < 0 or r.pos + n > r.data.len: raise newException(LdapError, "an LDAP length beyond the message")
  result.value = r.data[r.pos ..< r.pos + n]
  r.pos += n

func intOf(value: string): int =
  if value.len == 0 or value.len > 8: raise newException(LdapError, "a bad LDAP integer")
  result = if (ord(value[0]) and 0x80) != 0: -1 else: 0
  for ch in value: result = (result shl 8) or ord(ch)

proc expect(r: var Reader; tag: uint8): string =
  let t = r.readTlv
  if t.tag != tag: raise newException(LdapError, "an LDAP message of an unexpected shape (tag " & toHex(int(t.tag), 2) & ", wanted " & toHex(int(tag), 2) & ")")
  t.value

# ------------------------------------------------------------------ filters (RFC 4515)

func escapeFilterValue*(s: string): string =
  ## what goes into an equality or substring of a filter: `\`, `*`, `(`, `)` and NUL as `\hh`
  for ch in s:
    case ch
    of '\\', '*', '(', ')', '\0': result.add "\\" & toHex(ord(ch), 2).toLowerAscii
    else: result.add ch

proc unescapeValue(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\\':
      if i + 2 > s.high: raise newException(LdapError, "a bad escape in the filter")
      try: result.add char(parseHexInt(s[i + 1 .. i + 2]))
      except ValueError: raise newException(LdapError, "a bad escape in the filter")
      i += 3
    else:
      result.add s[i]
      inc i

proc encodeFilter(f: string; pos: var int): string

proc encodeFilterList(f: string; pos: var int): string =
  while pos < f.len and f[pos] == '(': result.add encodeFilter(f, pos)
  if result.len == 0: raise newException(LdapError, "an empty list in the filter")

proc encodeFilter(f: string; pos: var int): string =
  if pos >= f.len or f[pos] != '(': raise newException(LdapError, "the filter does not start with (")
  inc pos
  if pos >= f.len: raise newException(LdapError, "the filter ends too soon")
  case f[pos]
  of '&':
    inc pos
    result = tlv(0xa0, encodeFilterList(f, pos))
  of '|':
    inc pos
    result = tlv(0xa1, encodeFilterList(f, pos))
  of '!':
    inc pos
    result = tlv(0xa2, encodeFilter(f, pos))
  else:
    let eq = f.find('=', pos)
    let close = f.find(')', pos)
    if eq < 0 or close < 0 or eq > close: raise newException(LdapError, "an item of the filter has no =")
    let attr = f[pos ..< eq]
    if attr.len == 0 or attr.contains({'(', ')', '*', '\\'}) or attr[^1] in {'~', '>', '<', ':'}:
      raise newException(LdapError, "this kind of filter item is not supported: " & attr & "=")
    var value = f[eq + 1 ..< close]
    pos = close
    if value == "*":
      result = tlv(0x87, attr)
    elif value.contains('*'):
      # substrings: initial*any*...*final, the parts between the stars
      let parts = value.split('*')
      var subs: string
      for i, p in parts:
        if p.len == 0: continue
        let tag = if i == 0: 0x80'u8 elif i == parts.high: 0x82'u8 else: 0x81'u8
        subs.add tlv(tag, unescapeValue(p))
      result = tlv(0xa4, berOctets(attr) & tlv(tSeq, subs))
    else:
      result = tlv(0xa3, berOctets(attr) & berOctets(unescapeValue(value)))
  if pos >= f.len or f[pos] != ')': raise newException(LdapError, "the filter lacks a )")
  inc pos

proc encodeFilter*(f: string): string =
  ## the BER of a filter in the string form of RFC 4515: (&...), (|...), (!...), (attr=value), (attr=*), (attr=a*b*c)
  var pos = 0
  result = encodeFilter(f, pos)
  if pos != f.len: raise newException(LdapError, "something follows the filter")

# ------------------------------------------------------------------ the messages

func bindRequest*(id: int; dn, password: string): string =
  tlv(tSeq, berInt(id) & tlv(tBindReq, berInt(3) & berOctets(dn) & tlv(0x80, password)))

func unbindRequest*(id: int): string = tlv(tSeq, berInt(id) & tlv(tUnbindReq, ""))

func startTlsRequest*(id: int): string = tlv(tSeq, berInt(id) & tlv(tExtReq, tlv(0x80, startTlsOid)))

proc searchRequest*(id: int; base: string; scope: Scope; filter: string; attrs: seq[string]; sizeLimit, timeLimit: int): string =
  var attrList: string
  for a in attrs: attrList.add berOctets(a)
  tlv(tSeq, berInt(id) & tlv(tSearchReq, berOctets(base) & berEnum(ord(scope)) & berEnum(0) & berInt(sizeLimit) & berInt(timeLimit) & berBool(false) &
    encodeFilter(filter) & tlv(tSeq, attrList)))

type Answer* = object
  op*: uint8
  body*: string
  id*: int

proc parseMessage*(raw: string): Answer =
  ## LDAPMessage ::= SEQUENCE { messageID INTEGER, protocolOp, controls [0] OPTIONAL }
  var outer = Reader(data: raw)
  let seqBody = outer.expect(tSeq)
  var r = Reader(data: seqBody)
  result.id = intOf(r.expect(tInt))
  let op = r.readTlv
  result.op = op.tag
  result.body = op.value

type LdapResult* = object
  code*: int
  matchedDn*, message*: string

proc parseResult*(body: string): LdapResult =
  ## LDAPResult ::= SEQUENCE { resultCode ENUMERATED, matchedDN, diagnosticMessage, referral [3] OPTIONAL } (the fields of the op itself)
  var r = Reader(data: body)
  result.code = intOf(r.expect(tEnum))
  result.matchedDn = r.expect(tOctets)
  result.message = r.expect(tOctets)

proc parseEntry*(body: string): LdapEntry =
  var r = Reader(data: body)
  result.dn = r.expect(tOctets)
  var attrs = Reader(data: r.expect(tSeq))
  while not attrs.atEnd:
    var one = Reader(data: attrs.expect(tSeq))
    let name = one.expect(tOctets)
    var vals = Reader(data: one.expect(tSet))
    var values: seq[string]
    while not vals.atEnd: values.add vals.expect(tOctets)
    result.attrs.add (name, values)

func values*(e: LdapEntry; attr: string): seq[string] =
  ## the values of an attribute, the name compared without regard to case
  for (n, v) in e.attrs:
    if cmpIgnoreCase(n, attr) == 0: result.add v

func first*(e: LdapEntry; attr: string): string =
  let v = e.values(attr)
  if v.len > 0: v[0] else: ""

# ------------------------------------------------------------------ the connection

proc parseUrl(url: string): tuple[tls: bool, host: string, port: int] =
  var rest: string
  if url.startsWith("ldaps://"):
    result.tls = true
    result.port = 636
    rest = url["ldaps://".len .. ^1]
  elif url.startsWith("ldap://"):
    result.port = 389
    rest = url["ldap://".len .. ^1]
  else:
    raise newException(LdapError, "the address of a directory starts with ldap:// or ldaps://")
  rest = rest.strip(chars = {'/'})
  if rest.len == 0 or rest.contains({'/', '?', ' '}): raise newException(LdapError, "the address of a directory is ldap[s]://host[:port]")
  let colon = rest.rfind(':')
  if colon >= 0:
    try: result.port = parseInt(rest[colon + 1 .. ^1])
    except ValueError: raise newException(LdapError, "the port of the directory is not a number")
    if result.port < 1 or result.port > 65535: raise newException(LdapError, "the port of the directory is not a port")
    result.host = rest[0 ..< colon]
  else:
    result.host = rest

proc checkLdapUrl*(url: string) =
  ## raises LdapError if this is not an address of a directory
  discard parseUrl(url)

when defined(ssl):
  proc tlsContext(caPem: string; insecure: bool): SslContext =
    if insecure: return newContext(verifyMode = CVerifyNone)
    if caPem.len == 0: return newContext(verifyMode = CVerifyPeer)
    # the CA is text in the settings; the library wants a file: kept under a name made of the text, so that the same CA is one file
    let dir = getTempDir() / "cinim-ldap-ca"
    createDir(dir)
    let path = dir / ("ca-" & toHex(hash(caPem), 8) & ".pem")
    if not fileExists(path):
      let tmp = path & "." & $getCurrentProcessId()
      writeFile(tmp, caPem)
      moveFile(tmp, path)
    newContext(verifyMode = CVerifyPeer, caFile = path)

proc sendAll(c: LdapConn; data: string) =
  try: c.sock.send(data)
  except OSError as e: raise newException(LdapError, "sending to the directory failed: " & e.msg)

proc readExact(c: LdapConn; n: int): string =
  result = newString(n)
  var got = 0
  while got < n:
    var buf = newString(n - got)
    let k = try: c.sock.recv(addr buf[0], n - got, c.timeoutMs)
            except OSError as e: raise newException(LdapError, "the directory did not answer: " & e.msg)
            except TimeoutError: raise newException(LdapError, "the directory did not answer in time")
    if k <= 0: raise newException(LdapError, "the directory closed the connection")
    copyMem(addr result[got], addr buf[0], k)
    got += k

proc readMessage(c: LdapConn): string =
  ## one whole LDAPMessage: its tag and length first, then the rest
  let head = c.readExact(2)
  var raw = head
  var n = ord(head[1])
  if n >= 0x80:
    let k = n and 0x7f
    if k == 0 or k > 4: raise newException(LdapError, "a bad LDAP length")
    let lens = c.readExact(k)
    raw.add lens
    n = 0
    for ch in lens: n = (n shl 8) or ord(ch)
  if n > maxMessage: raise newException(LdapError, "an LDAP message of " & $n & " bytes is more than the " & $maxMessage & " this client takes")
  raw.add c.readExact(n)
  raw

proc nextId(c: LdapConn): int =
  inc c.msgId
  c.msgId

proc openLdap*(s: LdapSettings): LdapConn =
  ## connects (and, for ldaps:// or startTls, secures the connection and checks the server's certificate against the CA and the host name in the address)
  let u = parseUrl(s.url)
  let timeout = if s.timeoutMs > 0: s.timeoutMs else: 10_000
  var sock = newSocket()
  try:
    sock.connect(u.host, Port(u.port), timeout)
  except CatchableError as e:
    sock.close()
    raise newException(LdapError, "cannot connect to the directory " & u.host & ":" & $u.port & ": " & e.msg)
  result = LdapConn(sock: sock, timeoutMs: timeout)
  try:
    if u.tls:
      when defined(ssl):
        let ctx = tlsContext(s.caPem, s.insecureTls)
        wrapConnectedSocket(ctx, sock, handshakeAsClient, (if s.insecureTls: "" else: u.host))       # no name given, no name checked (the library checks it whenever it has one)
      else:
        raise newException(LdapError, "ldaps:// needs a core built with TLS (-d:ssl)")
    elif s.startTls:
      when defined(ssl):
        let id = result.nextId
        result.sendAll(startTlsRequest(id))
        let a = parseMessage(result.readMessage())
        if a.op != tExtResp: raise newException(LdapError, "the directory did not answer StartTLS as it should")
        let res = parseResult(a.body)
        if res.code != 0: raise newException(LdapError, "the directory refused StartTLS (" & $res.code & " " & res.message & ")")
        let ctx = tlsContext(s.caPem, s.insecureTls)
        wrapConnectedSocket(ctx, sock, handshakeAsClient, (if s.insecureTls: "" else: u.host))       # no name given, no name checked (the library checks it whenever it has one)
      else:
        raise newException(LdapError, "StartTLS needs a core built with TLS (-d:ssl)")
  except CatchableError as e:
    sock.close()
    if e of LdapError: raise
    raise newException(LdapError, "the TLS connection to the directory failed: " & e.msg)

proc close*(c: LdapConn) =
  if c == nil or c.sock == nil: return
  try:
    c.sock.send(unbindRequest(c.nextId))
  except CatchableError: discard
  try: c.sock.close()
  except CatchableError: discard
  c.sock = nil

proc bindSimple*(c: LdapConn; dn, password: string) =
  ## a bind with a name and a password. Raises LdapAuthError when the server says the credentials are wrong, LdapError for anything else; an empty password is refused here.
  if password.len == 0: raise newException(LdapAuthError, "an empty password is not a password")
  if dn.len == 0: raise newException(LdapAuthError, "an empty name cannot bind")
  let id = c.nextId
  c.sendAll(bindRequest(id, dn, password))
  while true:
    let a = parseMessage(c.readMessage())
    if a.id != id: continue
    if a.op != tBindResp: raise newException(LdapError, "the directory did not answer the bind as it should")
    let res = parseResult(a.body)
    case res.code
    of 0: return
    of 49, 48: raise newException(LdapAuthError, "the directory refused the credentials")
    else: raise newException(LdapError, "the bind failed (" & $res.code & " " & res.message & ")")

proc search*(c: LdapConn; base: string; scope: Scope; filter: string; attrs: seq[string] = @[]; sizeLimit = 0; timeLimit = 0): seq[LdapEntry] =
  ## the entries that match; raises LdapError for a result other than success (a size limit that the server applied is an error: a partial list of members would be a wrong one)
  let id = c.nextId
  c.sendAll(searchRequest(id, base, scope, filter, attrs, sizeLimit, timeLimit))
  while true:
    let a = parseMessage(c.readMessage())
    if a.id != id: continue
    case a.op
    of tSearchEntry: result.add parseEntry(a.body)
    of tSearchRef: discard
    of tSearchDone:
      let res = parseResult(a.body)
      if res.code != 0:
        var e = newException(LdapResultError, "the search failed (" & $res.code & " " & res.message & ")")
        e.code = res.code
        raise e
      return
    else: raise newException(LdapError, "the directory answered the search with something else")
