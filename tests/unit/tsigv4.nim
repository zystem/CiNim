## SigV4 presigned URLs (DAT-003): the example of the AWS documentation, and the shape of what the platform signs.
import std/[unittest, strutils]
import common/sigv4

suite "DAT-003 SigV4 presigned URLs":
  test "DAT-003 the AWS documentation's example (GET /test.txt, 2013-05-24, 86400 s) gives its signature":
    let q = presignQuery("GET", "examplebucket.s3.amazonaws.com", "/test.txt", "us-east-1", "AKIAIOSFODNN7EXAMPLE",
                         "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "20130524T000000Z", 86400)
    check q.endswith("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    check "X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" in q

  test "DAT-003 the method is part of the signature: PUT and GET of one object differ":
    let g = presignObject("GET", "http://garage:3900", "b", "runs/r1/a.txt", "garage", "K", "S", 1000, 60)
    let p = presignObject("PUT", "http://garage:3900", "b", "runs/r1/a.txt", "garage", "K", "S", 1000, 60)
    check g.startsWith("http://garage:3900/b/runs/r1/a.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256")
    check g.split("X-Amz-Signature=")[1] != p.split("X-Amz-Signature=")[1]

  test "DAT-003 a name with spaces and non-ASCII is encoded in the path, and the same key signs the same way every time":
    let a = presignObject("GET", "http://s:1", "b", "dir/a b/é.txt", "r", "K", "S", 5, 60)
    check a.startsWith("http://s:1/b/dir/a%20b/%C3%A9.txt?")
    check a == presignObject("GET", "http://s:1", "b", "dir/a b/é.txt", "r", "K", "S", 5, 60)

  test "DAT-003 the endpoint is a scheme and a host, nothing else":
    check splitEndpoint("http://garage:3900").host == "garage:3900"
    check splitEndpoint("https://s3.example.com/").host == "s3.example.com"
    for bad in ["garage:3900", "ftp://x", "http://", "http://a/b", "http://a b", ""]:
      check not splitEndpoint(bad).ok

  test "DAT-003 the time stamp":
    check amzDate(1369353600) == "20130524T000000Z"
