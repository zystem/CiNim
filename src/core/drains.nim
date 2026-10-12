## The drain of a step's leavings (DAT-003, D-27, docs/artifacts.md). When the core is not there, the shim keeps what it could not hand over on the run's volume - the manifest of its
## artifacts, its log spool - and ends with `artifacts_undelivered` or `logs_undelivered` (its command's result stands). The Pod has ended, so the controller of the organisation
## fetches them through a reader Pod of its own, when the core orders it. The core's part is here: it remembers which steps have something to fetch (`step_drains`), names them to the
## controller in every answer until the controller says they are done, tries again later after a failure that may pass, gives up after a day, and lets the ArtifactIngest
## accept the files of a step that has already ended while its drain is under way.
import std/[json, times]
import std/options
import ../common/[rqlite, shimstate]
import objectstore

const
  retryAfter* = 120               ## seconds before a drain that failed for a reason that may pass is ordered again
  giveUpAfter* = 24 * 3600        ## seconds a drain is tried before it is given up (the run's volume is kept meanwhile)
  maxOrders* = 3                  ## orders to one controller at a time: a drain takes the controller's poll loop for a while

type DrainRow* = object
  runId*: string
  ordinal*, attempt*: int
  image*: string
  artifacts*, logs*: bool

proc noteUndelivered*(c: var RqClient; runId: string; ordinal, attempt: int; reason: string; cmdExit: int; now: int64) =
  ## the step ended with `reason`: if that is one of the two undelivered, there is something on the volume to fetch (once; the next call for the same attempt does nothing).
  ## What exactly is read from the shim's own account, which the Pod log carries (shimstate.nim: `logs` and `arts` say what became of each; D-53); when that is not
  ## there, from the reason and from what the step declared. A command that failed put no artifacts (the shim puts them only after a success): only its log is to be fetched.
  if reason notin ["logs_undelivered", "artifacts_undelivered"]: return
  let r = c.query(%*[["SELECT profile_id, image, opts, shim_json FROM steps WHERE run_id = ? AND ordinal = ? AND attempt = ?", runId, ordinal, attempt]])
  let v = r["results"][0]{"values"}
  if v == nil or v.len == 0: return
  let declared = artifactDecl(v[0][2].getStr).upload.len > 0
  var shim = none(ShimState)
  if v[0][3].getStr.len > 0:
    shim = try: fromJson(parseJson(v[0][3].getStr)) except CatchableError: none(ShimState)
  let logsState = if shim.isSome: shim.get.logs else: lsNone
  let artsState = if shim.isSome: shim.get.artifacts else: asNone
  let logs = reason == "logs_undelivered" or logsState == lsUndelivered
  let succeeded = (if shim.isSome and shim.get.result.len > 0: shim.get.result == "success" else: cmdExit == 0)
  let arts = succeeded and (artsState == asUndelivered or reason == "artifacts_undelivered" or
             (reason == "logs_undelivered" and declared and artsState notin {asDelivered, asFailed}))
  if not arts and not logs: return
  discard c.execute(%*[["INSERT OR IGNORE INTO step_drains (run_id, ordinal, attempt, profile_id, image, artifacts, logs, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    runId, ordinal, attempt, v[0][0].getStr, v[0][1].getStr, (if arts: 1 else: 0), (if logs: 1 else: 0), now, now]])

proc dueDrains*(c: var RqClient; profileId: string; now: int64): seq[DrainRow] =
  ## the drains of this organisation to order now: pending, not waiting for a retry; the ones older than a day are given up here
  discard c.execute(%*[["UPDATE step_drains SET state = 'failed', detail = 'given up after a day', updated_at = ? WHERE state = 'pending' AND created_at < ?", now, now - giveUpAfter]])
  let r = c.query(%*[["SELECT run_id, ordinal, attempt, image, artifacts, logs FROM step_drains WHERE profile_id = ? AND state = 'pending' AND next_at <= ? ORDER BY created_at LIMIT ?",
    profileId, now, maxOrders]])
  let vals = r["results"][0]{"values"}
  if vals == nil: return
  for row in vals:
    result.add DrainRow(runId: row[0].getStr, ordinal: row[1].getInt, attempt: row[2].getInt, image: row[3].getStr, artifacts: row[4].getInt == 1, logs: row[5].getInt == 1)

proc recordDrained*(c: var RqClient; runId: string; ordinal, attempt: int; ok, final: bool; detail: string; now: int64) =
  ## what the controller said of an order: done, given up for good, or (neither) tried and to be tried again later
  if ok:
    discard c.execute(%*[["UPDATE step_drains SET state = 'done', detail = '', updated_at = ? WHERE run_id = ? AND ordinal = ? AND attempt = ? AND state = 'pending'", now, runId, ordinal, attempt]])
  elif final:
    discard c.execute(%*[["UPDATE step_drains SET state = 'failed', detail = ?, updated_at = ? WHERE run_id = ? AND ordinal = ? AND attempt = ? AND state = 'pending'", detail, now, runId, ordinal, attempt]])
  else:
    discard c.execute(%*[["UPDATE step_drains SET tries = tries + 1, next_at = ?, detail = ?, updated_at = ? WHERE run_id = ? AND ordinal = ? AND attempt = ? AND state = 'pending'",
      now + retryAfter, detail, now, runId, ordinal, attempt]])

proc isDraining*(c: var RqClient; runId: string; ordinal, attempt: int): bool =
  ## the files of this attempt are being fetched for it: the ArtifactIngest takes them although the step has ended
  let r = c.query(%*[["SELECT 1 FROM step_drains WHERE run_id = ? AND ordinal = ? AND attempt = ? AND state = 'pending' AND artifacts = 1", runId, ordinal, attempt]])
  let v = r["results"][0]{"values"}
  v != nil and v.len > 0
