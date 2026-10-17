## D-60 (docs/storage-module.md): the settings of a store are checked before they are kept, the pieces of the S3 backend, and the names of stores. The module's own rules, without a database.
import std/[unittest, strutils]
import storage/[registry, s3backend]

suite "DAT-003 the storage module's rules":
  test "DAT-003 the settings are checked before they are kept":
    let ok = StoreConfig(kind: "s3", endpoint: "http://garage:3900", region: "garage", bucket: "cinim-artifacts", keyId: "GK123")
    check checkConfig(ok, "secret") == ""
    check checkConfig(StoreConfig(kind: "s3", endpoint: "garage", region: "garage", bucket: "cinim-artifacts", keyId: "k"), "s").contains("endpoint")
    check checkConfig(StoreConfig(kind: "s3", endpoint: "http://g:1/x", region: "garage", bucket: "cinim-artifacts", keyId: "k"), "s").contains("endpoint")
    check checkConfig(StoreConfig(kind: "s3", endpoint: "http://g:1", region: "", bucket: "cinim-artifacts", keyId: "k"), "s").contains("region")
    check checkConfig(StoreConfig(kind: "s3", endpoint: "http://g:1", region: "r", bucket: "Bad Bucket", keyId: "k"), "s").contains("bucket")
    check checkConfig(StoreConfig(kind: "s3", endpoint: "http://g:1", region: "r", bucket: "ab", keyId: "k"), "s").contains("bucket")
    check checkConfig(ok, "").contains("secret")
    check checkConfig(ok, "with space").contains("secret")

  test "DAT-003 the body of CompleteMultipartUpload lists the parts in order with quoted ETags":
    let x = completeXml(@[(1, "\"aa\""), (2, "bb")])
    check x == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"aa\"</ETag></Part><Part><PartNumber>2</PartNumber><ETag>\"bb\"</ETag></Part></CompleteMultipartUpload>"

  test "DAT-003 the upload id and the error of a store's answer are read from its XML":
    check tagText("<InitiateMultipartUploadResult><Bucket>b</Bucket><UploadId>abc123</UploadId></InitiateMultipartUploadResult>", "UploadId") == "abc123"
    check tagText("<x/>", "UploadId") == ""
    check s3Error(403, "<Error><Code>AccessDenied</Code><Message>no</Message></Error>") == "the store answered 403 AccessDenied: no"
    check s3Error(500, "") == "the store answered 500"

  test "D-57 the settings of HTTP store nodes: 1 to 4 addresses with a scheme and a port, a number of confirmations that fits, a token":
    let ok = StoreConfig(kind: "dav", nodes: @["http://store-0.store:8080", "https://store-1.store:8443/share"], minAcks: 0)
    check ok.isMirror and checkConfig(ok, "a-token-long-enough") == ""
    var bad = ok
    bad.nodes = @[]
    check checkConfig(bad, "a-token-long-enough").len > 0
    bad.nodes = @["http://a:1", "http://b:1", "http://c:1", "http://d:1", "http://e:1"]
    check checkConfig(bad, "a-token-long-enough").len > 0
    for a in ["tcp://store-0:19750", "store-0:8080", "http://store-0", "ftp://store-0:21", "http://store-0:8080?x=1", "http://store-0:8080#id", "https://", "http://a b:80"]:
      bad = ok
      bad.nodes = @[a]
      check checkConfig(bad, "a-token-long-enough").len > 0
    bad = ok
    bad.minAcks = 3
    check checkConfig(bad, "a-token-long-enough").len > 0
    check checkConfig(ok, "short").len > 0
    check checkConfig(ok, "a token with a space inside").len > 0
    check not StoreConfig(kind: "s3").isMirror

  test "D-60 a store's name is lowercase letters, digits and -, starting with a letter":
    for good in ["garage", "caddy-main", "s3", "a"]: check validStoreName(good)
    for bad in ["", "Garage", "1garage", "-a", "a_b", "a b", "x".repeat(33), "_default"]: check not validStoreName(bad)
