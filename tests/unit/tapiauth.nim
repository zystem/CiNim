## IAM-003: the pure parts of the API tokens (the header, the token, the scopes).
import std/[unittest, strutils]
import ../../src/core/apiauth

suite "the bearer token of a request":
  test "it is read from the header, whatever the case of the name and of the scheme":
    check bearerOf("GET /x HTTP/1.1\r\nHost: a\r\nAuthorization: Bearer abc123\r\n\r\n") == "abc123"
    check bearerOf("GET /x HTTP/1.1\r\nauthorization: bearer  abc123 \r\n\r\n") == "abc123"
  test "no header, another scheme, or an empty value is no token; the body is not the header":
    check bearerOf("GET /x HTTP/1.1\r\nHost: a\r\n\r\n") == ""
    check bearerOf("GET /x HTTP/1.1\r\nAuthorization: Basic dXNlcjpwYXNz\r\n\r\n") == ""
    check bearerOf("GET /x HTTP/1.1\r\nAuthorization: Bearer \r\n\r\n") == ""
    check bearerOf("POST /x HTTP/1.1\r\nHost: a\r\n\r\nAuthorization: Bearer inbody") == ""

suite "the token":
  test "a new token has the shape that splitToken accepts, and its secret is never the stored value":
    let t = mintToken()
    check t.token.startsWith("cnm_") and t.id.len == 12 and t.secret.len == 64
    let s = splitToken(t.token)
    check s.ok and s.id == t.id and s.secret == t.secret
    check secretHash(t.secret) != t.secret and secretHash(t.secret).len == 64
  test "two tokens differ":
    check mintToken().token != mintToken().token
  test "a token of the wrong shape is refused before any lookup":
    check not splitToken("").ok
    check not splitToken("cnm_short").ok
    check not splitToken("xxx_" & "a".repeat(12) & "_" & "a".repeat(64)).ok
    check not splitToken("cnm_" & "g".repeat(12) & "_" & "a".repeat(64)).ok       # not hex
    check not splitToken("cnm_" & "a".repeat(12) & "-" & "a".repeat(64)).ok
  test "the hash is the SHA-256 (a known value)":
    check secretHash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

suite "scopes":
  test "admin, or one organisation":
    check validScope("admin") and validScope("org:acme") and validScope("org:a1-b2")
    check not validScope("") and not validScope("org:") and not validScope("org:Acme") and not validScope("org:1abc")
    check not validScope("org:acme-") and not validScope("root") and not validScope("org:ac me") and not validScope("org:" & "a".repeat(41))
  test "an administrator may use any organisation, an organisation's token its own and no other, a failed one nothing":
    let adm = principalOf("admin")
    let acme = principalOf("org:acme")
    check adm.admin and adm.mayUseOrg("acme") and adm.mayUseOrg("other") and adm.mayUseOrg("")
    check acme.mayUseOrg("acme") and not acme.mayUseOrg("other") and not acme.mayUseOrg("")
    check not principalOf("nonsense").mayUseOrg("acme")
  test "IAM-001 mayCall is the one answer of the gate and of the page of a run: an administrator any call, a user what the roles allow, an organisation's token the runs routes, a failed token nothing":
    let abortPath = "/api/v1/runs/s1_a:abort"
    check principalOf("admin").mayCall("DELETE", "/api/v1/users/ann") and principalOf("admin").mayCall("POST", abortPath)
    check principalOf("org:acme").mayCall("POST", abortPath) and principalOf("org:acme").mayCall("GET", "/api/v1/runs/s1_a")
    check not principalOf("org:acme").mayCall("GET", "/api/v1/users") and not principalOf("org:acme").mayCall("POST", "/api/v1/organizations")
    check not principalOf("nonsense").mayCall("GET", "/api/v1/runs")
    var user = Principal(ok: true, user: "ann", roles: @["ro"], grants: grantsOfRoles(["ro"]))
    check user.mayCall("GET", "/api/v1/runs/s1_a") and not user.mayCall("POST", abortPath) and not user.mayCall("POST", "/api/v1/runs/s1_a:retry")
    user.grants = grantsOfRoles(["dev"])
    check user.mayCall("POST", abortPath) and user.mayCall("POST", "/api/v1/runs/s1_a:retry") and not user.mayCall("DELETE", "/api/v1/organizations/acme")
    user.grants = grantsOfRoles(["ro", "dev"])                                   # the rights of the roles add up
    check user.mayCall("POST", abortPath)
    check user.mayCall("PUT", "/api/v1/users/ann/password") and not user.mayCall("PUT", "/api/v1/users/bob/password")      # one's own password
    check not Principal(ok: true, user: "gone").mayCall("GET", "/api/v1/runs")      # a user with no role left may do nothing
