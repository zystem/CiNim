## The object store of the shard (DAT-003, D-46): the settings, the paths and keys of artifacts, what a step declared.
import std/[unittest, strutils]
import core/[objectstore, s3backend, artifactingest]

suite "DAT-003 the object store's rules":
  test "DAT-003 the settings are checked before they are kept":
    let ok = StoreConfig(found: true, endpoint: "http://garage:3900", region: "garage", bucket: "cinim-artifacts", keyId: "GK123")
    check checkConfig(ok, "secret") == ""
    check checkConfig(StoreConfig(found: true, endpoint: "garage", region: "garage", bucket: "cinim-artifacts", keyId: "k"), "s").contains("endpoint")
    check checkConfig(StoreConfig(found: true, endpoint: "http://g:1/x", region: "garage", bucket: "cinim-artifacts", keyId: "k"), "s").contains("endpoint")
    check checkConfig(StoreConfig(found: true, endpoint: "http://g:1", region: "", bucket: "cinim-artifacts", keyId: "k"), "s").contains("region")
    check checkConfig(StoreConfig(found: true, endpoint: "http://g:1", region: "r", bucket: "Bad Bucket", keyId: "k"), "s").contains("bucket")
    check checkConfig(StoreConfig(found: true, endpoint: "http://g:1", region: "r", bucket: "ab", keyId: "k"), "s").contains("bucket")
    check checkConfig(ok, "").contains("secret")
    check checkConfig(ok, "with space").contains("secret")

  test "DAT-003 an artifact's path is relative and inside the workspace":
    for good in ["a", "dist/app.tar.gz", "a b/c.txt", "deep/er/path/x.y"]:
      check cleanPath(good) == good
    for bad in ["", "/etc/passwd", "../x", "a/../b", "a//b", "./a", "a/./b", "dir/", "a\\b", "a\nb", "a\x00b", "x".repeat(513)]:
      check cleanPath(bad) == ""

  test "DAT-003 an object's key holds the tenant and the run, so one organisation's key is never another's":
    check objectKey("org1", "s1_run", "dist/a") == "org1/s1_run/dist/a"
    check objectKey("org1", "s1_run", "x") != objectKey("org2", "s1_run", "x")

  test "DAT-003 what the step declared is read from its options":
    let d = artifactDecl("""{"artifacts":{"download":["app"],"upload":["dist/**","a"]},"timeout":60}""")
    check d.upload == @["dist/**", "a"] and d.download == @["app"]
    check hasArtifacts("""{"artifacts":{"upload":["a"]}}""")
    check not hasArtifacts("""{"timeout":60}""")
    check not hasArtifacts("")
    check not hasArtifacts("{broken")
    check not hasArtifacts("""{"artifacts":"x"}""")

suite "DAT-003 the S3 backend's pieces and the step's rights":
  test "DAT-003 the body of CompleteMultipartUpload lists the parts in order with quoted ETags":
    let x = completeXml(@[(1, "\"aa\""), (2, "bb")])
    check x == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"aa\"</ETag></Part><Part><PartNumber>2</PartNumber><ETag>\"bb\"</ETag></Part></CompleteMultipartUpload>"

  test "DAT-003 the upload id and the error of a store's answer are read from its XML":
    check tagText("<InitiateMultipartUploadResult><Bucket>b</Bucket><UploadId>abc123</UploadId></InitiateMultipartUploadResult>", "UploadId") == "abc123"
    check tagText("<x/>", "UploadId") == ""
    check s3Error(403, "<Error><Code>AccessDenied</Code><Message>no</Message></Error>") == "the store answered 403 AccessDenied: no"
    check s3Error(500, "") == "the store answered 500"

  test "DAT-003 a step may read what its download list names, a directory's contents included, and nothing else":
    check coveredBy(@["dist"], "dist") and coveredBy(@["dist"], "dist/sub/a.txt")
    check not coveredBy(@["dist"], "distribution/a") and not coveredBy(@["dist/a"], "dist/b") and not coveredBy(@[], "x")
