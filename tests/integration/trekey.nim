## D-80: the master key moves to another key (another key service, a key file, ...): `rekeySealed` opens each data key of an organisation and the check text of the vault with the old key and
## seals them with the new one, the secrets themselves are not touched. Against a real rqlite, with two keys that have nothing to do with each other. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times, sequtils]
import common/rqlite
import core/[schema, secretvault, kekprovider]

let url = getEnv("CINIM_RQLITE_URL")

suite "D-80 the master key moves to another":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    setDekCacheSeconds(0.0)                                        # every call asks the key: nothing is remembered from an earlier one
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let old = derivedKek("old-key-" & sfx)
    let fresh = derivedKek("new-key-" & sfx)
    let third = derivedKek("third-key-" & sfx)
    let now = getTime().toUnix()
    var tenants: seq[string]
    # the vault of a test run is shared with the other tests of the database: only the rows of these tenants are looked at, and the check text is put back at the end
    var checkBefore = ""
    let cb = c.query(%*[["SELECT value FROM vault_meta WHERE key = 'kek_check'"]])["results"][0]{"values"}
    if cb != nil and cb.len > 0: checkBefore = cb[0][0].getStr
    discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'kek_check'"], ["DELETE FROM org_keys"]])         # the vault of this test is its own: the rows of other tests are of other keys
    for i in 1 .. 3:
      let t = "rk" & $i & sfx
      tenants.add t
      check c.putSecret(old, t, "TOKEN", "value-" & $i, now).ok
    check c.ensureKeyCheck(old).ok
    proc readable(k: KekProvider; i: int): bool =
      let g = c.getSecrets(k, tenants[i], @["TOKEN"])
      g.ok and g.values == @[("TOKEN", "value-" & $(i + 1))]

    test "a dry run opens everything with the old key and the new key can wrap, and changes nothing":
      let r = c.rekeySealed(old, fresh, dryRun = true)
      check r.ok and r.moved == 4 and r.failed == 0          # three data keys would move, and the check text
      check readable(old, 0) and readable(old, 1) and readable(old, 2)
      check not readable(fresh, 0)
      check c.ensureKeyCheck(old).ok and not c.ensureKeyCheck(fresh).ok
    test "the move: the data keys and the check text open with the new key and no more with the old; the secrets read as before":
      let r = c.rekeySealed(old, fresh, dryRun = false)
      check r.ok and r.moved == 4 and r.failed == 0 and r.errors.len == 0
      check readable(fresh, 0) and readable(fresh, 1) and readable(fresh, 2)
      check not readable(old, 0)
      check c.ensureKeyCheck(fresh).ok and not c.ensureKeyCheck(old).ok
    test "a second run finds everything moved and does nothing (and says so)":
      let r = c.rekeySealed(old, fresh, dryRun = false)
      check r.ok and r.moved == 0 and r.already == 4
      check readable(fresh, 1)
    test "a row of a third key stops the check text from moving, and is told; what was movable was moved":
      # put the vault back under the old key, with one organisation sealed by a third key
      for i in 0 ..< 3: discard c.execute(%*[["DELETE FROM org_keys WHERE tenant_id = ?", tenants[i]]])
      discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'kek_check'"]])
      check c.putSecret(old, tenants[0], "TOKEN", "value-1", now).ok
      check c.putSecret(third, tenants[1], "TOKEN", "value-2", now).ok
      check c.putSecret(old, tenants[2], "TOKEN", "value-3", now).ok
      check c.ensureKeyCheck(old).ok
      let r = c.rekeySealed(old, fresh, dryRun = false)
      check r.failed == 1 and not r.ok and r.moved == 2
      check r.errors.anyIt(tenants[1] in it)
      check readable(fresh, 0) and readable(fresh, 2) and not readable(fresh, 1)
      check c.ensureKeyCheck(old).ok                               # the check text is still the old key's: the core still starts with it, until the whole move is done
    test "a key that cannot wrap says so and nothing is half moved":
      let broken = KekProvider(id: "broken", wrap: proc (plain: seq[byte]; aad: string): WrapResult {.gcsafe.} = (false, true, "the service is away", ""),
                               unwrap: fresh.unwrap)
      for i in 0 ..< 3: discard c.execute(%*[["DELETE FROM org_keys WHERE tenant_id = ?", tenants[i]]])
      discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'kek_check'"]])
      for i in 0 ..< 3: check c.putSecret(old, tenants[i], "TOKEN", "value-" & $(i + 1), now).ok
      check c.ensureKeyCheck(old).ok
      let r = c.rekeySealed(old, broken, dryRun = false)
      check not r.ok and r.retry and r.moved == 0
      check readable(old, 0) and readable(old, 1) and readable(old, 2) and c.ensureKeyCheck(old).ok
    test "teardown":
      for t in tenants: discard c.execute(%*[["DELETE FROM org_keys WHERE tenant_id = ?", t], ["DELETE FROM step_secrets WHERE tenant_id = ?", t]])
      discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'kek_check'"]])
      if checkBefore.len > 0: discard c.execute(%*[["INSERT OR IGNORE INTO vault_meta (key, value) VALUES ('kek_check', ?)", checkBefore]])
