## DAT-003, D-57 (docs/store.md): keeping two HTTP store nodes alike - the repair queue in the database and its pass over real nodes (`build/caddy-store`), the pause after a failure, and the check of
## the rows of `artifacts` and `caches` against the nodes, through the code of the module (storage/repair.nim, storage/replicas.nim). Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, osproc, strutils, strtabs, sequtils, times, locks, net]
import common/[rqlite, httpsrv]
import storage/[schema, httpstore, repair, storeauth]
import common/storagebackend

const
  port1 = 29874
  port2 = 29875
  authPort = 29876
  secret = "a-secret-for-the-http-repair-test"
let url = getEnv("CINIM_RQLITE_URL")

proc onAuth() {.gcsafe, nimcall, raises: [].} =
  {.cast(gcsafe).}:
    try:
      if getUri().startsWith(authPath) and storeAuthOk(getRequest(), getUri(), secret, epochTime().int64): reply(Http200, "ok") else: reply(Http401, "no")
    except CatchableError: reply(Http500, "error")

suite "D-57 the repair of the HTTP store (the module)":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  elif not fileExists("build/caddy-store") and execCmd("tools/store/build-caddy.sh") != 0:
    echo "  skipped: no build/caddy-store and it could not be made (it needs Docker and the network)"
  else:
    let caddy = getCurrentDir() / "build" / "caddy-store"
    let base = getTempDir() / ("tstorehttprepair-" & $getCurrentProcessId())
    removeDir(base)
    createDir(base)
    let authService = newService(onAuth)
    authService.start(authPort, 2)
    proc listening(port: int): bool =
      try:
        let s = newSocket()
        s.connect("127.0.0.1", Port(port), 200)
        s.close()
        true
      except OSError: false
    proc startNode(root: string; port: int): Process =
      if listening(port): quit "something listens on " & $port & " already (a node of an earlier run?)"
      createDir(root)
      let file = base / ("Caddyfile-" & $port)
      writeFile(file, "{\n\torder webdav before file_server\n\tauto_https off\n\tadmin off\n}\n:" & $port & " {\n\tforward_auth 127.0.0.1:" & $authPort & " {\n\t\turi " & authPath &
        "?node=127.0.0.1:" & $port & "\n\t}\n\twebdav {\n\t\troot " & root & "\n\t\tatomic_put\n\t\tcreate_dirs\n\t}\n}\n")
      let env = newStringTable()
      for k, v in envPairs(): env[k] = v
      env["XDG_DATA_HOME"] = base / "xdg"
      env["XDG_CONFIG_HOME"] = base / "xdgc"
      result = startProcess("/bin/sh", args = ["-c", "exec " & caddy & " run --config " & file & " --adapter caddyfile > " & base / ("caddy-" & $port & ".log") & " 2>&1"], env = env)     # the log goes to a file: an unread pipe fills up and stops the node
      for _ in 0 ..< 100:
        if listening(port): return
        sleep 100
      quit "the node on " & $port & " did not start"
    proc stop(p: Process) =
      p.terminate()
      discard p.waitForExit(5000)
      p.close()
    proc node(port: int; timeoutMs = 15000): HttpNode = newHttpNode("http://127.0.0.1:" & $port, secret, timeoutMs)
    var p1 = startNode(base / "n1", port1)
    var p2 = startNode(base / "n2", port2)
    var c = newRq(url)
    migrate(c)
    let sfx = $getCurrentProcessId()
    let store = "repairtest"
    discard c.execute(%*[["DELETE FROM storage_objects WHERE store = ?", store], ["DELETE FROM storage_repair WHERE store = ?", store]])
    let now = getTime().toUnix()
    var hookLock: Lock
    initLock(hookLock)
    proc hook(key, nodeName, what: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        var hc = newRq(url)
        withLock hookLock: hc.noteMissed(store, key, nodeName, what, getTime().toUnix())
    proc addArtifact(key: string; size: int; state = "stored") = c.recordObject(store, key, size, now)
    proc taskOf(key: string): seq[string] =
      let v = c.query(%*[["SELECT op, attempts, next_at FROM storage_repair WHERE store = ? AND key = ?", store, key]])["results"][0]{"values"}
      if v != nil and v.len > 0: @[v[0][0].getStr, $v[0][1].getInt, $v[0][2].getInt] else: @[]
    let a = node(port1)
    let b = node(port2)
    let a2 = newHttpMirror(@[a])
    let b2 = newHttpMirror(@[b])
    let bothNodes = newHttpMirror(@[a, b])

    test "a write that a node missed is queued, and the pass gives it to the node when it is back":
      p2.stop()
      let m = newHttpMirror(@[node(port1), node(port2, 1000)], 1, hook)               # the degraded mode: one ack is enough
      let key = "t/rp-" & sfx & "/one"
      check m.putObject(key, "given to the first node only").ok
      addArtifact(key, 27)
      check taskOf(key)[0] == "copy"
      p2 = startNode(base / "n2", port2)
      let rep = c.repairPass(store, bothNodes, now + 1)
      check rep.copied >= 1
      check b2.readRange(key, 0, 100).data == "given to the first node only"
      check taskOf(key).len == 0
    test "an object of several chunks is copied by chunks and read back whole":
      let key = "t/rp-" & sfx & "/parts"
      var data = newString(partSize + 5000)
      for i in 0 ..< data.len: data[i] = char(i * 7 mod 251)
      let up = a2.createMultipart(key)
      let p1r = a2.uploadPart(key, up.uploadId, 1, data[0 ..< partSize])
      let p2r = a2.uploadPart(key, up.uploadId, 2, data[partSize .. ^1])
      check a2.completeMultipart(key, up.uploadId, @[(1, p1r.etag), (2, p2r.etag)]).ok
      addArtifact(key, data.len)
      c.noteMissed(store, key, b.name, "copy", now)
      check c.repairPass(store, bothNodes, now + 1).copied >= 1
      check b2.objectSize(key).size == data.len
      check b2.readRange(key, partSize - 3, 6).data == data[partSize - 3 ..< partSize + 3]
    test "the last operation on a key and a node wins: a delete that is followed by a write is a copy":
      let key = "t/rp-" & sfx & "/last"
      c.noteMissed(store, key, b.name, "delete", now)
      check taskOf(key)[0] == "delete"
      c.noteMissed(store, key, b.name, "copy", now + 1)
      check taskOf(key)[0] == "copy"
    test "a delete task deletes on the node and goes":
      let key = "t/rp-" & sfx & "/gone"
      check a2.putObject(key, "x").ok and b2.putObject(key, "x").ok
      c.noteMissed(store, key, b.name, "delete", now)
      let rep = c.repairPass(store, bothNodes, now + 1)
      check rep.deleted >= 1 and b2.objectSize(key).res.ok == false and a2.objectSize(key).res.ok and taskOf(key).len == 0
    test "a copy of an object that is not in the inventory any more is dropped, not made":
      let key = "t/rp-" & sfx & "/swept"
      check a2.putObject(key, "x").ok
      c.noteMissed(store, key, b.name, "copy", now)                                   # no inventory row for it
      let rep = c.repairPass(store, bothNodes, now + 1)
      check rep.dropped >= 1 and not b2.objectSize(key).res.ok and taskOf(key).len == 0
    test "a copy that cannot be made waits, with a pause that grows, and is tried again":
      let key = "t/rp-" & sfx & "/nowhere"
      addArtifact(key, 5)
      c.noteMissed(store, key, b.name, "copy", now)                                   # neither node has it
      let t = now + 1000
      check c.repairPass(store, bothNodes, t).failed >= 1
      let first = taskOf(key)
      check first[1] == "1" and parseInt(first[2]) >= t + 30
      check c.repairPass(store, bothNodes, t + 1).failed == 0                         # not due yet
      check c.repairPass(store, bothNodes, t + 100).failed >= 1
      check a2.putObject(key, "12345").ok                                      # the object appears on a node: the next try gives it to the other
      check c.repairPass(store, bothNodes, t + 10000).copied >= 1 and b2.objectSize(key).size == 5 and taskOf(key).len == 0
    test "the check of the rows makes a copy task for what a node lacks or has with another size, and for nothing else":
      let pre = "t/rc-" & sfx & "/"
      for (name, onA, onB) in [("both", "same", "same"), ("only-a", "from a", ""), ("short-on-b", "full size", "short"), ("only-b", "", "from b")]:
        let key = pre & name
        if onA.len > 0: check a2.putObject(key, onA).ok
        if onB.len > 0: check b2.putObject(key, onB).ok
        addArtifact(key, max(onA.len, onB.len))
      addArtifact(pre & "nowhere", 9)                                          # nobody has it: nothing to copy from, no task
      var cursor = pre
      cursor.setLen cursor.len - 1
      var made = 0
      for _ in 0 ..< 20:
        made += c.checkNodes(store, bothNodes, cursor, now, slice = 2)
        if cursor == "" or cursor > pre & "~": break
      check taskOf(pre & "only-a")[0] == "copy" and taskOf(pre & "short-on-b")[0] == "copy" and taskOf(pre & "only-b")[0] == "copy"
      check taskOf(pre & "both").len == 0 and taskOf(pre & "nowhere").len == 0
      check made >= 3
    test "one node is no mirror: the check makes no tasks":
      var cursor = ""
      check c.checkNodes(store, a2, cursor, now) == 0
    p1.stop()
    p2.stop()
    shutdown()
    removeDir(base)
