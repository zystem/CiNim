## D-57 (docs/store.md): the pure parts of the store on HTTP nodes - how a key becomes a path, the chunk names, the etag of a part, and the reading of the listing a WebDAV node gives
## (the text below is what the module answers to a PROPFIND of an object directory). The nodes themselves are tested in tests/integration/tstorehttp.nim.
import std/[unittest, strutils]
import core/httpstore

const listing = """<?xml version="1.0" encoding="UTF-8"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>/acme/o~obj/</D:href><D:propstat><D:prop><D:displayname>o~obj</D:displayname><D:resourcetype><D:collection xmlns:D="DAV:"/></D:resourcetype><D:getlastmodified>Fri, 16 Oct 2026 16:48:46 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response><D:response><D:href>/acme/o~obj/.c0000001</D:href><D:propstat><D:prop><D:displayname>.c0000001</D:displayname><D:getcontentlength>8</D:getcontentlength><D:resourcetype></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response><D:response><D:href>/acme/o~obj/.c0000000</D:href><D:propstat><D:prop><D:displayname>.c0000000</D:displayname><D:getcontentlength>8388608</D:getcontentlength><D:resourcetype></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>"""

suite "D-57 the store on HTTP nodes, the pure parts":
  test "a path is percent-encoded but for the unreserved characters and the slash":
    check encodePath("/acme/r1/dist/app.txt~obj/.c0000000") == "/acme/r1/dist/app.txt~obj/.c0000000"
    check encodePath("/a b/c%d/e?f#g/ключ") == "/a%20b/c%25d/e%3Ff%23g/%D0%BA%D0%BB%D1%8E%D1%87"
  test "an object is a directory named by the key, with a suffix no escaped segment can have; a chunk is a dot, a c and seven digits":
    check objectDir("acme/s1/x.bin") == "/acme/s1/x.bin~obj"
    check objectDir("a/b") == "/a/b~obj"
    check objectDir("with space/q?") == "/with space/q%3F~obj"
    check objectDir("a%b/~c") == "/a%25b/%7Ec~obj"                                 # a `~` of a key is escaped, so no key ends in `~obj` on its own
    check chunkName(0) == ".c0000000" and chunkName(12) == ".c0000012" and chunkName(9999) == ".c0009999"
    check objectDir("a") != objectDir("a/b") and not objectDir("a/b").startsWith(objectDir("a") & "/")      # one object is never inside another
  test "the etag of a part has its hash and its length":
    let e = etagOf("hello")
    check e == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824-5"
    check etagSize(e) == 5 and etagSize(etagOf("")) == 0 and etagSize("nothing") == -1 and etagSize("x-y") == -1
  test "the listing of an object directory gives the chunks in order, with their sizes":
    let entries = parsePropfind(listing)
    check entries.len == 3 and entries[0].href == "/acme/o~obj/" and entries[0].size == -1 and entries[1].size == 8
    let cs = chunksOf(entries)
    check cs.ok and cs.chunks == @[(0, 8388608'i64), (1, 8'i64)]
  test "a gap in the numbers of the chunks, or no chunk, is seen":
    let gap = chunksOf(@[("/o~obj/.c0000000", 5'i64), ("/o~obj/.c0000002", 5'i64)])
    check not gap.ok
    let noZero = chunksOf(@[("/o~obj/.c0000001", 5'i64)])
    check not noZero.ok
    let none = chunksOf(@[("/o~obj/", -1'i64), ("/o~obj/stray.txt", 3'i64), ("/o~obj/.c12", 3'i64), ("/o~obj/.cabcdefg", 3'i64)])
    check none.ok and none.chunks.len == 0                                         # files that are not chunks are not counted
  test "an address becomes the id of the node, host and port, with the default port when none is given":
    check newHttpNode("http://store-0.store:8080", "s").name == "store-0.store:8080"
    check newHttpNode("https://store-1.store", "s").name == "store-1.store:443"
    check newHttpNode("http://10.0.0.5/", "s").name == "10.0.0.5:80"
    let p = newHttpNode("https://host:8443/share/", "s")
    check p.prefix == "/share" and p.port == 8443 and p.scheme == "https"
