## D-60 (docs/storage-module.md): the secrets of the stores are sealed under the module's key with the store's name as additional data; and the token of the core's call is good for one shard,
## method and target (path with its query) for two minutes.
import std/[unittest, strutils]
import storage/seal
import common/storagetoken

suite "D-60 the module's seal and the core's token":
  let key = sealKey("a-seal-key-for-the-unit-test")

  test "D-60 a sealed secret opens under the same key and store name, and under no other":
    let sealed = seal(key, "garage-main", "the-secret")
    check sealed.startsWith("v1.") and "the-secret" notin sealed
    check unseal(key, "garage-main", sealed) == (true, "the-secret")
    check not unseal(key, "caddy-main", sealed).ok                              # another store's row
    check not unseal(sealKey("another seal key of the module"), "garage-main", sealed).ok
    check not unseal(key, "garage-main", sealed[0 ..< sealed.len - 2] & "00").ok     # damaged
    check not unseal(key, "garage-main", "").ok and not unseal(key, "garage-main", "v1.zz").ok
    check seal(key, "garage-main", "the-secret") != sealed                      # a fresh nonce every time

  test "D-60 a token is good for its shard, method, path and query, and for two minutes":
    let now = 1_700_000_000'i64
    let t = signTarget("s3cr3t-of-shard", "001", "GET", "/v1/stores/a/objects/k?stat", now)
    check verifyTarget("s3cr3t-of-shard", "001", "GET", "/v1/stores/a/objects/k?stat", t, now)
    check verifyTarget("s3cr3t-of-shard", "001", "get", "/v1/stores/a/objects/k?stat", t, now + 100)
    check not verifyTarget("s3cr3t-of-shard", "002", "GET", "/v1/stores/a/objects/k?stat", t, now)             # another shard
    check not verifyTarget("s3cr3t-of-shard", "001", "PUT", "/v1/stores/a/objects/k?stat", t, now)             # another method
    check not verifyTarget("s3cr3t-of-shard", "001", "GET", "/v1/stores/a/objects/k", t, now)                  # the query is signed
    check not verifyTarget("s3cr3t-of-shard", "001", "GET", "/v1/stores/a/objects/j?stat", t, now)             # another path
    check not verifyTarget("another-secret", "001", "GET", "/v1/stores/a/objects/k?stat", t, now)
    check not verifyTarget("s3cr3t-of-shard", "001", "GET", "/v1/stores/a/objects/k?stat", t, now + tokenLifetime + 1)    # expired
    check not verifyTarget("s3cr3t-of-shard", "001", "GET", "/v1/stores/a/objects/k?stat", t, now - clockSkew - tokenLifetime - 5)   # from too far ahead
    check not verifyTarget("s3cr3t-of-shard", "001", "GET", "/v1/stores/a/objects/k?stat", "", now)
    check not verifyTarget("s3cr3t-of-shard", "001", "GET", "/v1/stores/a/objects/k?stat", "v1.1.2", now)
    check not verifyTarget("", "001", "GET", "/x", t, now)
