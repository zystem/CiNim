## D-114, against a real rqlite: the registries of an organisation - saved with the password sealed, changed field by field, listed and deleted, the Docker config made from them, what is
## wrong with a request told. Needs CINIM_RQLITE_URL; without it the suite is skipped.
import std/[unittest, json, os, times, strutils, base64]
import common/[rqlite, scriptsource, bytestr]
import core/[schema, secretvault, registries, scheduler, groups, projectpolicy, loggate, logcircuit, runlease]
import ../../build/nimproto/protos
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

suite "D-114 registries given to the steps that push":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    setDekCacheSeconds(0.0)
    let sfx = newId()
    let kek = derivedKek("registries-steps-" & sfx)
    let now = getTime().toUnix()
    let orgId = c.addOrganization("rs" & sfx, "S")
    let otherOrg = c.addOrganization("rt" & sfx, "T")
    proc put(name: string; j: JsonNode; org = orgId) = check c.putRegistry(kek, true, org, name, j, now).error == ""
    put("gh", %*{"address": "ghcr.io/acme", "username": "ann", "password": "tok-gh"})
    put("hub", %*{"address": "docker.io/acme", "username": "bob", "password": "tok-hub"})
    put("lan", %*{"address": "10.0.0.5:5000", "insecure": true})
    put("gh", %*{"address": "quay.io/other"}, org = otherOrg)

    test "the logins of the named registries are one Docker config; a registry without a login adds nothing; Docker Hub is keyed as `docker login` keys it":
      let cfg = c.registriesConfig(kek, true, orgId, @["gh", "hub", "lan"], trusted = true)
      check cfg.ok
      let auths = parseJson(cfg.config)["auths"]
      check auths.len == 2
      check decode(auths["ghcr.io"]["auth"].getStr) == "ann:tok-gh"
      check decode(auths["https://index.docker.io/v1/"]["auth"].getStr) == "bob:tok-hub"
      let none = c.registriesConfig(kek, true, orgId, @["lan"])                                                   # no login: nobody needs to be trusted for it
      check none.ok and parseJson(none.config) == %*{"auths": {}}
    test "a login goes to a trusted run only: a run that is not on a protected ref is refused and told why, and a registry without a login is still free":
      let denied = c.registriesConfig(kek, true, orgId, @["gh", "lan"])                                        # trusted is false unless it is said
      check not denied.ok and not denied.retry and "gh has a login" in denied.error and "protected ref" in denied.error and "tok-gh" notin denied.error
      check c.registriesConfig(kek, true, orgId, @["gh"], trusted = false).config.len == 0
      check c.registriesConfig(kek, true, orgId, @["gh", "lan"], trusted = true).ok
    test "a name the organisation has not is refused, and a registry of another organisation is not seen; a vault that does not answer is a retry":
      let unknown = c.registriesConfig(kek, true, orgId, @["gh", "nowhere"], trusted = true)
      check not unknown.ok and not unknown.retry and "no registry nowhere" in unknown.error
      check parseJson(c.registriesConfig(kek, true, otherOrg, @["gh"], trusted = true).config)["auths"].len == 0     # the other organisation's `gh` has no login: nothing of ours is in it
      let down = c.registriesConfig(kek, false, orgId, @["gh"], trusted = true)
      check not down.ok and down.retry
    test "the password is in the config as the login needs it and nowhere else the core wrote: the registry's own row holds it sealed":
      let row = c.query(%*[["SELECT secret_enc FROM registries WHERE tenant_id = ? AND name = 'gh'", orgId]])["results"][0]["values"][0][0].getStr
      check "tok-gh" notin row and "ann" notin row

    test "the host calls: `registry` answers the address, plain HTTP and login of the object, and a step that names registries is made only when they exist":
      let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
      let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns", buildOn: true, deployOn: true, orgPrefix: "cinim", orgShard: "001")
      let prof = c.ensureOrganizationProfile(orgId, "cinim-001-rs-" & sfx)
      check c.createGroup(orgId, "g", now).error.len == 0
      let p1 = c.createProject(orgId, "g/p1", "https://example.test/p1.git", now)
      check p1.error.len == 0
      let run = co.createRun("return 1", orgId, prof, groupId = p1.id, source = Source(repository: "https://example.test/p1.git", commit: "0123456789abcdef0123456789abcdef01234567", path: ".ci/pipeline.lua", refName: "main"))
      var next = 0'u64
      proc call(kind, payload: string; key = ""; numbered = false): ExecutorResponse =
        var tok = takeRunLease(c, "master", run, "test")
        if tok.len == 0:
          tok = leaseToken("master", run, c.query(%*[["SELECT lease_attempt FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getInt)
        inc next
        handleCall(c, co, HostCall(run_id: run, lease_token: tok, seq: next, kind: kind, key: key, numbered: numbered, step_no: uint32(next), payload: cast[seq[byte]](payload)), "master")
      proc ok(r: ExecutorResponse): bool = r.body.kind == ExecutorResponseBodyKind.result
      proc why(r: ExecutorResponse): string = (if r.body.kind == ExecutorResponseBodyKind.failure: r.body.failure.detail else: "")
      proc said(r: ExecutorResponse): string = bytesToStr(r.body.result.result)
      let gh = call("registry", "gh", key = "registry#0")
      check ok(gh) and said(gh) == "ghcr.io/acme\n0\n1"
      check said(call("registry", "lan", key = "registry#1")) == "10.0.0.5:5000\n1\n0"
      check "no registry nowhere" in why(call("registry", "nowhere", key = "registry#2"))
      check "without its key" in why(call("registry", "gh"))
      let step = proc (opts: string): ExecutorResponse = call("job_sh", "job-" & $(next + 1) & "\tkaniko\t\t" & opts & "\techo x", numbered = true)
      check "has a login" in why(step("""{"registries":["gh","hub"]}""")) and "protected ref" in why(step("""{"registries":["gh"]}"""))      # the run is not on a protected ref
      check ok(step("""{"registries":["lan"]}"""))                                                                                  # a registry without a login is for everyone
      discard c.execute(%*[["UPDATE runs SET trusted = 1 WHERE id = ?", run]])
      check ok(step("""{"registries":["gh","hub"]}"""))
      # D-114: the group above the project narrows the registries of the organisation: what it does not list is not available below it, in the step and in the host call, and a project cannot widen it
      let gGroup = c.groupIdOf(orgId, "g").id
      check c.setAllowedRegistries(gGroup, @["gh", "lan"]) == ""
      check "not available" in why(step("""{"registries":["hub"]}""")) and "not available" in why(call("registry", "hub", key = "registry#9"))
      check ok(step("""{"registries":["gh"]}""")) and ok(step("""{"registries":["lan"]}""")) and said(call("registry", "lan", key = "registry#10")) == "10.0.0.5:5000\n1\n0"
      check "not allowed by a group above" in c.setAllowedRegistries(p1.id, @["lan", "hub"])               # hub is not allowed above: a project cannot widen
      check "no registry" in c.setAllowedRegistries(p1.id, @["nowhere"])
      check c.setAllowedRegistries(p1.id, @["lan"]) == "" and c.effectiveRegistries(p1.id).names == @["lan"]
      check "not available" in why(step("""{"registries":["gh"]}""")) and ok(step("""{"registries":["lan"]}"""))      # the project narrowed it further
      check c.setAllowedRegistries(p1.id, @[]) == "" and c.effectiveRegistries(p1.id).names == @["gh", "lan"]           # emptied: it inherits the group's again
      check c.setAllowedRegistries(gGroup, @[]) == "" and c.effectiveRegistries(p1.id).all
      check ok(step("""{"registries":["hub"]}"""))
      check "no registry nowhere" in why(step("""{"registries":["gh","nowhere"]}"""))
      check "at most 8" in why(step("""{"registries":["a","b","c","d","e","f","g","h","i"]}"""))
      # the variables the core makes are not stored secrets: a step may ask for them (D-99, D-114) without a secret of that name
      check ok(step("""{"api":["run.read"],"secrets":["CINIM_API_TOKEN"]}"""))
      check ok(step("""{"registries":["gh"],"secrets":["CINIM_REGISTRY_CONFIG"]}"""))
