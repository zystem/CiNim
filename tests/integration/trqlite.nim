## Spike 1 against a real rqlite cluster (7.2 [M0-CHECK]).
## Needs CINIM_RQLITE_URL (port-forward to a FOLLOWER) and CINIM_KUBECTL
## (e.g. "kubectl --context admin@home -n rqlite"); otherwise the suite is skipped.
import std/[unittest, json, os, osproc, times, algorithm, sets, strutils, typedthreads, tables]
import common/rqlite

let url = getEnv("CINIM_RQLITE_URL")
let kubectl = getEnv("CINIM_KUBECTL")

proc pct(xs: seq[float]; p: float): float =
  let s = xs.sorted
  s[min(s.high, int(float(s.len) * p))]

proc report(name: string; v: string) = echo "  METRIC ", name, " = ", v

type ClaimArgs = tuple[url, ctrl: string; claimed: ptr seq[int]]

proc claimer(a: ClaimArgs) {.thread.} =
  var c = newRq(a.url)
  while true:
    let r = c.execute(%*[["UPDATE steps SET state='dispatched', controller_id=?, pod_name='pod-'||id, version=version+1 " &
      "WHERE id=(SELECT id FROM steps WHERE state='queued' AND profile_id='p' ORDER BY priority DESC, queued_at LIMIT 1) " &
      "AND state='queued' RETURNING id", a.ctrl]])
    let vals = r["results"][0]{"values"}
    if vals == nil or vals.len == 0: break
    a.claimed[].add vals[0][0].getInt

proc setupSteps(c: var RqClient; n: int) =
  discard c.execute(%*["DROP TABLE IF EXISTS steps",
    "CREATE TABLE steps(id INTEGER PRIMARY KEY, state TEXT, profile_id TEXT, priority INT, queued_at INT, controller_id TEXT, pod_name TEXT, version INT DEFAULT 0)"])
  var stmts = newJArray()
  for i in 1 .. n:
    stmts.add %*[ "INSERT INTO steps(state,profile_id,priority,queued_at) VALUES ('queued','p',?,?)", i mod 5, i]
  discard c.execute(stmts, transaction = true)

suite "7.2 rqlite as state store [M0-CHECK]":
  if url.len == 0:
    test "skipped: CINIM_RQLITE_URL not set":
      skip()
  else:
    test "7.2 concurrent claim: every queued step is claimed exactly once":
      var c = newRq(url)
      setupSteps(c, 300)
      var results: array[8, seq[int]]
      var ths: array[8, Thread[ClaimArgs]]
      let t0 = epochTime()
      for i in 0 ..< 8: createThread(ths[i], claimer, (url, "ctrl" & $i, addr results[i]))
      joinThreads(ths)
      let dt = epochTime() - t0
      var all = initHashSet[int]()
      var total = 0
      for r in results:
        for id in r:
          inc total
          all.incl id
      check total == 300
      check all.len == 300   # no id claimed twice
      report "claim_300_steps_8_clients_s", dt.formatFloat(ffDecimal, 2)
      let q = c.query(%*["SELECT count(*) FROM steps WHERE state='queued'"])
      check q["results"][0]["values"][0][0].getInt == 0

    test "7.2 CAS on version: of two racing writers exactly one wins":
      var c = newRq(url)
      setupSteps(c, 1)
      let a = c.execute(%*[["UPDATE steps SET state='running', version=version+1 WHERE id=1 AND version=?", 0]])
      let b = c.execute(%*[["UPDATE steps SET state='cancelled', version=version+1 WHERE id=1 AND version=?", 0]])
      check a["results"][0]{"rows_affected"}.getInt(0) == 1
      check b["results"][0]{"rows_affected"}.getInt(0) == 0  # rqlite omits the field at 0

    test "7.2 journal batch and state change commit atomically":
      var c = newRq(url)
      discard c.execute(%*["DROP TABLE IF EXISTS journal", "CREATE TABLE journal(run INT, seq INT, body TEXT, PRIMARY KEY(run, seq))"])
      setupSteps(c, 1)
      # the last statement violates the primary key: nothing of the batch may persist
      discard c.execute(%*["INSERT INTO journal VALUES (1, 0, 'x')"])
      var failed = false
      try:
        discard c.execute(%*[["UPDATE steps SET state='done', version=version+1 WHERE id=1"],
          ["INSERT INTO journal VALUES (1, 1, 'y')"], ["INSERT INTO journal VALUES (1, 0, 'dup')"]], transaction = true)
      except RqError: failed = true
      check failed
      let s = c.query(%*["SELECT state FROM steps WHERE id=1", "SELECT count(*) FROM journal"])
      check s["results"][0]["values"][0][0].getStr == "queued"
      check s["results"][1]["values"][0][0].getInt == 1

    test "7.2 batching raises write throughput by an order of magnitude":
      var c = newRq(url)
      discard c.execute(%*["DROP TABLE IF EXISTS bench", "CREATE TABLE bench(id INTEGER PRIMARY KEY, v TEXT)"])
      var t0 = epochTime()
      for i in 1 .. 100: discard c.execute(%*[["INSERT INTO bench(v) VALUES (?)", "single" & $i]])
      let single = 100.0 / (epochTime() - t0)
      t0 = epochTime()
      for batch in 1 .. 20:
        var stmts = newJArray()
        for i in 1 .. 500: stmts.add %*[ "INSERT INTO bench(v) VALUES (?)", "b" & $i]
        discard c.execute(stmts, transaction = true)
      let bulk = 10000.0 / (epochTime() - t0)
      report "single_writes_per_s", single.formatFloat(ffDecimal, 0)
      report "bulk_rows_per_s_500_per_request", bulk.formatFloat(ffDecimal, 0)
      check bulk > single * 10

    test "7.2 VACUUM and sustained writes: record the worst write stall":
      var c = newRq(url)
      discard c.execute(%*["DROP TABLE IF EXISTS big", "CREATE TABLE big(id INTEGER PRIMARY KEY, v TEXT)"])
      for batch in 1 .. 40:  # ~20 MB
        var stmts = newJArray()
        for i in 1 .. 500: stmts.add %*[ "INSERT INTO big(v) VALUES (?)", 'x'.repeat(1000)]
        discard c.execute(stmts, transaction = true)
      discard c.execute(%*["DELETE FROM big WHERE id % 2 = 0"])
      var lat = newSeq[float]()
      var vac: Thread[string]
      proc vacuumer(u: string) {.thread.} =
        var cc = newRq(u, 120000)
        discard cc.execute(%*["VACUUM"])
      createThread(vac, vacuumer, url)
      let t0 = epochTime()
      while epochTime() - t0 < 6.0:
        let s = epochTime()
        discard c.execute(%*[["INSERT INTO bench(v) VALUES (?)", "during"]])
        lat.add (epochTime() - s) * 1000
      joinThread(vac)
      report "write_ms_p50", pct(lat, 0.5).formatFloat(ffDecimal, 1)
      report "write_ms_p99", pct(lat, 0.99).formatFloat(ffDecimal, 1)
      report "write_ms_max_during_vacuum", lat.max.formatFloat(ffDecimal, 1)
      check lat.len > 0

    test "7.2 leader killed during writes: no acknowledged write is lost":
      var c = newRq(url)
      discard c.execute(%*["DROP TABLE IF EXISTS acked", "CREATE TABLE acked(id INTEGER PRIMARY KEY)"])
      let leader = c.leaderId()
      report "leader_before", leader
      var acked = newSeq[int]()
      var ackInfo = initTable[int, string]()
      var i = 0
      var killed = false
      var killAt, lastAck, maxGap = 0.0
      let t0 = epochTime()
      while true:
        inc i
        if i == 60 and not killed:
          discard execCmd(kubectl & " delete pod " & leader & " --grace-period=0 --force")
          killed = true
          killAt = epochTime()
          lastAck = killAt
        try:
          let resp = c.execute(%*[["INSERT INTO acked(id) VALUES (?)", i]])
          if resp["results"].len != 1 or resp["results"][0]{"rows_affected"}.getInt(0) != 1:
            echo "  SUSPICIOUS ack id=", i, " resp=", $resp  # 200 without an applied row
            continue
          acked.add i
          ackInfo[i] = $resp["results"][0] & " t=" & (epochTime() - t0).formatFloat(ffDecimal, 2) &
            (if killed: " after_kill" else: "")
          if killed:
            maxGap = max(maxGap, epochTime() - lastAck)
            lastAck = epochTime()
        except CatchableError:
          discard  # not acknowledged: allowed to be absent
        if killed and epochTime() - killAt > 15.0: break
        if epochTime() - t0 > 90.0: break
      let maxStall = maxGap  # longest gap between two acknowledged writes after the kill
      check killed
      var have = initHashSet[int]()
      var q: JsonNode
      for attempt in 1 .. 30:
        try:
          q = c.query(%*["SELECT id FROM acked"]); break
        except CatchableError: sleep 1000
      for row in q["results"][0]{"values"}: have.incl row[0].getInt
      var lost = 0
      for a in acked:
        if a notin have:
          inc lost
          echo "  LOST id=", a, " resp=", ackInfo[a]
      report "acked_writes", $acked.len
      report "lost_acked_writes", $lost
      report "max_gap_between_acked_writes_s", maxStall.formatFloat(ffDecimal, 2)
      report "leader_after", c.leaderId()
      check lost == 0
