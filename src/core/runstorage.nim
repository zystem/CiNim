## Run storage on the core's side (STO-001, STO-006): the job controller of an organisation makes one volume per run, and the core tells it when a run's
## volume may be deleted. Nothing is remembered between polls except one column, `runs.storage_released`: the core names the runs that are over and
## whose retention (`CINIM_STORAGE_RETENTION_SUCCEEDED`, 0 by default, `CINIM_STORAGE_RETENTION_FAILED`, 24 h, in seconds) has passed, in every poll until
## the controller says it deleted the volume (it counts a run that never had one as released), so a lost answer or a restarted controller costs nothing.
import std/[json, os, strutils, sequtils]
import common/[rqlite, states]

const
  defaultKeepSucceeded* = 0
  defaultKeepFailed* = 24 * 3600
  maxPerPoll = 50

type Retention* = object
  succeeded*, failed*: int64      ## seconds after the end of a run; a negative value keeps the volume for good

proc retentionFromEnv*(): Retention =
  proc secs(name: string; default: int): int64 =
    try: parseBiggestInt(getEnv(name, $default)) except ValueError: default.int64
  Retention(succeeded: secs("CINIM_STORAGE_RETENTION_SUCCEEDED", defaultKeepSucceeded), failed: secs("CINIM_STORAGE_RETENTION_FAILED", defaultKeepFailed))

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
  for row in vals:
    let keepFor = if row[1].getStr == ok: keep.succeeded else: keep.failed
    if keepFor >= 0 and row[2].getBiggestInt + keepFor <= now:
      result.add row[0].getStr
      if result.len >= maxPerPoll: break

proc markReleased*(c: var RqClient; runIds: seq[string]) =
  ## the controller deleted these runs' volumes
  if runIds.len == 0: return
  var stmts = newJArray()
  for id in runIds: stmts.add %*["UPDATE runs SET storage_released = 1 WHERE id = ?", id]
  discard c.execute(stmts, transaction = true)
