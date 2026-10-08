## The data keys of the organisations that were opened lately, kept in the core's memory for a short time, so that the start of every step does not ask the token
## again (a token answers in tens of milliseconds, but it is another machine that can be down). A key is dropped after `ttl` seconds, and all of them are dropped
## when the master key changes. Nothing is written anywhere.
import std/[tables, locks]

type
  DekCache* = object
    lock: Lock
    items: Table[string, tuple[dek: seq[byte], until: float]]
    ttl*: float

proc initDekCache*(ttl: float): DekCache =
  initLock(result.lock)
  result.ttl = ttl

proc get*(c: var DekCache; tenant: string; now: float): tuple[found: bool, dek: seq[byte]] =
  withLock c.lock:
    if tenant in c.items:
      let e = c.items[tenant]
      if now < e.until: return (true, e.dek)
      c.items.del tenant

proc put*(c: var DekCache; tenant: string; dek: seq[byte]; now: float) =
  if c.ttl <= 0: return            # a cache of no time keeps nothing
  withLock c.lock:
    c.items[tenant] = (dek, now + c.ttl)

proc forget*(c: var DekCache; tenant: string) =
  withLock c.lock: c.items.del tenant

proc clear*(c: var DekCache) =
  withLock c.lock: c.items.clear()

proc len*(c: var DekCache): int =
  withLock c.lock: result = c.items.len
