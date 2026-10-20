## The identifiers of a shard (SHD-004, D-66): the shard's prefix and the time in microseconds in 11 characters of base32 (the alphabet of Crockford,
## lowercase, in the order of ASCII, so that the order of the strings is the order of the times and an id can be the cursor of a list).
## The core is one process (an architectural decision: small, restarts fast, whatever is slow is outside it), so uniqueness is one number in memory:
## an id is the later of the time now and the last id plus one, which holds when two ids are asked for in the same microsecond, when the clock goes back
## (a leap, a restart on a machine with a slower clock) and when threads ask at once (a compare-and-swap, no lock). A second process that made
## ids would need something else (D-66).
## Why microseconds: when ids are made faster than the unit, the "plus one" runs them ahead of the clock; after a quick restart of the core the new ids
## would fall into slots already taken. At milliseconds that is 100 000 ids a second (99 s ahead); at microseconds it takes a million a second kept up for
## the length of a restart (0.04 ms ahead), and the core makes a few thousand (every id is a write to rqlite).

import std/[atomics, times]

const
  shardId* = "s1"                                  ## single shard, no directory yet (stage M5 of the roadmap adds it)
  idDigits = "0123456789abcdefghjkmnpqrstvwxyz"
  idWidth = 11                                     ## 11 * 5 = 55 bits: a count of microseconds lasts to the year 3100

func idAt*(us: int64): string =
  ## the id of an instant (microseconds since 1970)
  result = shardId & "_" & newString(idWidth)
  var n = us
  for i in countdown(shardId.len + idWidth, shardId.len + 1):
    result[i] = idDigits[int(n and 31)]
    n = n shr 5

func idTimeUs*(id: string): int64 =
  ## what `idAt` was given; 0 for something that is not an id
  if id.len != shardId.len + 1 + idWidth: return 0
  for i in shardId.len + 1 ..< id.len:
    let d = idDigits.find(id[i])
    if d < 0: return 0
    result = (result shl 5) or int64(d)

type IdClock* = object
  last: Atomic[int64]                              ## the number of the last id

proc next*(c: var IdClock; now: int64): int64 =
  ## the number for an id asked for at `now`: above the one before it, whatever the threads and the clock do
  var prev = c.last.load(moRelaxed)
  while true:
    result = max(now, prev + 1)
    if c.last.compareExchange(prev, result, moRelaxed, moRelaxed): return    # on a loss `prev` is what the other thread put there

var shardClock: IdClock

proc newId*(): string =
  let t = getTime()
  idAt(shardClock.next(t.toUnix * 1_000_000'i64 + int64(t.nanosecond div 1000)))
