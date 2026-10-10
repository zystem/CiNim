## Run storage on the core's side (STO-001, STO-006): the job controller of an organisation makes one volume per run, and the core tells it when a run's
## volume may be deleted. Nothing is remembered between polls except one column, `runs.storage_released`: the core names the runs that are over and
## whose retention (`CINIM_STORAGE_RETENTION_SUCCEEDED`, 0 by default, `CINIM_STORAGE_RETENTION_FAILED`, 10 minutes, in seconds) has passed, in every poll until
## the controller says it deleted the volume (it counts a run that never had one as released), so a lost answer or a restarted controller costs nothing.
## Two rules protect the failed run that its author may still want to continue with only the failed steps (docs/parallel.md section 11): the core releases nothing of a
## failed run until it has itself been up for the retention (a core that comes back after a stop would otherwise delete at once what could not be offered for a retry), and
## an organisation whose storage is short of space (the controller reports its ResourceQuota) keeps such a volume for a minute only, oldest first.
import std/[json, os, strutils, sequtils, locks, times]
import common/[rqlite, states]

const
  defaultKeepSucceeded* = 0
  defaultKeepFailed* = 10 * 60
  defaultKeepPressure* = 60
  maxPerPoll = 50
  pressureSlots = 256
  pressureIdLen = 64

type Retention* = object
  succeeded*, failed*, pressure*: int64      ## seconds after the end of a run; a negative `succeeded` or `failed` keeps the volume for good; `pressure`: the keep of a failed run while short of space

proc retentionFromEnv*(): Retention =
  proc secs(name: string; default: int): int64 =
    try: parseBiggestInt(getEnv(name, $default)) except ValueError: default.int64
  Retention(succeeded: secs("CINIM_STORAGE_RETENTION_SUCCEEDED", defaultKeepSucceeded), failed: secs("CINIM_STORAGE_RETENTION_FAILED", defaultKeepFailed),
            pressure: secs("CINIM_STORAGE_RETENTION_PRESSURE", defaultKeepPressure))

var coreStartedAt* = getTime().toUnix()      ## when this core process started; a failed run's volume is not released before this plus the retention

# ------------------------------------------------------------------ pressure on the storage of an organisation
# The controller reads the ResourceQuota of its namespace and reports `requests.storage` used and hard; the core remembers, per organisation, whether less than 15 % is free
# (pressure) and until more than 20 % is free again (so it does not flap). Fixed arrays under a lock: the thread of the organisation writes, any may read.

var
  pressureLock: Lock
  pressureIds: array[pressureSlots, array[pressureIdLen, char]]
  pressureOn: array[pressureSlots, bool]
  pressureUsed: int
initLock(pressureLock)

proc slotOf(profileId: string; make: bool): int =
  ## the slot of this organisation, or a new one if `make`; -1 when there is none (a very long id, or no room)
  if profileId.len == 0 or profileId.len >= pressureIdLen: return -1
  for i in 0 ..< pressureUsed:
    var same = true
    for k in 0 ..< profileId.len:
      if pressureIds[i][k] != profileId[k]:
        same = false
        break
    if same and pressureIds[i][profileId.len] == '\0': return i
  if not make or pressureUsed >= pressureSlots: return -1
  result = pressureUsed
  inc pressureUsed
  for k in 0 ..< profileId.len: pressureIds[result][k] = profileId[k]
  pressureIds[result][profileId.len] = '\0'
  pressureOn[result] = false

proc resetPressure*() =
  {.cast(gcsafe).}:
    withLock pressureLock:
      pressureUsed = 0

proc notePressure*(profileId: string; used, hard: uint64) =
  ## what the controller of the organisation reported of its storage quota; `hard` 0 (no quota, or it could not be read) says nothing
  if hard == 0: return
  {.cast(gcsafe).}:
    withLock pressureLock:
      let i = slotOf(profileId, true)
      if i < 0: return
      let free = hard - min(used, hard)
      if free * 100 < hard * 15: pressureOn[i] = true            # less than 15 % free
      elif free * 100 > hard * 20: pressureOn[i] = false         # more than 20 % free

proc underPressure*(profileId: string): bool =
  {.cast(gcsafe).}:
    withLock pressureLock:
      let i = slotOf(profileId, false)
      result = i >= 0 and pressureOn[i]

func volumeDue*(state: string; ended, now, coreStarted: int64; keep: Retention; pressure: bool): bool =
  ## May the volume of a run that ended at `ended` go now? A run that succeeded: after `keep.succeeded`. Any other end: after `keep.failed`, counted from the later of its
  ## end and the start of this core; under pressure after `keep.pressure` from its end (never longer than `keep.failed`), whatever the core's age. Negative: never.
  if state == protoName(rsSucceeded):
    return keep.succeeded >= 0 and ended + keep.succeeded <= now
  if keep.failed < 0: return false
  if pressure: return ended + min(keep.pressure, keep.failed) <= now
  max(ended, coreStarted) + keep.failed <= now

proc releasableRuns*(c: var RqClient; profileId: string; now: int64; keep: Retention): seq[string] =
  ## the runs of this profile (an organisation's namespace) that are over, past their retention and not yet confirmed released
  if profileId.len == 0: return
  let ok = protoName(rsSucceeded)
  var ends: seq[string]
  for s in [rsSucceeded, rsFailed, rsCanceled, rsSkipped, rsTimedOut, rsInfrastructureError]: ends.add protoName(s)
  let marks = ends.mapIt("?").join(",")
  var args = %*["SELECT id, state, CAST(updated_at AS INTEGER) FROM runs WHERE profile_id = ? AND storage_released = 0 AND state IN (" & marks & ") ORDER BY updated_at LIMIT ?", profileId]
  for e in ends: args.add %e
  args.add %(maxPerPoll * 4)       # more than enough: the retention filters some out below
  let r = c.query(%*[args])
  let vals = r["results"][0]{"values"}
  if vals == nil: return
  let pressure = underPressure(profileId)
  for row in vals:
    if volumeDue(row[1].getStr, row[2].getBiggestInt, now, coreStartedAt, keep, pressure):
      result.add row[0].getStr
      if result.len >= maxPerPoll: break

proc markReleased*(c: var RqClient; runIds: seq[string]) =
  ## the controller deleted these runs' volumes
  if runIds.len == 0: return
  var stmts = newJArray()
  for id in runIds: stmts.add %*["UPDATE runs SET storage_released = 1 WHERE id = ?", id]
  discard c.execute(stmts, transaction = true)
