## IAM-001, basic RBAC (D-50): the roles admin, rw, ro and what each may do. Pure.
import std/[unittest, strutils, json]
import ../../src/core/rbac

suite "IAM-001 the roles of the shard":
  test "there are four, and no other word is a role":
    check shardRoles == ["admin", "rw", "dev", "ro"]
    check validRole("admin") and validRole("rw") and validRole("dev") and validRole("ro")
    check not validRole("") and not validRole("root") and not validRole("Admin")
  test "an administrator may do anything, a made-up role nothing":
    for (m, p) in [("GET", "/api/v1/tokens"), ("POST", "/api/v1/users/rw:reset-credentials"), ("PUT", "/api/v1/storage"), ("DELETE", "/api/v1/organizations/acme")]:
      check roleMay("admin", m, p)
      check not roleMay("boss", m, p)

suite "IAM-001 what ro may do":
  test "read runs, steps, logs, artifacts, and the plain facts of the shard":
    for p in ["/api/v1/runs/s1_x", "/api/v1/runs/s1_x/steps/0/log", "/api/v1/runs/s1_x/artifacts", "/api/v1/components", "/api/v1/launch-gate",
              "/api/v1/profile", "/api/v1/alerts", "/api/v1/router", "/api/v1/organizations", "/api/v1/organizations:check",
              "/api/v1/organizations/acme/triggers"]:
      check roleMay("ro", "GET", p)
      check roleMay("ro", "HEAD", p)
  test "write nothing, anywhere":
    for m in ["POST", "PUT", "PATCH", "DELETE"]:
      for p in ["/api/v1/runs", "/api/v1/runs/s1_x", "/api/v1/profile", "/api/v1/organizations/acme/triggers"]:
        check not roleMay("ro", m, p)
  test "read what is for administrators: users, tokens, storage, secrets, controller credentials, reconciliation":
    for p in ["/api/v1/users", "/api/v1/tokens", "/api/v1/tokens/abc", "/api/v1/storage", "/api/v1/organizations/acme/secrets",
              "/api/v1/organizations/acme/secrets/TOKEN", "/api/v1/organizations:reconcile", "/api/v1/unknown", "/healthz-not-a-route"]:
      check not roleMay("ro", "GET", p)

suite "IAM-001 what dev may do":
  test "everything ro reads":
    for p in ["/api/v1/runs/s1_x", "/api/v1/runs/s1_x/steps/0/log", "/api/v1/runs/s1_x/artifacts", "/api/v1/components", "/api/v1/organizations",
              "/api/v1/organizations/acme/triggers"]:
      check roleMay("dev", "GET", p)
  test "start a run, directly or by firing a manual trigger of an organisation":
    check roleMay("dev", "POST", "/api/v1/runs")
    check roleMay("dev", "POST", "/api/v1/organizations/acme/triggers/t1:fire")
  test "change or stop nothing: no cancel, no delete, no settings, no triggers made or switched, nothing of an administrator":
    for (m, p) in [("POST", "/api/v1/runs/s1_x:cancel"), ("DELETE", "/api/v1/runs/s1_x"), ("PUT", "/api/v1/runs/s1_x"), ("PUT", "/api/v1/profile"),
                   ("POST", "/api/v1/organizations/acme/triggers"), ("POST", "/api/v1/organizations/acme/triggers/t1:disable"),
                   ("DELETE", "/api/v1/organizations/acme/triggers/t1"), ("POST", "/api/v1/organizations"), ("POST", "/api/v1/users"),
                   ("DELETE", "/api/v1/users/ro"), ("POST", "/api/v1/tokens"), ("PUT", "/api/v1/storage"), ("PUT", "/api/v1/users/dev/password")]:
      check not roleMay("dev", m, p)
    for p in ["/api/v1/users", "/api/v1/roles", "/api/v1/tokens", "/api/v1/storage", "/api/v1/organizations/acme/secrets"]:
      check not roleMay("dev", "GET", p)
  test "a dev is not a rw: the same user with both roles may do what rw may":
    check not roleMay("dev", "DELETE", "/api/v1/runs/s1_x") and rolesMay(["dev", "rw"], "DELETE", "/api/v1/runs/s1_x")

suite "IAM-001 what rw may do":
  test "everything ro reads":
    for p in ["/api/v1/runs/s1_x", "/api/v1/components", "/api/v1/organizations", "/api/v1/organizations/acme/triggers"]:
      check roleMay("rw", "GET", p)
  test "start and change runs, in any organisation (the role is the shard's)":
    check roleMay("rw", "POST", "/api/v1/runs")
    check roleMay("rw", "POST", "/api/v1/runs/s1_x:cancel")
    check roleMay("rw", "DELETE", "/api/v1/runs/s1_x")
  test "change nothing but runs":
    for (m, p) in [("PUT", "/api/v1/profile"), ("POST", "/api/v1/organizations"), ("DELETE", "/api/v1/organizations/acme"), ("POST", "/api/v1/tokens"),
                   ("PUT", "/api/v1/organizations/acme/secrets/TOKEN"), ("POST", "/api/v1/organizations/acme/triggers"), ("PUT", "/api/v1/storage"),
                   ("POST", "/api/v1/users/ro:reset-credentials")]:
      check not roleMay("rw", m, p)
  test "see none of the administrator's reads":
    for p in ["/api/v1/users", "/api/v1/tokens", "/api/v1/storage", "/api/v1/organizations/acme/secrets"]:
      check not roleMay("rw", "GET", p)
  test "a user with several roles may do what any of them may":
    check rolesMay(["ro", "rw"], "POST", "/api/v1/runs")
    check not rolesMay(["ro"], "POST", "/api/v1/runs")
    check not rolesMay(newSeq[string](), "GET", "/api/v1/runs")

suite "IAM-001 a body that lacks the field is a bad request, not a crash":
  test "a missing key is nil in a JSON object, and isString copes with it":
    check not parseJson("{}").isString("password")
    check not parseJson("""{"other": "x"}""").isString("password")
    check not parseJson("""{"password": 5}""").isString("password")
    check not parseJson("""{"password": null}""").isString("password")
    check not parseJson("""{"password": ["a"]}""").isString("password")
    check not parseJson("[]").isString("password")
    check not parseJson("\"password\"").isString("password")
    check not (nil.JsonNode).isString("password")                           # a body that did not parse
    check parseJson("""{"password": "x"}""").isString("password")
    check parseJson("""{"password": ""}""").isString("password")

suite "IAM-001 users and the line in the log":
  test "names of users":
    check validUserName("admin") and validUserName("rw") and validUserName("ci-bot_2")
    check not validUserName("") and not validUserName("Admin") and not validUserName("1st") and not validUserName("a b") and not validUserName("a".repeat(33))
  test "a password is at least 16 characters (not bytes), and not absurdly long":
    check passwordProblem("0123456789abcdef") == ""
    check passwordProblem("0123456789abcde") != ""
    check passwordProblem("") != ""
    check passwordProblem("пароль-пароль-пароль") == ""                      # 20 characters, 37 bytes
    check passwordProblem("парольпарольпар") != ""                            # 15 characters, 29 bytes: the characters count, not the bytes
    check passwordProblem("a".repeat(256)) == "" and passwordProblem("a".repeat(257)) != ""
  test "every user may change their own password and nobody else's, whatever the role":
    check selfService("rw", "PUT", "/api/v1/users/rw/password")
    check not selfService("rw", "PUT", "/api/v1/users/ro/password")
    check not selfService("rw", "POST", "/api/v1/users/rw/password")
    check not selfService("rw", "GET", "/api/v1/users/rw/password")
    check not selfService("rw", "PUT", "/api/v1/users/rw/password/x")
    check not selfService("", "PUT", "/api/v1/users//password")
    check not roleMay("ro", "PUT", "/api/v1/users/ro/password") and not roleMay("rw", "PUT", "/api/v1/users/rw/password")      # a role alone does not give it
  test "the user in a password path":
    check userOfPasswordPath("/api/v1/users/rw/password") == "rw"
    check userOfPasswordPath("/api/v1/users/ci-bot_2/password") == "ci-bot_2"
    for bad in ["/api/v1/users//password", "/api/v1/users/Bad Name/password", "/api/v1/users/rw", "/api/v1/users/rw/password/x", "/api/v1/tokens/rw/password"]:
      check userOfPasswordPath(bad) == ""
  test "the scope of a token for a user, and back":
    check userScope("rw") == "user:rw"
    check userOfScope("user:rw") == "rw"
    check userOfScope("user:") == "" and userOfScope("admin") == "" and userOfScope("org:acme") == "" and userOfScope("user:Bad Name") == ""
  test "the credentials line is the fixed word, then user, role, password, token; it parses back":
    let c = UserCredential(user: "rw", role: "rw", password: "ab".repeat(32), token: "cnm_" & "c".repeat(12) & "_" & "d".repeat(64))
    let line = credentialLine(c)
    check line.startsWith("cinim-credentials user=rw role=rw password=")
    check line.count(' ') == 4                                                  # one space between the five parts, none inside a value
    let p = parseCredentialLine(line)
    check p.ok and p.cred == c
  test "a line of another shape does not parse":
    check not parseCredentialLine("core: something").ok
    check not parseCredentialLine("cinim-credentials user=rw role=rw password=x").ok
    check not parseCredentialLine("cinim-credentials role=rw user=rw password=x token=y").ok
