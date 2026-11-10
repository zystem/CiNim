## D-104/D-105/D-106: the core's own secret (the identities of the controllers are made under it) is kept in the database sealed by the key of the secrets, so that a key service holds the only secret
## that is not in the database and a backup of the database is the only backup: `ensureMasterSecret`. The first start makes one; a later start opens what is stored; another key cannot; a move to another
## key (`rekeySealed`) takes it along. The key is a key service and nothing else: no key file, and no file `tls/master.key` is read or brought in. Against a real rqlite (needs CINIM_RQLITE_URL)
## and, for the start of the core (`resolveMasterSecret`), the stand-in of a Transit service.
import std/[unittest, json, os, strutils, times]
import common/[rqlite, ctrlauth]
import core/[schema, secretvault, kekprovider, vaultsetup]
import ../support/[testkek, transitemu]
import ../support/freeport

let url = getEnv("CINIM_RQLITE_URL")
let emuPort = 19400 + getCurrentProcessId() mod 400
requireFreePorts("tmastersecret", [emuPort])      # a port that something holds is another process: stop, do not talk to it (tests/support/freeport.nim)

suite "D-105 the master secret in the database":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let sfx = newId()[^6 .. ^1].toLowerAscii
    let key = derivedKek("master-key-" & sfx)
    let other = derivedKek("other-key-" & sfx)
    let fresh = derivedKek("fresh-key-" & sfx)
    var checkBefore = ""
    let cb = c.query(%*[["SELECT value FROM vault_meta WHERE key = 'kek_check'"]])["results"][0]{"values"}
    if cb != nil and cb.len > 0: checkBefore = cb[0][0].getStr
    # the vault of this test is its own (the rows of other tests are of other keys), and is put back at the end
    proc clear() = discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'master_secret'"], ["DELETE FROM vault_meta WHERE key = 'kek_check'"], ["DELETE FROM org_keys"]])
    clear()
    proc stored(): string =
      let v = c.query(%*[["SELECT value FROM vault_meta WHERE key = 'master_secret'"]])["results"][0]{"values"}
      if v != nil and v.len > 0: v[0][0].getStr else: ""

    test "the first start makes a random secret of 64 hexadecimal digits, sealed (the text in the database is not the secret), and a later start reads the same back":
      let a = c.ensureMasterSecret(key)
      check a.ok and a.secret.len == 64 and a.secret.allCharsInSet(HexDigits)
      check stored().len > 0 and a.secret notin stored()
      check c.ensureMasterSecret(key).secret == a.secret
    test "another key cannot open it, and says it is not for a retry":
      let r = c.ensureMasterSecret(other)
      check not r.ok and not r.retry and r.secret.len == 0
    test "a move to another key takes it along; the secret is the same, the old key opens nothing":
      let before = c.ensureMasterSecret(key).secret
      let moved = c.rekeySealed(key, fresh)
      check moved.ok and moved.moved >= 1
      check c.ensureMasterSecret(fresh).secret == before
      check not c.ensureMasterSecret(key).ok
    test "a key that cannot seal says so, and nothing is stored":
      discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'master_secret'"]])
      let broken = KekProvider(id: "broken", wrap: proc (plain: seq[byte]; aad: string): WrapResult {.gcsafe.} = (false, true, "the service is away", ""),
                               unwrap: fresh.unwrap)
      let r = c.ensureMasterSecret(broken)
      check not r.ok and r.retry
      check stored().len == 0

    # D-106: the start of the core: the key is a key service, and nothing else gives it
    let oldUrl = getEnv("CINIM_KEYSERVICE_URL")
    let oldFile = getEnv("CINIM_SECRETS_KEY_FILE")
    let dir = getTempDir() / ("tmastersecret-" & sfx)
    createDir(dir / "tls")
    defer: removeDir dir
    proc restore() =
      if oldUrl.len > 0: putEnv("CINIM_KEYSERVICE_URL", oldUrl) else: delEnv("CINIM_KEYSERVICE_URL")
      if oldFile.len > 0: putEnv("CINIM_SECRETS_KEY_FILE", oldFile) else: delEnv("CINIM_SECRETS_KEY_FILE")

    startEmulator(emuPort, @[byte 0x21] & newSeq[byte](31))          # once: the server of the stand-in cannot be started again in the same process
    test "with no key service the core does not start, and says what to give; a key file is no key (the variable of the earlier versions is not read)":
      clear()
      delEnv("CINIM_KEYSERVICE_URL")
      writeFile(dir / "kek", 'a'.repeat(64))
      putEnv("CINIM_SECRETS_KEY_FILE", dir / "kek")
      defer: restore()
      let r = resolveMasterSecret(url)
      check not r.ok and not r.retry and "CINIM_KEYSERVICE_URL" in r.error and "KEY_FILE" notin r.error
      check stored().len == 0
    test "with a key service the core makes the secret and keeps it sealed; a file tls/master.key left in the directory is never read, and a restart opens the same secret":
      clear()
      writeFile(dir / "tls" / "master.key", "the-old-secret-of-the-file\n")
      putEnv("CINIM_KEYSERVICE_URL", "http://127.0.0.1:" & $emuPort)
      putEnv("CINIM_KEYSERVICE_KEY_NAME", "cinim-shard")
      delEnv("CINIM_SECRETS_KEY_FILE")
      defer:
        restore()
        delEnv("CINIM_KEYSERVICE_KEY_NAME")
      let a = resolveMasterSecret(url)
      check a.ok
      let made = coreSecretKey(dir)
      check made != "the-old-secret-of-the-file" and made.len == 64 and made.allCharsInSet(HexDigits)
      check stored().len > 0 and made notin stored()
      check resolveMasterSecret(url).ok and coreSecretKey(dir) == made
    test "a database that has identities of controllers and keeps no master secret gets a new one: the controllers are made again under it by the core, nothing is brought in":
      clear()
      discard c.execute(%*[["DELETE FROM controller_credentials WHERE namespace = ?", "tms-" & sfx]])
      discard c.execute(%*[["INSERT INTO controller_credentials (namespace, generation, confirmed, bootstrap_expires_at) VALUES (?, 1, 0, 0)", "tms-" & sfx]])
      putEnv("CINIM_KEYSERVICE_URL", "http://127.0.0.1:" & $emuPort)
      putEnv("CINIM_KEYSERVICE_KEY_NAME", "cinim-shard")
      defer:
        discard c.execute(%*[["DELETE FROM controller_credentials WHERE namespace = ?", "tms-" & sfx]])
        restore()
        delEnv("CINIM_KEYSERVICE_KEY_NAME")
      let r = resolveMasterSecret(url)
      check r.ok and stored().len > 0

    stopEmulator()
    clear()
    if checkBefore.len > 0: discard c.execute(%*[["INSERT OR REPLACE INTO vault_meta (key, value) VALUES ('kek_check', ?)", checkBefore]])
