## Is the database there? For the readiness of the services whose state is in rqlite (the core, the storage module): a read that goes through the leader (`weak`), with a short timeout of its
## own, so that a probe is answered quickly whatever the database is doing. The answer is kept for a moment (`readyCached`) so that probes are not a load of their own.
import std/[json]
import rqlite

proc databaseReady*(url: string; timeoutMs: int): tuple[ok: bool, why: string] =
  try:
    var c = newRq(url, timeoutMs)
    discard c.query(%*[["SELECT 1"]], level = "weak")
    (true, "")
  except CatchableError as e:
    (false, e.msg)

const readyKeepSeconds = 2.0

var
  lastAt {.threadvar.}: float
  lastAnswer {.threadvar.}: tuple[ok: bool, why: string]

proc readyCached*(url: string; timeoutMs: int; now: float): tuple[ok: bool, why: string] =
  ## the answer of `databaseReady`, asked again only when the last is older than a moment (each thread keeps its own)
  if lastAt > 0.0 and now - lastAt < readyKeepSeconds and now >= lastAt: return lastAnswer
  lastAnswer = databaseReady(url, timeoutMs)
  lastAt = now
  lastAnswer
