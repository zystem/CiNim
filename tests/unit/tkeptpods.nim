## D-29, RUN-005: the Pods that a controller keeps because core could not read them: an alert for each, replaced by the controller's next
## picture, ended when the controller removes the Pod or the organisation is deleted.
import std/[unittest, json, strutils]
import ../../src/core/keptpods

proc item(pod, reason: string; seq = 0; reportedAt = 1000'i64): KeptItem =
  KeptItem(pod: pod, runId: "s1_r", reason: reason, seq: seq, attempt: 1, reportedAt: reportedAt, keepUntil: reportedAt + 14 * 86400)

suite "kept Pods and their alerts":
  test "every kept Pod is an alert with its reason and the time it is kept until":
    recordKept("cinim-001-acme", 5000, 2, @[item("ci-s1-r-1-1", "outcome_unknown", 1, 2000), item("ci-s1-r-0-1", "logs_undelivered", 0, 1000)])
    let a = keptAlerts()
    check a.len == 2
    check a[0]["code"].getStr == "pod_unread" and a[0]["namespace"].getStr == "cinim-001-acme" and a[0]["pod"].getStr == "ci-s1-r-1-1"
    check a[0]["reason"].getStr == "outcome_unknown" and a[0]["keep_until"].getBiggestInt == 2000 + 14 * 86400
    check "could not be fully read" in a[0]["detail"].getStr
    check keptCounts() == @[("cinim-001-acme", 2)]

  test "the next picture of a namespace replaces the last, an empty one ends the alerts":
    recordKept("cinim-001-acme", 5100, 1, @[item("ci-s1-r-0-1", "logs_undelivered")])
    check keptAlerts().len == 1
    recordKept("cinim-001-acme", 5200, 0, @[])
    check keptAlerts().len == 0 and keptCounts().len == 0

  test "namespaces are kept apart, the count is the controller's whole number even when the list was cut, a deleted organisation leaves none":
    recordKept("cinim-001-a", 1, 250, @[item("p1", "outcome_unknown")])
    recordKept("cinim-001-b", 1, 1, @[item("p2", "logs_undelivered")])
    check keptAlerts().len == 2
    check ("cinim-001-a", 250) in keptCounts()
    forgetKept("cinim-001-a")
    check keptAlerts().len == 1 and keptAlerts()[0]["namespace"].getStr == "cinim-001-b"
    forgetKept("cinim-001-b")
    check keptAlerts().len == 0
