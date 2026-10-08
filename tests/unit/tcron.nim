## Cron schedules of the triggers (spec 6.3).
import std/[unittest, times]
import common/cron

proc at(y, mo, d, h, mi: int): int64 = toUnix(dateTime(y, Month(mo), d, h, mi, 0, zone = utc()).toTime)

suite "TRG-001 cron schedules":
  test "TRG-001 a plain expression fires on its minute only":
    let c = parseCron("30 2 * * *").cron
    check c.matches(dateTime(2026, mOct, 8, 2, 30, 0, zone = utc()))
    check not c.matches(dateTime(2026, mOct, 8, 2, 31, 0, zone = utc()))
    check not c.matches(dateTime(2026, mOct, 8, 3, 30, 0, zone = utc()))

  test "TRG-001 steps, ranges and lists":
    let c = parseCron("*/15 9-17/4 1,15 * *").cron
    check c.matches(dateTime(2026, mOct, 1, 9, 45, 0, zone = utc()))
    check c.matches(dateTime(2026, mOct, 15, 13, 0, 0, zone = utc()))
    check not c.matches(dateTime(2026, mOct, 15, 11, 0, 0, zone = utc()))   # 9, 13, 17 only
    check not c.matches(dateTime(2026, mOct, 2, 9, 0, 0, zone = utc()))

  test "TRG-001 names, and 0 and 7 are both Sunday":
    let sun0 = parseCron("0 0 * * 0").cron
    let sun7 = parseCron("0 0 * * 7").cron
    let sunName = parseCron("0 0 * * sun").cron
    let d = dateTime(2026, mOct, 11, 0, 0, 0, zone = utc())      # a Sunday
    check d.weekday == dSun
    check sun0.matches(d) and sun7.matches(d) and sunName.matches(d)
    check not sun0.matches(dateTime(2026, mOct, 12, 0, 0, 0, zone = utc()))
    check parseCron("0 0 1 jan-mar *").cron.matches(dateTime(2026, mFeb, 1, 0, 0, 0, zone = utc()))

  test "TRG-001 both day fields restricted: either matches; one restricted: that one decides":
    let c = parseCron("0 0 13 * fri").cron
    check c.matches(dateTime(2026, mOct, 13, 0, 0, 0, zone = utc()))     # the 13th (a Tuesday)
    check c.matches(dateTime(2026, mOct, 9, 0, 0, 0, zone = utc()))      # a Friday
    check not c.matches(dateTime(2026, mOct, 10, 0, 0, 0, zone = utc()))
    let d = parseCron("0 0 * * fri").cron
    check not d.matches(dateTime(2026, mOct, 13, 0, 0, 0, zone = utc()))

  test "TRG-001 macros":
    check parseCron("@hourly").ok and parseCron("@daily").ok and parseCron("@weekly").ok and parseCron("@monthly").ok
    check parseCron("@daily").cron.matches(dateTime(2026, mOct, 8, 0, 0, 0, zone = utc()))

  test "TRG-001 malformed schedules are refused with a reason":
    for bad in ["", "* * * *", "* * * * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8", "*/0 * * * *", "5-3 * * * *",
                "a * * * *", "1,,2 * * * *", "*/ * * * *", "1/ * * * *", "foo"]:
      let r = parseCron(bad)
      check not r.ok
      check r.error.len > 0

  test "TRG-001 latestDue finds the last firing in (after, now]":
    let c = parseCron("*/10 * * * *").cron
    let now = at(2026, 10, 8, 12, 34) + 20
    check c.latestDue(at(2026, 10, 8, 12, 0), now) == at(2026, 10, 8, 12, 30)
    check c.latestDue(at(2026, 10, 8, 12, 30), now) == 0              # the 12:30 firing is the one already done
    check c.latestDue(at(2026, 10, 8, 12, 29), now) == at(2026, 10, 8, 12, 30)

  test "TRG-001 a core that was down fires once, and not for a firing older than the look-back":
    let c = parseCron("0 * * * *").cron
    let now = at(2026, 10, 8, 12, 5)
    check c.latestDue(at(2026, 10, 8, 6, 0), now) == at(2026, 10, 8, 12, 0)   # five missed hours: one firing
    check c.latestDue(0, now, lookbackSeconds = 3600) == at(2026, 10, 8, 12, 0)
    check parseCron("0 0 1 1 *").cron.latestDue(0, now, lookbackSeconds = 86400) == 0
