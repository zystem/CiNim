## D-114: the registries of an organisation, the parts that need no database: the rules for a name and an address, the Docker config made from a registry, what the view shows.
import std/[unittest, json, base64, strutils]
import core/registries

suite "D-114 registries: names and addresses":
  test "a name is lowercase letters, digits, - and _, starting with a letter":
    check validRegistryName("gitea")
    check validRegistryName("ghcr-acme_2")
    check not validRegistryName("")
    check not validRegistryName("Gitea")
    check not validRegistryName("1gitea")
    check not validRegistryName("a b")
    check not validRegistryName("a".repeat(41))
  test "an address is host[:port][/path] with no scheme and nothing that is not part of one":
    check validRegistryAddress("ghcr.io/acme")
    check validRegistryAddress("registry.example.org:5000")
    check validRegistryAddress("gitea.example.org/owner/project")
    check validRegistryAddress("registry-docker-registry.registry.svc:5000")
    check not validRegistryAddress("")
    check not validRegistryAddress("https://ghcr.io/acme")
    check not validRegistryAddress("ghcr.io/ac me")
    check not validRegistryAddress("ghcr.io/acme/")
    check not validRegistryAddress("ghcr.io:port")
    check not validRegistryAddress("ghcr.io/acme?x=1")
    check not validRegistryAddress("user:pw@ghcr.io")
    check not validRegistryAddress("a".repeat(201))

suite "D-114 registries: the Docker config":
  test "the login is keyed by the host (and the port) of the address, not by its path":
    let cfg = parseJson(dockerConfigOf("ghcr.io/acme", "ann", "tok-1"))
    check cfg["auths"].len == 1
    check cfg["auths"].hasKey("ghcr.io")
    check decode(cfg["auths"]["ghcr.io"]["auth"].getStr) == "ann:tok-1"
    let cfg2 = parseJson(dockerConfigOf("registry.example.org:5000/team", "bob", "pw"))
    check cfg2["auths"].hasKey("registry.example.org:5000")
  test "Docker Hub is keyed as Docker writes it":
    for a in ["docker.io/acme", "index.docker.io/acme", "registry-1.docker.io/acme"]:
      check parseJson(dockerConfigOf(a, "ann", "pw"))["auths"].hasKey("https://index.docker.io/v1/")
  test "a password with characters that need quoting is kept as it is":
    let pw = "p\"w:\\ $x 'y' \u00e9"
    check decode(parseJson(dockerConfigOf("ghcr.io/a", "u", pw))["auths"]["ghcr.io"]["auth"].getStr) == "u:" & pw
  test "no login, no config: an empty string":
    check dockerConfigOf("ghcr.io/acme", "", "") == ""

suite "D-114 registries: the view":
  test "the view tells whether there is a login and never shows the password or its sealed form":
    let r = Registry(id: "r1", name: "gh", address: "ghcr.io/acme", username: "ann", secretEnc: "SEALED-xyz", insecure: false, description: "the public images", createdAt: 5, updatedAt: 6)
    let v = r.view
    check v["name"].getStr == "gh"
    check v["address"].getStr == "ghcr.io/acme"
    check v["username"].getStr == "ann"
    check v["has_password"].getBool
    check v["insecure"].getBool == false
    check "SEALED" notin $v
    check not v.hasKey("password")
    check not Registry(name: "x", address: "a.b").view["has_password"].getBool
