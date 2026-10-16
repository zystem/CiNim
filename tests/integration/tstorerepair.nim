## DAT-003, D-57 (docs/store.md): keeping the two store nodes alike - the repair queue in the database, its pass over real nodes, the pause after a failure, and the check of the rows of
## `artifacts` and `caches` against the nodes. Real node processes (build/cinim-store) and a real rqlite. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, osproc, strutils, strtabs, sequtils, times, locks]
import common/[rqlite, zmqcurve]
import core/[schema, zstore, storagebackend, storerepair]
import store/disk

const port1 = 29863
const port2 = 29864
const token = "a-token-for-the-repair-test"
let url = getEnv("CINIM_RQLITE_URL")
let certs = getCurrentDir() / "tests" / "certs"

suite "D-57 the repair of the store":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    check execCmd("nim c --hints:off --warnings:off -p:src --threads:on --outdir:build -o:build/cinim-store src/store/main.nim") == 0
    let binary = getCurrentDir() / "build" / "cinim-store"
    let base = getTempDir() / ("tstorerepair-" & $getCurrentProcessId())
    removeDir(base)
    proc startNode(root: string; port: int): Process =
      let env = newStringTable()
      for k, v in envPairs(): env[k] = v
      env["CINIM_STORE_ROOT"] = root
      env["CINIM_CERTS"] = certs
      env["CINIM_STORE_PORT"] = $port
      env["CINIM_STORE_TOKEN"] = token
      result = startProcess(binary, env = env, options = {poStdErrToStdOut})
      sleep 700
    proc stop(p: Process) =
      p.terminate()
      discard p.waitForExit(5000)
      p.close()
    proc node(port: int; timeoutMs = 20000): ZNode =
      newNode("tcp://127.0.0.1:" & $port, loadPublicKey(certs, "store"), token, loadKeypair(certs, "client"), timeoutMs)
    var p1 = startNode(base / "n1", port1)
    var p2 = startNode(base / "n2", port2)
    let d1 = openDisk(base / "n1")
    let d2 = openDisk(base / "n2")
    var c = newRq(url)
    migrate(c)
    let sfx = newId()[^8 .. ^1].toLowerAscii
    let now = getTime().toUnix()
    var hookLock: Lock
    initLock(hookLock)
    proc hook(key, nodeName, what: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        var hc = newRq(url)
        withLock hookLock: hc.noteMissed(key, nodeName, what, getTime().toUnix())
    proc addArtifact(key: string; size: int; state = "stored") =
      discard c.execute(%*[["INSERT INTO artifacts (id, tenant_id, run_id, step_ordinal, path, s3_key, size, sha256, state, created_at) VALUES (?, 't', ?, 0, ?, ?, ?, 'x', ?, ?)",
        newId(), "run-" & sfx, key, key, size, state, now]])
    proc taskOf(key: string): seq[string] =
      let v = c.query(%*[["SELECT op, attempts, next_at FROM store_repair WHERE key = ?", key]])["results"][0]{"values"}
      if v != nil and v.len > 0: @[v[0][0].getStr, $v[0][1].getInt, $v[0][2].getInt] else: @[]
    let a = node(port1)
    let b = node(port2)

    test "a write that a node missed is queued, and the pass gives it to the node when it is back":
      p2.stop()
      let m = newMirror(@[node(port1), node(port2, 1000)], 1, hook)               # the degraded mode: one ack is enough
      let key = "t/rp-" & sfx & "/one"
      check m.putObject(key, "given to the first node only").ok
      addArtifact(key, 27)
      check taskOf(key)[0] == "copy"
      p2 = startNode(base / "n2", port2)
      let mir = newMirror(@[a, b])
      let rep = c.repairPass(mir, now + 1)
      check rep.copied >= 1
      check d2.readRange(key, 0, 100).data == "given to the first node only"
      check taskOf(key).len == 0
    test "the last operation on a key and a node wins: a delete that is followed by a write is a copy":
      let key = "t/rp-" & sfx & "/last"
      c.noteMissed(key, b.name, "delete", now)
      check taskOf(key)[0] == "delete"
      c.noteMissed(key, b.name, "copy", now + 1)
      check taskOf(key)[0] == "copy"
    test "a delete task deletes on the node and goes":
      let key = "t/rp-" & sfx & "/gone"
      check a.nodePut(key, "x").ok and b.nodePut(key, "x").ok
      c.noteMissed(key, b.name, "delete", now)
      let rep = c.repairPass(newMirror(@[a, b]), now + 1)
      check rep.deleted >= 1 and d2.objectSize(key).res.code == "not_found" and d1.objectSize(key).res.ok and taskOf(key).len == 0
    test "a copy of an object that is not in the database any more is dropped, not made":
      let key = "t/rp-" & sfx & "/swept"
      check a.nodePut(key, "x").ok
      c.noteMissed(key, b.name, "copy", now)                                   # no row for it
      let rep = c.repairPass(newMirror(@[a, b]), now + 1)
      check rep.dropped >= 1 and d2.objectSize(key).res.code == "not_found" and taskOf(key).len == 0
    test "a copy that cannot be made waits, with a pause that grows, and is tried again":
      let key = "t/rp-" & sfx & "/nowhere"
      addArtifact(key, 5)
      c.noteMissed(key, b.name, "copy", now)                                   # neither node has it
      let mir = newMirror(@[a, b])
      let t = now + 1000
      check c.repairPass(mir, t).failed >= 1
      let first = taskOf(key)
      check first[1] == "1" and parseInt(first[2]) >= t + 30
      check c.repairPass(mir, t + 1).failed == 0                               # not due yet
      check c.repairPass(mir, t + 100).failed >= 1
      check taskOf(key)[1] == "2" and parseInt(taskOf(key)[2]) >= t + 100 + 60
      check a.nodePut(key, "12345").ok                                         # the object appears on a node: the next try gives it to the other
      check c.repairPass(mir, t + 10000).copied >= 1 and d2.objectSize(key).size == 5 and taskOf(key).len == 0
    test "a task for a node that is not in the settings is dropped":
      let key = "t/rp-" & sfx & "/stranger"
      c.noteMissed(key, "tcp://10.9.9.9:1", "copy", now)
      check c.repairPass(newMirror(@[a, b]), now + 1).dropped >= 1 and taskOf(key).len == 0
    test "the check of the rows makes a copy task for what a node lacks or has with another size, and for nothing else":
      let pre = "t/rc-" & sfx & "/"
      for (name, onA, onB) in [("both", "same", "same"), ("only-a", "from a", ""), ("short-on-b", "full size", "short"), ("only-b", "", "from b")]:
        let key = pre & name
        if onA.len > 0: check a.nodePut(key, onA).ok
        if onB.len > 0: check b.nodePut(key, onB).ok
        addArtifact(key, max(onA.len, onB.len))
      addArtifact(pre & "nowhere", 9)                                          # nobody has it: nothing to copy from, no task
      var cursor = pre
      cursor.setLen cursor.len - 1                                              # the cursor is "the key before": the check starts at the first key of the prefix
      var made = 0
      for _ in 0 ..< 20:
        made += c.checkNodes(newMirror(@[a, b]), cursor, now, slice = 2)
        if cursor == "" or cursor > pre & "~": break
      check taskOf(pre & "only-a")[0] == "copy" and taskOf(pre & "short-on-b")[0] == "copy" and taskOf(pre & "only-b")[0] == "copy"
      check taskOf(pre & "both").len == 0 and taskOf(pre & "nowhere").len == 0
      check made >= 3
    test "the check looks at the rows of caches too":
      let key = "t/cache/_/" & sfx
      check a.nodePut(key, "cache bytes").ok
      discard c.execute(%*[["INSERT INTO caches (id, tenant_id, scope, key, s3_key, size, sha256, state, upload_id, created_at, last_used_at) VALUES (?, 't', '', ?, ?, 11, 'x', 'stored', '', ?, ?)", newId(), "k-" & sfx, key, now, now]])
      var cursor = "t/cache/_/" & sfx[0 ..< 7]
      discard c.checkNodes(newMirror(@[a, b]), cursor, now, slice = 50)
      check taskOf(key)[0] == "copy"
    test "one node is no mirror: the check makes no tasks":
      var cursor = ""
      check c.checkNodes(newMirror(@[a]), cursor, now) == 0
    p1.stop()
    p2.stop()
    removeDir(base)
