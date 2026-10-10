## T-03, PIP-003 (docs/conductors.md section 7): the core computes and stores the hash chain of a run's journal and checks it at every lease, so
## that the party that may be hostile (an executor in a tenant's namespace) does not keep the history. Pure.
import std/[unittest, strutils]
import executor/journal
import core/journalchain

proc rows(n: int): seq[Row] =
  ## a journal of n entries as the core would have stored it
  var prev = ""
  for i in 0 ..< n:
    var r = Row(seq: i, kind: (if i == 0: "params" else: "job_sh"), payload: "payload-" & $i, result: "result-" & $i)
    r.hash = chainHash(prev, r)
    prev = r.hash
    result.add r

suite "T-03 the hash chain computed by the core":
  test "it is the very chain the executor builds, so an executor can check what the core stored":
    var j = Journal()
    let rs = rows(4)
    for r in rs: discard j.append(r.kind, r.payload, r.result)
    for i, r in rs: check r.hash == j.entries[i].hash
  test "a journal that was written properly is whole":
    let rs = rows(5)
    check checkChain(rs, rs[^1].hash).verdict == cvOk
  test "a run with nothing in the journal is whole with no tip":
    check checkChain(@[], "").verdict == cvOk

suite "T-03 what the check finds":
  test "a changed result, payload or kind":
    for field in ["result", "payload", "kind"]:
      var rs = rows(5)
      case field
      of "result": rs[2].result = "0"
      of "payload": rs[2].payload = "echo evil"
      else: rs[2].kind = "now"
      let c = checkChain(rs, rs[^1].hash)
      check c.verdict == cvBroken and c.at == 2
  test "a row taken out of the middle, a row added, rows swapped":
    var rs = rows(5)
    let tip = rs[^1].hash
    var cut = rs
    cut.delete(2)
    check checkChain(cut, tip).verdict == cvBroken
    var swapped = rs
    swap(swapped[1], swapped[2])
    check checkChain(swapped, tip).verdict == cvBroken
    var added = rs
    added.add Row(seq: 5, kind: "job_sh", payload: "forged", result: "0\n", hash: "f".repeat(64))
    check checkChain(added, tip).verdict == cvBroken
  test "the newest rows taken away (so that a step is done again) are seen by the tip kept with the run":
    let rs = rows(5)
    let tip = rs[^1].hash
    check checkChain(rs[0 .. 3], tip).verdict == cvBroken
    check checkChain(rs[0 .. 3], rs[3].hash).verdict == cvOk       # the run's own tip moved back too: not detectable here, said so in the design
  test "a tip that is missing from a hashed journal is broken, not a pass":
    let rs = rows(3)
    check checkChain(rs, "").verdict == cvBroken
  test "rows from before the chain was kept are legacy: all without hashes and without a tip":
    var rs = rows(3)
    for r in rs.mitems: r.hash = ""
    check checkChain(rs, "").verdict == cvLegacy
    let adopted = legacyHashes(rs)
    check adopted.len == 3
    var again = rs
    for i, r in again.mpairs: r.hash = adopted[i]
    check checkChain(again, adopted[^1]).verdict == cvOk
  test "some rows hashed and some not is broken":
    var rs = rows(4)
    rs[3].hash = ""
    check checkChain(rs, "").verdict == cvBroken
  test "the first sequence number is 0 and there are no gaps":
    var rs = rows(3)
    rs[1].seq = 5
    check checkChain(rs, rs[^1].hash).verdict == cvBroken
