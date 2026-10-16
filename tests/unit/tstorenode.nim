## D-57 (docs/store.md): a store node's answers to requests, without sockets: the token is needed for everything, every operation does what the table says, limits are kept, and an
## error carries a code the client can act on.
import std/[unittest, os, strutils, options]
import checksums/sha2
import store/[disk, wire, node]

func sha(s: string): string =
  for c in secureHash(Sha_256, s): result.add toHex(ord(c), 2).toLowerAscii

const secret = "a-shared-secret"
let root = getTempDir() / ("tstorenode-" & $getCurrentProcessId())
removeDir(root)
let d = openDisk(root)

proc call(fields: varargs[Field]): Msg =
  var req: Msg
  req.add(tToken, secret)
  for f in fields: req.add f
  handle(d, secret, req)

func ok(m: Msg): bool = m.get(tOk) == "1"

suite "D-57 the node: who may ask":
  test "a request without the token, with a wrong one, or to a node that has none, gets `unauthorized` and nothing is done":
    check handle(d, secret, @[(tOp, "put"), (tKey, "a/b"), (tData, "x")]).get(tCode) == "unauthorized"
    check handle(d, secret, @[(tToken, "wrong"), (tOp, "put"), (tKey, "a/b"), (tData, "x")]).get(tCode) == "unauthorized"
    check handle(d, secret, @[(tToken, secret & "x"), (tOp, "ping")]).get(tCode) == "unauthorized"
    check handle(d, "", @[(tToken, ""), (tOp, "ping")]).get(tCode) == "unauthorized"
    check d.objectSize("a/b").res.code == "not_found"
  test "a ping with the token is ok":
    check call((tOp, "ping")).ok

suite "D-57 the node: operations":
  test "put, size, read, hash, delete":
    check call((tOp, "put"), (tKey, "t/r/f.txt"), (tData, "hello world"), (tSha256, sha("hello world"))).ok
    check call((tOp, "size"), (tKey, "t/r/f.txt")).getInt(tSize) == 11
    let r = call((tOp, "read"), (tKey, "t/r/f.txt"), (tOffset, "6"), (tLength, "5"))
    check r.ok and r.get(tData) == "world" and r.getInt(tSize) == 11
    check call((tOp, "hash"), (tKey, "t/r/f.txt")).get(tSha256) == sha("hello world")
    check call((tOp, "delete"), (tKey, "t/r/f.txt")).ok
    let gone = call((tOp, "size"), (tKey, "t/r/f.txt"))
    check not gone.ok and gone.get(tCode) == "not_found"
    check call((tOp, "delete"), (tKey, "t/r/f.txt")).ok                       # again: not an error
  test "a put with a wrong hash is refused with bad_hash, a bad key with bad_key":
    check call((tOp, "put"), (tKey, "a/b"), (tData, "x"), (tSha256, sha("y"))).get(tCode) == "bad_hash"
    check call((tOp, "put"), (tKey, "a/../b"), (tData, "x")).get(tCode) == "bad_key"
    check call((tOp, "read"), (tKey, "a//b"), (tOffset, "0"), (tLength, "1")).get(tCode) == "bad_key"
  test "a multipart upload: create, parts in any order, complete with the etags and the whole hash":
    let up = call((tOp, "mp_create"), (tKey, "t/r/big"))
    check up.ok
    let id = up.get(tUploadId)
    let b = call((tOp, "mp_part"), (tUploadId, id), (tPart, "2"), (tData, "WORLD"))
    let a = call((tOp, "mp_part"), (tUploadId, id), (tPart, "1"), (tData, "HELLO "))
    check a.get(tEtag) == sha("HELLO ") and b.get(tEtag) == sha("WORLD")
    check call((tOp, "mp_complete"), (tUploadId, id), (tParts, partText(1, a.get(tEtag))), (tParts, partText(2, b.get(tEtag))), (tSha256, sha("HELLO WORLD"))).ok
    check call((tOp, "read"), (tKey, "t/r/big"), (tOffset, "0"), (tLength, "100")).get(tData) == "HELLO WORLD"
    check call((tOp, "mp_complete"), (tUploadId, id), (tParts, "1:x")).get(tCode) == "bad_upload"
    check call((tOp, "mp_complete"), (tUploadId, id), (tParts, "garbage")).get(tCode) == "bad_part"
  test "an abort removes the upload":
    let id = call((tOp, "mp_create"), (tKey, "t/r/gone")).get(tUploadId)
    check call((tOp, "mp_abort"), (tUploadId, id)).ok
    check call((tOp, "mp_part"), (tUploadId, id), (tPart, "1"), (tData, "x")).get(tCode) == "bad_upload"
  test "a list gives entries with sizes, pages by limit, and says where to go on":
    for i in 0 ..< 7: check call((tOp, "put"), (tKey, "list/k" & $i), (tData, "x".repeat(i + 1))).ok
    let p1 = call((tOp, "list"), (tPrefix, "list/"), (tLimit, "3"))
    check p1.ok and p1.all(tEntries).len == 3 and p1.get(tNext) == "list/k2"
    check parseEntry(p1.all(tEntries)[1]).get.size == 2
    let p3 = call((tOp, "list"), (tPrefix, "list/"), (tAfter, "list/k5"), (tLimit, "10"))
    check p3.all(tEntries).len == 1 and p3.get(tNext) == ""
    check call((tOp, "list"), (tPrefix, "list/"), (tLimit, "99999")).all(tEntries).len == 7        # the limit is capped, not refused
  test "stats say how much room there is":
    let s = call((tOp, "stats"))
    check s.ok and s.getInt(tTotal) > 0 and s.getInt(tFree) > 0
  test "an operation nobody knows is refused":
    check call((tOp, "format-the-disk")).get(tCode) == "bad_op"
    check call().get(tCode) == "bad_op"

suite "D-57 the node: limits":
  test "a put over 8 MiB, a part over 16 MiB are refused with too_big":
    check call((tOp, "put"), (tKey, "x/y"), (tData, "z".repeat(maxPutBytes + 1))).get(tCode) == "too_big"
    let id = call((tOp, "mp_create"), (tKey, "x/z")).get(tUploadId)
    check call((tOp, "mp_part"), (tUploadId, id), (tPart, "1"), (tData, "z".repeat(maxPartBytes + 1))).get(tCode) == "too_big"
    check d.objectSize("x/y").res.code == "not_found"
  test "a read is capped at 8 MiB however much is asked":
    check call((tOp, "put"), (tKey, "x/big"), (tData, "q".repeat(maxPutBytes))).ok
    let r = call((tOp, "read"), (tKey, "x/big"), (tOffset, "0"), (tLength, "999999999999"))
    check r.ok and r.get(tData).len == maxReadBytes

removeDir(root)
