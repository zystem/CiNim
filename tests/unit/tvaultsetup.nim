## The start of the secrets store (core/vaultsetup.nim, setupAtStart): the master key must be there when the core starts. If it is not, nothing in the shard can open its secrets and the whole of
## it is unusable, so the core says why and exits (the real one's `_exit(1)`): Kubernetes shows CrashLoopBackOff, the loudest word there is for a person, and starts the core again with a growing
## pause, which is the retry (D-64). The cause may be one that passes (the key service is restarting, the card waits for a PIN) or not (the key is not the one that sealed the database, the service
## refuses the core): the end is the same, only the words differ. Here the attempt and the ends are stand-ins.
import std/[unittest, strutils]
import ../../src/core/vaultsetup

type Attempt = tuple[ready, retry: bool, error: string]

var
  next: Attempt
  raises: bool
  calls, readies: int
  fatals: seq[string]
  mayPasses: seq[bool]

proc reset(a: Attempt; raising = false) =
  next = a
  raises = raising
  calls = 0
  readies = 0
  fatals = @[]
  mayPasses = @[]

proc attempt(): Attempt {.gcsafe.} =
  {.cast(gcsafe).}:
    inc calls
    if raises: raise newException(IOError, "the database does not answer")
    next

proc onReady() {.gcsafe.} =
  {.cast(gcsafe).}:
    inc readies

proc onFatal(e: string; mayPass: bool) {.gcsafe.} =
  {.cast(gcsafe).}:
    fatals.add e
    mayPasses.add mayPass

suite "the start of the secrets store":
  test "the key is there: ready, nothing fatal":
    reset((true, false, ""))
    setupAtStart(attempt, onReady, onFatal)
    check calls == 1 and readies == 1 and fatals.len == 0
  test "a key service that does not answer (it may be back in a moment) ends the core, once, and says that it may pass: Kubernetes does the asking again":
    reset((false, true, "the key service does not answer (unexpected eof)"))
    setupAtStart(attempt, onReady, onFatal)
    check calls == 1 and readies == 0
    check fatals == @["the key service does not answer (unexpected eof)"] and mayPasses == @[true]
  test "a key that is not the one that sealed the database ends the core, and says that waiting will not help":
    reset((false, false, "the key of the secrets (transit:cinim-shard@da9a) is not the one that sealed the secrets in this database"))
    setupAtStart(attempt, onReady, onFatal)
    check calls == 1 and readies == 0 and fatals.len == 1 and "is not the one that sealed" in fatals[0] and mayPasses == @[false]
  test "an exception in the attempt (the database) ends the core with the reason, it does not kill the thread without a word":
    reset((true, false, ""), raising = true)
    setupAtStart(attempt, onReady, onFatal)
    check calls == 1 and readies == 0
    check fatals.len == 1 and "could not start" in fatals[0] and "the database does not answer" in fatals[0] and mayPasses == @[true]
