## StateStore contract (D-21, DAT-010): the same behaviour for the in-memory store and for rqlite (the production store of the shard).
## Needs CINIM_RQLITE_URL for the rqlite part (see tools/m0/pf-follower.sh).
import std/[unittest, os, options, json, strutils, times]
import core/[logcircuit, rqlitestore]

proc contract(st: StateStore; label: string) =
  test label & ": create, get, update with the right revision":
    let rev = st.create("k1", "v1")
    check st.get("k1") == ("v1", rev)
    let rev2 = st.update("k1", "v2", rev)
    check rev2 == rev + 1 and st.get("k1") == ("v2", rev2)

  test label & ": create of an existing key and update with a stale revision conflict":
    let rev = st.create("k2", "a")
    expect StoreConflict: discard st.create("k2", "b")
    discard st.update("k2", "b", rev)
    expect StoreConflict: discard st.update("k2", "c", rev)          # the stale revision loses
    check st.get("k2")[0] == "b"

  test label & ": a missing key is reported as not found":
    expect StoreNotFound: discard st.get("no-such-key")
    expect StoreNotFound: discard st.update("no-such-key", "x", 1)

  test label & ": keys by prefix":
    for k in ["p/1", "p/2", "q/1"]: discard st.create(k, "x")
    check st.keys("p/").len == 2

  test label & ": two coordinators racing for a promotion, exactly one wins":
    let cfg = Config(failThreshold: 3, maxLag: 1000, promoteCooldown: 60.0, pollInterval: 2.0, gateMaxLag: 100_000)
    discard st.initCluster("a", 0.0)
    let statuses = [NodeStatus(name: "a", failures: 3, lastSeen: 1.0), NodeStatus(name: "b", lastSeen: 1.0, stream: StreamStatus(connected: true))]
    var wins = 0
    for _ in 0 ..< 2:
      let (cl, rev) = st.loadCluster()
      let p = decideFailover(cl, statuses, 1000.0, cfg)
      if p.isSome and st.tryPromote(cl, rev, p.get, 1000.0): inc wins
    check wins == 1
    check st.loadCluster()[0].master == "b" and st.history().len == 1

suite "StateStore contract":
  contract(newMemStore(), "memory")
  let url = getEnv("CINIM_RQLITE_URL")
  if url.len > 0:
    let table = "kv_test_" & $getTime().toUnix()
    contract(newRqliteStore(url, table), "rqlite")
    test "cleanup":
      dropTable(url, table)
  else:
    test "rqlite part skipped: CINIM_RQLITE_URL not set":
      skip()
