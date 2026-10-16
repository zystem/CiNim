## D-57 (docs/store.md): the tokens of the calls to an HTTP store node. One token is good for one node, one method, one path, for a short time. Pure.
import std/[unittest, strutils]
import core/storeauth

const secret = "a-store-secret-of-some-length"

suite "D-57 store node tokens":
  test "a token is good for the request it was made for":
    let t = signRequest(secret, "store-0:8080", "PUT", "/acme/r1/dist/app.txt", 1000)
    check verifyRequest(secret, "store-0:8080", "PUT", "/acme/r1/dist/app.txt", t, 1000)
    check verifyRequest(secret, "store-0:8080", "PUT", "/acme/r1/dist/app.txt", t, 1000 + tokenLifetime)         # to the last second
    check verifyRequest(secret, "store-0:8080", "put", "/acme/r1/dist/app.txt?x=1", t, 1050)                    # the method's case and the query do not matter
  test "it is not good for another node, method, path, or secret":
    let t = signRequest(secret, "store-0:8080", "PUT", "/a/b", 1000)
    check not verifyRequest(secret, "store-1:8080", "PUT", "/a/b", t, 1000)
    check not verifyRequest(secret, "store-0:8080", "DELETE", "/a/b", t, 1000)
    check not verifyRequest(secret, "store-0:8080", "PUT", "/a/c", t, 1000)
    check not verifyRequest(secret, "store-0:8080", "PUT", "/a/b/", t, 1000)
    check not verifyRequest(secret & "x", "store-0:8080", "PUT", "/a/b", t, 1000)
    check not verifyRequest("", "store-0:8080", "PUT", "/a/b", t, 1000)
    check not verifyRequest(secret, "", "PUT", "/a/b", t, 1000)
  test "the path counts as the bytes it stands for, not as it is written":
    let t = signRequest(secret, "n", "GET", "/t/r/a%20b%2Fc%41", 1000)
    check verifyRequest(secret, "n", "GET", "/t/r/a b/cA", t, 1000)
    check verifyRequest(secret, "n", "GET", "/t/r/a%20b%2fc%41?Range=1", t, 1000)
    check verifyRequest(secret, "n", "GET", "/t/r/a%20b/cA", t, 1000)                                           # %2F is a slash once decoded, as the WebDAV handler sees it
    check not verifyRequest(secret, "n", "GET", "/t/r/a%20b/cB", t, 1000)
  test "a token does not outlive its time, and does not come from far in the future":
    let t = signRequest(secret, "n", "GET", "/p", 1000)
    check not verifyRequest(secret, "n", "GET", "/p", t, 1000 + tokenLifetime + 1)
    check verifyRequest(secret, "n", "GET", "/p", t, 1000 - clockSkew)                                          # the node's clock is a little behind
    check not verifyRequest(secret, "n", "GET", "/p", t, 1000 - clockSkew - tokenLifetime - 1)
  test "a damaged token is refused, whatever is wrong with it":
    let t = signRequest(secret, "n", "GET", "/p", 1000)
    let parts = t.split('.')
    for bad in ["", "v1", "v1.1000", "v2." & parts[1] & "." & parts[2], "v1.." & parts[2], "v1.abc." & parts[2], "v1." & parts[1] & ".", "v1." & parts[1] & "." & parts[2][0 ..< 63],
                "v1." & parts[1] & "." & parts[2] & "0", "v1." & $(parseInt(parts[1]) + 1) & "." & parts[2], t & ".x", "Bearer " & t]:
      check not verifyRequest(secret, "n", "GET", "/p", bad, 1000)

suite "D-57 the answer to forward_auth":
  proc asked(token, node, meth, fwd: string; auth = "Authorization"): string =
    "GET " & authPath & "?node=" & node & " HTTP/1.1\r\nHost: core\r\n" & (if token.len > 0: auth & ": Bearer " & token & "\r\n" else: "") &
      "X-Forwarded-Method: " & meth & "\r\nX-Forwarded-Uri: " & fwd & "\r\nAccept: */*\r\n\r\n"
  test "the request the node forwards is checked against the token it carries":
    let t = signRequest(secret, "store-0:8080", "PUT", "/a/b~obj/.c0000000", 1000)
    let q = authPath & "?node=store-0:8080"
    check storeAuthOk(asked(t, "store-0:8080", "PUT", "/a/b~obj/.c0000000"), q, secret, 1000)
    check storeAuthOk(asked(t, "store-0:8080", "PUT", "/a/b~obj/.c0000000", "authorization"), q, secret, 1000)       # the name's case
    check not storeAuthOk(asked(t, "store-0:8080", "PUT", "/a/other"), q, secret, 1000)
    check not storeAuthOk(asked(t, "store-0:8080", "GET", "/a/b~obj/.c0000000"), q, secret, 1000)
    check not storeAuthOk(asked(t, "store-0:8080", "PUT", "/a/b~obj/.c0000000"), authPath & "?node=store-1:8080", secret, 1000)
    check not storeAuthOk(asked(t, "store-0:8080", "PUT", "/a/b~obj/.c0000000"), authPath, secret, 1000)               # no node named
    check not storeAuthOk(asked("", "store-0:8080", "PUT", "/a/b"), q, secret, 1000)                                  # no token
    check not storeAuthOk(asked(t, "store-0:8080", "PUT", "/a/b~obj/.c0000000"), q, secret, 5000)                     # too late
    check not storeAuthOk("GET / HTTP/1.1\r\nAuthorization: Basic " & t & "\r\n\r\n", q, secret, 1000)             # not a bearer token
