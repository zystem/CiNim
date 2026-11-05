## D-104/D-105: the core's own secret (the identities of the controllers are made under it) is kept in the database sealed by the key of the secrets, so that a key service holds the only secret that
## is not in the database and a backup of the database is the only backup: `ensureMasterSecret`. The first start stores what it is given (the file of a shard that had one) or makes one; a later start
## opens what is stored; another key cannot; a move to another key (`rekeySealed`) takes it along. Against a real rqlite. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils, times]
import common/[rqlite, ctrlauth]
import core/[schema, secretvault, kekprovider, vaultsetup]

let url = getEnv("CINIM_RQLITE_URL")

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
    discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'master_secret'"], ["DELETE FROM vault_meta WHERE key = 'kek_check'"], ["DELETE FROM org_keys"]])
    proc stored(): string =
      let v = c.query(%*[["SELECT value FROM vault_meta WHERE key = 'master_secret'"]])["results"][0]{"values"}
      if v != nil and v.len > 0: v[0][0].getStr else: ""

    test "the first start stores what it is given, sealed (the text in the database is not the secret), and a later start reads it back":
      let r = c.ensureMasterSecret(key, "the-secret-of-the-file")
      check r.ok and r.secret == "the-secret-of-the-file"
      check stored().len > 0 and "the-secret-of-the-file" notin stored()
      let again = c.ensureMasterSecret(key, "")
      check again.ok and again.secret == "the-secret-of-the-file"
    test "what is stored wins over what a later start is given (another core was first, or the file is left over)":
      let r = c.ensureMasterSecret(key, "a-different-file")
      check r.ok and r.secret == "the-secret-of-the-file"
    test "another key cannot open it, and says it is not for a retry":
      let r = c.ensureMasterSecret(other, "")
      check not r.ok and not r.retry and r.secret.len == 0
    test "a move to another key takes it along; the secret is the same, the old key opens nothing":
      let moved = c.rekeySealed(key, fresh)
      check moved.ok and moved.moved >= 1
      check c.ensureMasterSecret(fresh, "").secret == "the-secret-of-the-file"
      check not c.ensureMasterSecret(key, "").ok
    test "with nothing given a random secret of 64 hexadecimal digits is made, once":
      discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'master_secret'"]])
      let a = c.ensureMasterSecret(fresh, "")
      check a.ok and a.secret.len == 64 and a.secret.allCharsInSet(HexDigits)
      check c.ensureMasterSecret(fresh, "").secret == a.secret
    test "a key that cannot seal says so, and nothing is stored":
      discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'master_secret'"]])
      let broken = KekProvider(id: "broken", wrap: proc (plain: seq[byte]; aad: string): WrapResult {.gcsafe.} = (false, true, "the service is away", ""),
                               unwrap: fresh.unwrap)
      let r = c.ensureMasterSecret(broken, "x")
      check not r.ok and r.retry
      check stored().len == 0
    test "there is no mode without a key (D-106): with no key service and no key file the core does not start, and says what to give":
      let oldUrl = getEnv("CINIM_KEYSERVICE_URL")
      let oldFile = getEnv("CINIM_SECRETS_KEY_FILE")
      delEnv("CINIM_KEYSERVICE_URL"); delEnv("CINIM_SECRETS_KEY_FILE")
      defer:
        if oldUrl.len > 0: putEnv("CINIM_KEYSERVICE_URL", oldUrl)
        if oldFile.len > 0: putEnv("CINIM_SECRETS_KEY_FILE", oldFile)
      let r = resolveMasterSecret(url, getTempDir())
      check not r.ok and not r.retry and "CINIM_KEYSERVICE_URL" in r.error and "CINIM_SECRETS_KEY_FILE" in r.error
    test "a shard that ran on the file master.key brings it in once: it is stored sealed, the credential does not change, and the file is not read again":
      discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'master_secret'"], ["DELETE FROM vault_meta WHERE key = 'kek_check'"], ["DELETE FROM org_keys"]])
      let dir = getTempDir() / ("tmastersecret-" & sfx)
      createDir(dir / "tls")
      defer: removeDir dir
      writeFile(dir / "tls" / "master.key", "the-old-secret-of-the-file\n")
      let oldUrl = getEnv("CINIM_KEYSERVICE_URL")
      let oldFile = getEnv("CINIM_SECRETS_KEY_FILE")
      delEnv("CINIM_KEYSERVICE_URL")
      defer:
        if oldUrl.len > 0: putEnv("CINIM_KEYSERVICE_URL", oldUrl)
        if oldFile.len > 0: putEnv("CINIM_SECRETS_KEY_FILE", oldFile) else: delEnv("CINIM_SECRETS_KEY_FILE")
      writeFile(dir / "kek", 'a'.repeat(64))
      putEnv("CINIM_SECRETS_KEY_FILE", dir / "kek")
      check resolveMasterSecret(url, dir).ok
      check coreSecretKey(dir) == "the-old-secret-of-the-file"
      check stored().len > 0 and "the-old-secret-of-the-file" notin stored()
      removeFile(dir / "tls" / "master.key")                                      # not mounted any more: the sealed one is read
      check resolveMasterSecret(url, dir).ok and coreSecretKey(dir) == "the-old-secret-of-the-file"
    test "a database that has identities of controllers and keeps no master secret does not get a new one":
      discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'master_secret'"], ["DELETE FROM controller_credentials WHERE namespace = ?", "tms-" & sfx]])
      discard c.execute(%*[["INSERT INTO controller_credentials (namespace, generation, confirmed, bootstrap_expires_at) VALUES (?, 1, 0, 0)", "tms-" & sfx]])
      defer: discard c.execute(%*[["DELETE FROM controller_credentials WHERE namespace = ?", "tms-" & sfx]])
      let dir = getTempDir() / ("tmastersecret2-" & sfx)
      createDir(dir / "tls")
      defer: removeDir dir
      writeFile(dir / "kek", 'b'.repeat(64))
      let oldFile = getEnv("CINIM_SECRETS_KEY_FILE")
      putEnv("CINIM_SECRETS_KEY_FILE", dir / "kek")
      defer: (if oldFile.len > 0: putEnv("CINIM_SECRETS_KEY_FILE", oldFile) else: delEnv("CINIM_SECRETS_KEY_FILE"))
      discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'kek_check'"], ["DELETE FROM org_keys"]])
      let r = resolveMasterSecret(url, dir)
      check not r.ok and "identities" in r.error
    discard c.execute(%*[["DELETE FROM vault_meta WHERE key = 'master_secret'"], ["DELETE FROM vault_meta WHERE key = 'kek_check'"], ["DELETE FROM org_keys"]])
    if checkBefore.len > 0: discard c.execute(%*[["INSERT OR REPLACE INTO vault_meta (key, value) VALUES ('kek_check', ?)", checkBefore]])
