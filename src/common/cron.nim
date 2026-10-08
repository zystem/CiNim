## Cron schedules for triggers (spec 6.3, triggers). Five fields, UTC: minute hour day-of-month month day-of-week.
##
## Each field is a list of items; an item is `*`, `a`, `a-b`, with an optional `/step` (`*/15`, `10-50/10`). Months and weekdays may be written as
## three-letter names (`jan`, `mon`); weekday 0 and 7 are both Sunday. As in Vixie cron, when both day-of-month and day-of-week are restricted
## a day matches if either does. The macros `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly` are accepted. There are no time zones:
## a schedule is in UTC, so that a change of summer time cannot run a job twice or not at all.
import std/[strutils, times]

type
  Cron* = object
    minutes, hours, dom, months, dow: uint64   ## bit n set = the value n matches
    domStar, dowStar: bool                     ## the field was `*` (so the other one alone decides the day)

const
  monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
  dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

func value(s: string; names: openArray[string]; first: int): int =
  ## a number or a name; -1 when it is neither
  let l = s.toLowerAscii
  for i, n in names:
    if l == n: return i + first
  if s.len == 0 or s.len > 2: return -1
  for ch in s:
    if ch notin Digits: return -1
  parseInt(s)

func parseField(f: string; lo, hi: int; names: openArray[string]; first: int; bits: var uint64; star: var bool): string =
  ## "" if the field is well formed, else what is wrong
  star = f == "*"
  for item in f.split(','):
    if item.len == 0: return "an empty item"
    var rng = item
    var step = 1
    let slash = item.find('/')
    if slash >= 0:
      rng = item[0 ..< slash]
      let st = item[slash + 1 .. ^1]
      if st.len == 0 or st.len > 2: return "bad step in '" & item & "'"
      for ch in st:
        if ch notin Digits: return "bad step in '" & item & "'"
      step = parseInt(st)
      if step < 1: return "the step of '" & item & "' must be at least 1"
    var a, b: int
    if rng == "*":
      a = lo; b = hi
      if slash < 0 and item != "*": return "bad item '" & item & "'"
    else:
      let dash = rng.find('-')
      if dash >= 0:
        a = value(rng[0 ..< dash], names, first); b = value(rng[dash + 1 .. ^1], names, first)
      else:
        a = value(rng, names, first)
        b = if slash >= 0: hi else: a
      if a < 0 or b < 0: return "bad item '" & item & "'"
    if a < lo or b > hi or a > b: return "'" & item & "' is outside " & $lo & ".." & $hi
    var v = a
    while v <= b:
      bits = bits or (1'u64 shl v)
      v += step

func parseCron*(spec: string): tuple[ok: bool, cron: Cron, error: string] =
  var s = spec.strip
  case s
  of "@hourly": s = "0 * * * *"
  of "@daily", "@midnight": s = "0 0 * * *"
  of "@weekly": s = "0 0 * * 0"
  of "@monthly": s = "0 0 1 * *"
  of "@yearly", "@annually": s = "0 0 1 1 *"
  else: discard
  let f = s.splitWhitespace
  if f.len != 5:
    result.error = "a schedule has five fields: minute hour day-of-month month day-of-week (UTC)"
    return
  var c: Cron
  var dummy: bool
  var dowRaw: uint64
  for (i, e) in [(0, parseField(f[0], 0, 59, [], 0, c.minutes, dummy)), (1, parseField(f[1], 0, 23, [], 0, c.hours, dummy)),
                 (2, parseField(f[2], 1, 31, [], 1, c.dom, c.domStar)), (3, parseField(f[3], 1, 12, monthNames, 1, c.months, dummy)),
                 (4, parseField(f[4], 0, 7, dayNames, 0, dowRaw, c.dowStar))]:
    if e.len > 0:
      result.error = "field " & $(i + 1) & ": " & e
      return
  c.dow = (dowRaw and 0x7F'u64) or (if (dowRaw and 0x80'u64) != 0: 1'u64 else: 0'u64)   # 7 is Sunday too
  (true, c, "")

func matches*(c: Cron; t: DateTime): bool =
  if (c.minutes and (1'u64 shl t.minute)) == 0 or (c.hours and (1'u64 shl t.hour)) == 0 or (c.months and (1'u64 shl ord(t.month))) == 0:
    return false
  let domOk = (c.dom and (1'u64 shl t.monthday)) != 0
  let dowOk = (c.dow and (1'u64 shl ((ord(t.weekday) + 1) mod 7))) != 0     # Nim: Monday = 0; cron: Sunday = 0
  if c.domStar or c.dowStar: domOk and dowOk
  else: domOk or dowOk

proc latestDue*(c: Cron; afterUnix, nowUnix: int64; lookbackSeconds = 7 * 86400): int64 =
  ## The latest whole minute m with after < m <= now at which the schedule fires, or 0. Looking at most `lookbackSeconds` back: a core that was
  ## down fires a schedule once when it is up again (not once for every minute it missed), unless the last firing is further back than that.
  var m = (nowUnix div 60) * 60
  let lowest = max(afterUnix, nowUnix - lookbackSeconds)
  while m > lowest:
    if c.matches(fromUnix(m).utc): return m
    m -= 60
  0
