## D-87: the LDAP messages (BER, RFC 4511) and the filters (RFC 4515) of src/common/ldapclient.nim, byte for byte. Pure: no server.
import std/[unittest, strutils]
import ../../src/common/ldapclient

func hex(s: string): string =
  for ch in s: result.add toHex(ord(ch), 2).toLowerAscii
func enumOf(v: int): string = tlv(0x0a, berInt(v)[2 .. ^1])
func bytes(h: string): string =
  var i = 0
  let t = h.replace(" ", "")
  while i < t.len:
    result.add char(parseHexInt(t[i .. i + 1]))
    i += 2

suite "D-87 BER integers and lengths":
  test "an integer is the shortest two's complement":
    check hex(berInt(0)) == "020100" and hex(berInt(1)) == "020101" and hex(berInt(127)) == "02017f"
    check hex(berInt(128)) == "02020080" and hex(berInt(255)) == "020200ff" and hex(berInt(256)) == "02020100"
    check hex(berInt(-1)) == "0201ff" and hex(berInt(-128)) == "020180" and hex(berInt(-129)) == "0202ff7f"
    check hex(berInt(65535)) == "020300ffff"
  test "a length under 128 is one byte, a longer one says how many bytes it takes":
    check hex(tlv(0x04, "")) == "0400" and hex(tlv(0x04, "a")) == "040161"
    check hex(tlv(0x04, 'x'.repeat(127)))[0 .. 3] == "047f" and hex(tlv(0x04, 'x'.repeat(128)))[0 .. 5] == "048180"
    check hex(tlv(0x04, 'x'.repeat(300)))[0 .. 7] == "0482012c"

suite "D-87 the requests":
  test "a bind: the message id, version 3, the name, a simple password":
    check hex(bindRequest(1, "cn=admin", "pw")) == "301602010160110201030408" & hex("cn=admin") & "8002" & hex("pw")
  test "an unbind, and StartTLS with its object identifier":
    check hex(unbindRequest(7)) == "300502010742" & "00"
    check hex(startTlsRequest(2)) == "301d02010277" & "18" & "80" & "16" & hex("1.3.6.1.4.1.1466.20037")
  test "a search: base, scope, no aliases, limits, not types only, the filter, the attributes":
    let m = searchRequest(2, "dc=x", scSub, "(uid=ann)", @["cn", "mail"], 5, 10)
    check m.startsWith("\x30") and hex(m).contains(hex("dc=x") & "0a0102" & "0a0100" & "020105" & "02010a" & "010100" & "a30a0403" & hex("uid") & "0403" & hex("ann") & "300a" & "0402" & hex("cn") & "0404" & hex("mail"))

suite "D-87 filters":
  test "equality, presence, and, or, not":
    check hex(encodeFilter("(uid=ann)")) == "a30a0403" & hex("uid") & "0403" & hex("ann")
    check hex(encodeFilter("(uid=*)")) == "8703" & hex("uid")
    check hex(encodeFilter("(&(a=b)(c=d))")) == "a0" & "10" & "a306" & "040161" & "040162" & "a306" & "040163" & "040164"
    check hex(encodeFilter("(|(a=b)(c=d))"))[0 .. 1] == "a1"
    check hex(encodeFilter("(!(a=b))")) == "a2" & "08" & "a306" & "040161" & "040162"
  test "substrings: the first part, the middle ones, the last":
    check hex(encodeFilter("(cn=a*b*c)")) == "a4" & "0f" & "0402" & hex("cn") & "3009" & "8001" & hex("a") & "8101" & hex("b") & "8201" & hex("c")
    check hex(encodeFilter("(cn=*dev*)")) == "a4" & "0b" & "0402" & hex("cn") & "3005" & "8103" & hex("dev")
    check hex(encodeFilter("(cn=*Dev)")).contains("8203" & hex("Dev")) and hex(encodeFilter("(cn=Dev*)")).contains("8003" & hex("Dev"))
  test "an escape in a value is one byte":
    check hex(encodeFilter("(cn=a\\2ab)")) == "a3" & "09" & "0402" & hex("cn") & "0403" & hex("a*b")
    check hex(encodeFilter("(cn=\\28x\\29)")) == "a3" & "09" & "0402" & hex("cn") & "0403" & hex("(x)")
  test "what a person types is made safe before it goes in a filter":
    check escapeFilterValue("ann") == "ann" and escapeFilterValue("a*(b)\\") == "a\\2a\\28b\\29\\5c" and escapeFilterValue("x\0y") == "x\\00y"
    check hex(encodeFilter("(uid=" & escapeFilterValue("*)(uid=*") & ")")) == "a3" & "0f" & "0403" & hex("uid") & "0408" & hex("*)(uid=*")           # one equality whose value is the text, not a filter that matches everyone
  test "a filter that is wrong or that this client does not send is refused":
    for f in ["", "uid=ann", "(uid=ann", "(uid=ann))", "(uid)", "(=x)", "(&)", "(uid~=ann)", "(uid>=1)", "(uid:=x)", "(&(a=b)", "(a=b)(c=d)", "(uid=a\\zz)", "(uid=a\\2)"]:
      expect LdapError: discard encodeFilter(f)

suite "D-87 what the server answers":
  test "a bind response with a result code and a message":
    let body = enumOf(49) & tlv(0x04, "") & tlv(0x04, "invalid credentials")
    let r = parseResult(body)
    check r.code == 49 and r.message == "invalid credentials"
  test "a message: the id and the operation":
    let msg = tlv(0x30, berInt(5) & tlv(0x65, enumOf(0) & tlv(0x04, "") & tlv(0x04, "")))
    let a = parseMessage(msg)
    check a.id == 5 and a.op == 0x65'u8 and parseResult(a.body).code == 0
  test "an entry: the DN and the attributes with all their values, found without regard to case":
    let entry = tlv(0x04, "uid=ann,dc=x") & tlv(0x30, tlv(0x30, tlv(0x04, "memberOf") & tlv(0x31, tlv(0x04, "cn=a") & tlv(0x04, "cn=b"))) & tlv(0x30, tlv(0x04, "CN") & tlv(0x31, tlv(0x04, "Ann"))))
    let e = parseEntry(entry)
    check e.dn == "uid=ann,dc=x" and e.values("MEMBEROF") == @["cn=a", "cn=b"] and e.first("cn") == "Ann" and e.first("mail") == ""
  test "a message that is cut, a length beyond it, an integer too long, are errors and not crashes":
    for m in [tlv(0x30, berInt(1)), "\x30", "\x30\x05\x02", "\x30\x84\xff\xff\xff\xff", tlv(0x30, "\x02\x09\x01\x01\x01\x01\x01\x01\x01\x01\x01" & tlv(0x65, ""))]:
      expect LdapError: discard parseMessage(m)
  test "the addresses of a directory":
    checkLdapUrl("ldap://ldap.example.org")
    checkLdapUrl("ldaps://ldap.example.org:636")
    for u in ["", "http://x", "ldap://", "ldap://host:99999", "ldap://host:abc", "ldap://host/dc=x", "ldaps:// host"]:
      expect LdapError: checkLdapUrl(u)
