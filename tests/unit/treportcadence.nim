## RUN-016 / docs/conductors.md section 12: on the push channel a controller reports its state when it has changed, and otherwise as a heartbeat
## now and then - not every second - so that a shard with many organisations does not spend its database on reports with no news. Pure.
import std/unittest
import jobcontroller/reportcadence

suite "RUN-016 when a controller reports":
  let heartbeat = 5.0
  test "the first time, always":
    check reportDue(Cadence(), now = 100.0, news = Changes(), sig = "a")
  test "a quiet round with the same picture of the Pods is not reported before the heartbeat":
    let c = Cadence(lastAt: 100.0, lastSig: "a")
    check not reportDue(c, now = 101.0, news = Changes(), sig = "a")
    check not reportDue(c, now = 104.9, news = Changes(), sig = "a")
    check reportDue(c, now = 105.1, news = Changes(), sig = "a")                 # the heartbeat: the core sees it is alive
  test "an end, a step handed back or a volume released is reported at once":
    let c = Cadence(lastAt: 100.0, lastSig: "a")
    check reportDue(c, now = 100.5, news = Changes(transitions: true), sig = "a")
    check reportDue(c, now = 100.5, news = Changes(handedBack: true), sig = "a")
    check reportDue(c, now = 100.5, news = Changes(released: true), sig = "a")
  test "a different picture of the Pods is reported at once (a Pod came up, a phase changed)":
    let c = Cadence(lastAt: 100.0, lastSig: "a")
    check reportDue(c, now = 100.5, news = Changes(), sig = "b")
  test "the core asking for our state again is answered at once":
    let c = Cadence(lastAt: 100.0, lastSig: "a")
    check reportDue(c, now = 100.2, news = Changes(asked: true), sig = "a")
  test "a report that was sent is remembered: the same picture is quiet afterwards":
    var c = Cadence(lastAt: 100.0, lastSig: "a")
    check reportDue(c, now = 101.0, news = Changes(transitions: true), sig = "b")
    c.sent(now = 101.0, sig = "b")
    check not reportDue(c, now = 102.0, news = Changes(), sig = "b")
  test "the signature of the Pods does not depend on their order and sees phases and reasons":
    check podSignature(@[("p1", "Running", ""), ("p2", "Pending", "ImagePullBackOff")]) ==
          podSignature(@[("p2", "Pending", "ImagePullBackOff"), ("p1", "Running", "")])
    check podSignature(@[("p1", "Running", "")]) != podSignature(@[("p1", "Succeeded", "")])
    check podSignature(@[("p1", "Pending", "")]) != podSignature(@[("p1", "Pending", "ImagePullBackOff")])
    check podSignature(@[]) == ""
