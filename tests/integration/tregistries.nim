## D-114, against a real rqlite: the registries of an organisation - saved with the password sealed, changed field by field, listed and deleted, the Docker config made from them, what is
## wrong with a request told. Needs CINIM_RQLITE_URL; without it the suite is skipped.
import std/[unittest, json, os, times, strutils, base64]
import common/rqlite
import core/[schema, secretvault, registries]
import ../support/testkek

let url = getEnv("CINIM_RQLITE_URL")

suite "D-114 registries of an organisation":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    setDekCacheSeconds(0.0)
    let sfx = newId()
    let kek = derivedKek("registries-key-" & sfx)
    let now = getTime().toUnix()
    let slug = "rg" & sfx
    let orgId = c.addOrganization(slug, "R")
    let otherOrg = c.addOrganization("ro" & sfx, "O")
    proc put(name: string; j: JsonNode; org = orgId): tuple[error: string, status: int, created: bool] = c.putRegistry(kek, true, org, name, j, now)

    test "a registry is saved, with its password sealed, and listed without it":
      let done = put("gh", %*{"address": "ghcr.io/acme", "username": "ann", "password": "tok-secret-1", "description": "images of acme"})
      check done.error == "" and done.created
      let row = c.query(%*[["SELECT secret_enc FROM registries WHERE tenant_id = ? AND name = 'gh'", orgId]])["results"][0]["values"][0][0].getStr
      check row.len > 0 and "tok-secret-1" notin row
      let all = c.registriesOf(orgId)
      check all.len == 1 and all[0].name == "gh" and all[0].address == "ghcr.io/acme" and all[0].username == "ann" and all[0].description == "images of acme"
      check all[0].view["has_password"].getBool and "tok-secret-1" notin $all[0].view

    test "the Docker config is made from the opened password":
      let r = c.registryNamed(orgId, "gh").registry
      let cfg = c.dockerConfigFor(kek, true, r)
      check cfg.ok
      check decode(parseJson(cfg.config)["auths"]["ghcr.io"]["auth"].getStr) == "ann:tok-secret-1"
      check not c.dockerConfigFor(kek, false, r).ok                                      # the secrets of the core are not available
      var broken = r
      broken.secretEnc = "not a sealed text"
      check not c.dockerConfigFor(kek, true, broken).ok

    test "a field that is left out keeps its value, a new password replaces the old, an empty one takes the login away":
      check put("gh", %*{"insecure": true}).error == ""
      var r = c.registryNamed(orgId, "gh").registry
      check r.insecure and r.address == "ghcr.io/acme" and r.username == "ann"
      check put("gh", %*{"password": "tok-secret-2"}).created == false
      check decode(parseJson(c.dockerConfigFor(kek, true, c.registryNamed(orgId, "gh").registry).config)["auths"]["ghcr.io"]["auth"].getStr) == "ann:tok-secret-2"
      check put("gh", %*{"username": "", "password": ""}).error == ""
      r = c.registryNamed(orgId, "gh").registry
      check r.secretEnc.len == 0 and r.username.len == 0
      check c.dockerConfigFor(kek, true, r) == (true, "", "")

    test "what is wrong with a request is told, and nothing is saved":
      check put("Bad Name", %*{"address": "ghcr.io"}).status == 400
      check put("x", %*{"address": "https://ghcr.io/acme"}).status == 400
      check put("x", %*{}).error.contains("address is required")
      check put("x", %*{"address": "ghcr.io", "password": "pw"}).error.contains("needs username")
      check put("x", %*{"address": "ghcr.io", "username": "u"}).error.contains("needs password")
      check put("x", %*{"address": "ghcr.io", "username": "a:b", "password": "pw"}).status == 400
      check put("x", %*{"address": "ghcr.io", "insecure": "yes"}).status == 400
      check put("x", %*{"address": 5}).status == 400
      check put("x", %*{"address": "ghcr.io", "password": "pw", "username": "u"}, org = orgId).error == ""     # control: a good one is accepted
      check not c.registryNamed(orgId, "bad name").found
      check not c.registryNamed(orgId, "bad-name").found
      check put("y", newJArray()).status == 400
      check not put("x", %*{"address": "ghcr.io", "password": "pw", "username": "u"}, org = orgId).created        # the same name is a change
      check put("z", %*{"address": "ghcr.io", "password": "pw"}, org = orgId).error.len > 0                          # a password without a login

    test "the vault being unavailable refuses a password and saves nothing":
      let done = c.putRegistry(kek, false, orgId, "nov", %*{"address": "ghcr.io", "username": "u", "password": "pw"}, now)
      check done.status == 503
      check not c.registryNamed(orgId, "nov").found

    test "the registries of one organisation are not those of another, and a name is free in each":
      check put("gh", %*{"address": "quay.io/other"}, org = otherOrg).created
      check c.registryNamed(otherOrg, "gh").registry.address == "quay.io/other"
      check c.registryNamed(orgId, "gh").registry.address == "ghcr.io/acme"
      check c.registriesOf(otherOrg).len == 1

    test "at most 50 registries to an organisation":
      let org = c.addOrganization("rm" & sfx, "M")
      for i in 1 .. maxRegistriesPerOrg: check put("r" & $i, %*{"address": "r" & $i & ".example.org"}, org = org).error == ""
      check put("one-more", %*{"address": "x.example.org"}, org = org).status == 409
      check put("r1", %*{"description": "a change is not a new one"}, org = org).error == ""

    test "a registry is deleted, once":
      check c.deleteRegistry(orgId, "gh")
      check not c.registryNamed(orgId, "gh").found
      check not c.deleteRegistry(orgId, "gh")
