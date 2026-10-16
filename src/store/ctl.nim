## `cinim-storectl`: a command-line client of the store nodes (docs/store.md), for what has to move files in and out without the core: the companion container that uploads a backup
## (BKP-003, BKP-005), an operator who looks at a node. It writes to every node and reads from the first that has the object, as the core's mirror does.
##   cinim-storectl put <key> <file>    cinim-storectl get <key> <file>    cinim-storectl ls [prefix]    cinim-storectl rm <key>    cinim-storectl stat    cinim-storectl hash <key>
## CINIM_STORE_NODES (addresses, comma separated), CINIM_STORE_TOKEN or CINIM_STORE_TOKEN_FILE, CINIM_CERTS (the `store` public key and the `client` keypair).
import std/[os, strutils, sequtils]
import ../common/zmqcurve
import ../core/[zstore, storagebackend]

proc fail(msg: string) =
  stderr.writeLine "cinim-storectl: " & msg
  quit 1

proc main() =
  let args = commandLineParams()
  if args.len == 0: fail("put <key> <file> | get <key> <file> | ls [prefix] | rm <key> | stat | hash <key>")
  var token = getEnv("CINIM_STORE_TOKEN")
  if token.len == 0 and getEnv("CINIM_STORE_TOKEN_FILE").len > 0: token = readFile(getEnv("CINIM_STORE_TOKEN_FILE")).strip
  let addrs = getEnv("CINIM_STORE_NODES").split(',').mapIt(it.strip).filterIt(it.len > 0)
  if token.len == 0 or addrs.len == 0: fail("CINIM_STORE_NODES and CINIM_STORE_TOKEN are required")
  let certs = getEnv("CINIM_CERTS", getCurrentDir() / "tests" / "certs")
  var nodes: seq[ZNode]
  let plain = getEnv("CINIM_STORE_TRANSPORT", "curve") == "plain"
  for a in addrs:
    var n = if plain: newNode(a, "", token, (publicKey: "", secretKey: "")) else: newNode(a, loadPublicKey(certs, "store"), token, loadKeypair(certs, "client"))
    n.plain = plain
    nodes.add n
  let b = newMirror(nodes)
  case args[0]
  of "put":
    if args.len != 3: fail("put <key> <file>")
    let size = getFileSize(args[2])
    var f = open(args[2], fmRead)
    defer: f.close()
    if size <= partSize:
      let data = f.readAll()
      let r = b.putObject(args[1], data)
      if not r.ok: fail(r.error)
    else:
      let up = b.createMultipart(args[1])
      if not up.res.ok: fail(up.res.error)
      var parts: seq[(int, string)]
      var buf = newString(partSize)
      var n = 1
      while true:
        let got = f.readBuffer(addr buf[0], partSize)
        if got <= 0: break
        let p = b.uploadPart(args[1], up.uploadId, n, buf[0 ..< got])
        if not p.res.ok:
          discard b.abortMultipart(args[1], up.uploadId)
          fail(p.res.error)
        parts.add (n, p.etag)
        inc n
      let r = b.completeMultipart(args[1], up.uploadId, parts)
      if not r.ok: fail(r.error)
    echo "stored ", args[1], " (", size, " bytes) on ", nodes.len, " node(s)"
  of "get":
    if args.len != 3: fail("get <key> <file>")
    let sz = b.objectSize(args[1])
    if not sz.res.ok: fail(sz.res.error)
    var o = open(args[2], fmWrite)
    defer: o.close()
    var off = 0'i64
    while off < sz.size:
      let r = b.readRange(args[1], off, readSize)
      if not r.res.ok or r.data.len == 0: fail(if r.res.ok: "the object is shorter than it was" else: r.res.error)
      discard o.writeBuffer(unsafeAddr r.data[0], r.data.len)
      off += r.data.len
    echo "read ", args[1], " (", sz.size, " bytes)"
  of "rm":
    if args.len != 2: fail("rm <key>")
    let r = b.deleteObject(args[1])
    if not r.ok: fail(r.error)
    echo "deleted ", args[1]
  of "ls":
    let prefix = if args.len > 1: args[1] else: ""
    var after = ""
    while true:
      let l = nodes[0].nodeList(prefix, after, 500)
      if not l.reply.ok: fail(l.reply.error)
      for e in l.entries: echo e.size, "\t", e.key, (if e.exact: "" else: "\t(shortened)")
      if l.next == "": break
      after = l.next
  of "hash":
    if args.len != 2: fail("hash <key>")
    for n in nodes:
      let h = n.nodeHash(args[1])
      echo n.name, "\t", (if h.reply.ok: h.sha256 else: h.reply.error)
  of "stat":
    for n in nodes:
      let s = n.nodeStats()
      echo n.name, "\t", (if s.reply.ok: $s.free & " free of " & $s.total & " bytes" else: s.reply.error)
  else:
    fail("no such command: " & args[0])

main()
