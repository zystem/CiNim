## D-59 (docs/storage-module.md, phase 1): the named stores of the shard and the choice of an organisation. A store has a name, a kind and settings, its secret is sealed in the vault; one of
## them is the default; an organisation may choose another for each purpose (artifacts, caches, held logs, audit). Against a real rqlite; needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, sequtils]
import common/rqlite
import core/[schema, secretvault, objectstore]

let url = getEnv("CINIM_RQLITE_URL")
let kek = derivedKek("a-core-secret-for-the-store-tests")

func s3(endpoint = "http://garage.test:3900", bucket = "cinim-artifacts"): StoreConfig =
  StoreConfig(found: true, kind: "s3", endpoint: endpoint, region: "garage", bucket: bucket, keyId: "GKabc")

func dav(nodes: seq[string] = @["http://caddy-0.test:8080", "http://caddy-1.test:8080"]): StoreConfig =
  StoreConfig(found: true, kind: "dav", nodes: nodes, minAcks: 0)

suite "D-59 the named stores of the shard":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let sfx = newId()[^8 .. ^1].toLowerAscii
    let now = getTime().toUnix()
    discard c.execute(%*[["DELETE FROM object_stores"]])
    discard c.execute(%*[["DELETE FROM org_storage"]])
    let garage = "garage-" & sfx
    let caddy = "caddy-" & sfx
    let orgA = "org-a-" & sfx
    let orgB = "org-b-" & sfx

    test "a store is saved with its secret sealed, shown without it, and the first one is the default":
      check c.listStores().len == 0
      check c.loadStoreWith(kek, "").error == "not_configured"
      let r = c.saveStore(kek, garage, s3(), "secret-of-garage", false, now)
      check r.ok
      let l = c.listStores()
      check l.len == 1 and l[0].name == garage and l[0].isDefault and l[0].cfg.kind == "s3" and l[0].cfg.bucket == "cinim-artifacts"
      let st = c.loadStoreWith(kek, garage)
      check st.ok and st.secret == "secret-of-garage" and st.cfg.endpoint == "http://garage.test:3900" and st.name == garage
      check c.loadStoreWith(kek, "").name == garage                         # "" is the default
      # the database holds nothing readable of the secret
      let raw = c.query(%*[["SELECT config FROM object_stores WHERE name = ?", garage]])["results"][0]{"values"}[0][0].getStr
      check "secret-of-garage" notin raw
      let sealed = c.query(%*[["SELECT value_enc FROM step_secrets WHERE name = ?", "OBJECTSTORE_SECRET_KEY:" & garage]])["results"][0]{"values"}
      check sealed.len == 1 and "secret-of-garage" notin sealed[0][0].getStr
    test "a second store is not the default until it is made one, and exactly one store is":
      check c.saveStore(kek, caddy, dav(), "token-of-the-caddy-nodes", false, now).ok
      var l = c.listStores()
      check l.len == 2
      check l[0].isDefault != l[1].isDefault
      check c.loadStoreWith(kek, "").name == garage
      check c.saveStore(kek, caddy, dav(), "token-of-the-caddy-nodes", true, now).ok       # saved again, now as the default
      check c.loadStoreWith(kek, "").name == caddy
      l = c.listStores()
      check l.countIt(it.isDefault) == 1
      check c.setDefaultStore(garage)
      check c.loadStoreWith(kek, "").name == garage and not c.setDefaultStore("no-such-store")
    test "a new secret is a new version, and the settings are replaced":
      check c.saveStore(kek, garage, s3("http://garage2.test:3900", "other-bucket"), "second-secret", false, now + 1).ok
      let st = c.loadStoreWith(kek, garage)
      check st.secret == "second-secret" and st.cfg.endpoint == "http://garage2.test:3900" and st.cfg.bucket == "other-bucket"
      check c.listStores().countIt(it.isDefault) == 1                                      # saving does not change which is the default
    test "a name or settings that cannot be are refused":
      for bad in ["", "Upper", "1starts-with-digit", "has space", "a".repeat(33), "under_score", "-dash"]:
        check not validStoreName(bad)
      for good in ["garage-main", "caddy", "s3", "a1-b2"]:
        check validStoreName(good)
      check not c.saveStore(kek, "Bad Name", s3(), "secret-of-garage", false, now).ok
      check not c.saveStore(kek, "x-" & sfx, s3(endpoint = "ftp://nope"), "secret-of-garage", false, now).ok
      check not c.saveStore(kek, "x-" & sfx, dav(@[]), "token-token", false, now).ok
      check c.listStores().len == 2
    test "an organisation's choice is kept for a purpose, read, and cleared; an unknown store or purpose is refused; another organisation is not touched":
      check c.setOrgStorage(orgA, "artifacts", caddy, "admin", now) == ""
      check c.setOrgStorage(orgA, "caches", garage, "admin", now) == ""
      check c.orgStorage(orgA) == @[("artifacts", caddy), ("caches", garage)]
      check c.orgStorage(orgB).len == 0
      check c.setOrgStorage(orgA, "artifacts", "no-such-store", "admin", now).len > 0
      check c.setOrgStorage(orgA, "logs", garage, "admin", now).len > 0
      check c.setOrgStorage(orgA, "caches", "", "admin", now) == ""                        # empty clears: the default again
      check c.orgStorage(orgA) == @[("artifacts", caddy)]
    test "which store a purpose uses: the organisation's choice, else the default":
      check c.storeFor(orgA, "artifacts") == caddy
      check c.storeFor(orgA, "caches") == garage                                           # the default (garage)
      check c.storeFor(orgB, "artifacts") == garage
      check c.storeFor(orgB, "held_logs") == garage
    test "a store that is in use cannot be forgotten; the default needs another one first":
      let r1 = c.forgetStore(caddy)
      check not r1.ok and "organisation" in r1.error                                      # orgA chose it
      check c.setOrgStorage(orgA, "artifacts", "", "admin", now) == ""
      discard c.execute(%*[["INSERT INTO artifacts (id, tenant_id, run_id, step_ordinal, path, s3_key, size, sha256, state, created_at, store) VALUES (?, 't', ?, 0, 'p', 'k', 1, 'x', 'stored', ?, ?)",
        newId(), "run-" & sfx, now, caddy]])
      let r2 = c.forgetStore(caddy)
      check not r2.ok and "artifact" in r2.error                                          # an artifact lies in it
      discard c.execute(%*[["DELETE FROM artifacts WHERE run_id = ?", "run-" & sfx]])
      discard c.execute(%*[["INSERT INTO caches (id, tenant_id, scope, key, s3_key, size, sha256, state, upload_id, created_at, last_used_at, store) VALUES (?, 't', '', ?, 'k', 1, 'x', 'stored', '', ?, ?, ?)",
        newId(), "ck-" & sfx, now, now, caddy]])
      let r3 = c.forgetStore(caddy)
      check not r3.ok and "cache" in r3.error
      discard c.execute(%*[["DELETE FROM caches WHERE key = ?", "ck-" & sfx]])
      let r4 = c.forgetStore(garage)
      check not r4.ok and "default" in r4.error
      check c.forgetStore(caddy).ok
      check c.listStores().len == 1
      check not c.forgetStore("no-such-store").ok
    test "the last store can be forgotten when nothing uses it; then there is none":
      check c.forgetStore(garage).ok
      check c.listStores().len == 0 and c.storeFor(orgB, "artifacts") == ""
      check c.loadStoreWith(kek, "").error == "not_configured"
