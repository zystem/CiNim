## RUN-016 / docs/conductors.md section 12: the push channel numbers what the core sends, the other side acknowledges what it has applied, and
## whatever is not acknowledged is sent again after a reconnect - so that every message is applied once and in order. Pure.
import std/[unittest, sequtils]
import common/streamstate

suite "RUN-016 push channel: numbering and acknowledgement":
  test "frames are numbered from 1 in the order they are pushed":
    var o = initOutbox()
    check o.push("work", "a", 10.0).id == 1
    check o.push("work", "b", 10.0).id == 2
    check o.push("work", "c", 11.0).id == 3
    check o.unacked.mapIt(it.id) == @[1'u64, 2, 3]
  test "an acknowledgement is cumulative: everything up to it is dropped":
    var o = initOutbox()
    for p in ["a", "b", "c", "d"]: discard o.push("work", p, 0.0)
    o.ack(2)
    check o.unacked.mapIt(it.id) == @[3'u64, 4]
    o.ack(1)                                    # an older acknowledgement changes nothing
    check o.unacked.mapIt(it.id) == @[3'u64, 4]
    o.ack(99)                                   # one beyond what was sent drops everything and breaks nothing
    check o.unacked.len == 0
    check o.push("work", "e", 0.0).id == 5      # numbering goes on
  test "frames older than a limit that nobody acknowledged are due again; sending them again restarts their clock":
    var o = initOutbox()
    discard o.push("work", "a", 0.0)
    discard o.push("work", "b", 8.0)
    check o.due(now = 9.0, olderThan = 5.0).mapIt(it.id) == @[1'u64]
    o.sentAgain(@[1'u64], now = 9.0)
    check o.due(now = 10.0, olderThan = 5.0).len == 0
    check o.due(now = 14.5, olderThan = 5.0).mapIt(it.id) == @[1'u64, 2]
  test "after a reconnect everything unacknowledged is sent again, in order":
    var o = initOutbox()
    for p in ["a", "b", "c"]: discard o.push("work", p, 0.0)
    o.ack(1)
    check o.unacked.mapIt(it.payload) == @["b", "c"]

suite "RUN-016 push channel: applying once and in order":
  test "the next frame is applied, a repeated one is a duplicate, one that skips a number is a gap":
    var i = initInbox()
    check i.accept(1) == acApply
    check i.accept(1) == acDuplicate
    check i.accept(3) == acGap                  # 2 is missing: not applied, asked for again by the acknowledgement
    check i.ackValue == 1
    check i.accept(2) == acApply
    check i.accept(3) == acApply
    check i.ackValue == 3
  test "a sender that resends everything after a reconnect has each frame applied exactly once":
    var o = initOutbox()
    var i = initInbox()
    for p in ["a", "b", "c", "d"]: discard o.push("work", p, 0.0)
    var applied: seq[string]
    for f in o.unacked[0 .. 1]:                 # the first two arrive, then the connection drops
      if i.accept(f.id) == acApply: applied.add f.payload
    for f in o.unacked:                         # reconnect: all four are sent again
      if i.accept(f.id) == acApply: applied.add f.payload
    check applied == @["a", "b", "c", "d"]
    o.ack(i.ackValue)
    check o.unacked.len == 0
  test "an inbox that starts again (a new process) asks for everything from the beginning":
    var i = initInbox()
    check i.ackValue == 0
    check i.accept(5) == acGap

suite "RUN-016 push channel: credit":
  test "the sender never goes below zero and the credit is replaced by what the receiver says":
    var c = Credit()
    c.set(3)
    check c.take(2) == 2
    check c.take(5) == 1                        # only one was left
    check c.available == 0
    c.set(20)
    check c.available == 20
