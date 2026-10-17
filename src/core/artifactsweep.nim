## The sweep of the artifacts (DAT-006): what nobody will read is deleted from the store, so that it does not fill up.
##
##   * a stored artifact older than the retention (`CINIM_ARTIFACT_RETENTION`, 30 days; 0 or less keeps for ever), of a run that has ended - an artifact of a run still
##     under way is never taken, whatever its age, nor is one of a run under a legal hold (core/holds.nim, DAT-006);
##   * an upload that was started and never finished (state `uploading`, the multipart upload of the store still open) for longer than `CINIM_UPLOAD_ABANDON_AFTER`
##     (a day): the upload is aborted, so that the store frees the parts, and the row goes;
##   * an artifact whose run is not in the database any more (a switched-off organisation that was purged): the object and the row go.
## One call looks at a bounded number of rows (the rest in the next pass). An object the store says it does not have is as good as deleted; a store that does not answer
## leaves the row for the next pass. The objects are named `<tenant>/<run>/<path>`; the store is reached through `ObjectBackend` (core/storagebackend.nim), so the sweep
## is tested against a store in memory.
import std/[json, strutils, times, os]
import ../common/[rqlite, states]
import ../common/storagebackend
import holds, objectstore

const
  defaultRetention* = 30 * 86400'i64
  defaultAbandonAfter* = 86400'i64
  batch* = 200

type SweepReport* = object
  expired*, abandoned*, orphans*, failed*: int

func finalList(): string =
  for i, s in [rsSucceeded, rsFailed, rsCanceled, rsSkipped, rsTimedOut, rsInfrastructureError]:
    result.add (if i == 0: "'" else: ",'") & protoName(s) & "'"

proc retentionFromEnv*(): int64 =
  try: parseBiggestInt(getEnv("CINIM_ARTIFACT_RETENTION", $defaultRetention)) except ValueError: defaultRetention

proc abandonAfterFromEnv*(): int64 =
  try: parseBiggestInt(getEnv("CINIM_UPLOAD_ABANDON_AFTER", $defaultAbandonAfter)) except ValueError: defaultAbandonAfter

proc dropObject(ss: StoreSet; store, key: string): bool =
  let rb = ss.resolve(store)
  if rb.be == nil: return false              # no storage module is set up: the row stays for another pass
  let r = rb.be.deleteObject(key)
  # a store the module does not have any more (the operator forgot it, D-60) holds nothing the core can reach: the row goes
  r.ok or (not r.retry and ("no such object" in r.error.toLowerAscii or r.error == "no such store"))

proc abortUpload(ss: StoreSet; store, key, uploadId: string): Outcome =
  let rb = ss.resolve(store)
  if rb.be == nil: return fail("the store is not available: " & rb.error, retry = true)
  rb.be.abortMultipart(key, uploadId)

proc sweepArtifacts*(c: var RqClient; ss: StoreSet; now: int64; retention = defaultRetention; abandonAfter = defaultAbandonAfter): SweepReport =
  ## one pass; the report says what was done
  # the retention of an organisation (days, in its profile) is its own; 0 there is the shard's `retention`, and no retention at all (0 or less) keeps for ever
  block expire:
    let r = c.query(%*[["SELECT a.id, a.s3_key, a.store FROM artifacts a LEFT JOIN runs r ON r.id = a.run_id LEFT JOIN execution_profiles p ON p.id = r.profile_id " &
      "WHERE a.state = 'stored' AND r.state IN (" & finalList() & ") AND NOT " & heldRunSql("a.run_id", "r.tenant_id", "r.group_id") & " AND " &
      "(CASE WHEN COALESCE(p.artifact_retention_days, 0) > 0 THEN p.artifact_retention_days * 86400 ELSE ? END) > 0 AND " &
      "a.created_at < ? - (CASE WHEN COALESCE(p.artifact_retention_days, 0) > 0 THEN p.artifact_retention_days * 86400 ELSE ? END) " &
      "ORDER BY a.created_at LIMIT ?", max(retention, 0), now, max(retention, 0), batch]])["results"][0]{"values"}
    if r != nil:
      for v in r:
        if dropObject(ss, v[2].getStr, v[1].getStr):
          discard c.execute(%*[["DELETE FROM artifacts WHERE id = ?", v[0].getStr]])
          inc result.expired
        else: inc result.failed
  if abandonAfter > 0:
    let r = c.query(%*[["SELECT id, s3_key, upload_id, store FROM artifacts WHERE state = 'uploading' AND created_at < ? ORDER BY created_at LIMIT ?", now - abandonAfter, batch]])["results"][0]{"values"}
    if r != nil:
      for v in r:
        var gone = true
        if v[2].getStr.len > 0:
          let a = abortUpload(ss, v[3].getStr, v[1].getStr, v[2].getStr)
          gone = a.ok or (not a.retry and ("no such" in a.error.toLowerAscii or "nosuchupload" in a.error.toLowerAscii))
        if gone:
          discard c.execute(%*[["DELETE FROM artifacts WHERE id = ?", v[0].getStr]])
          inc result.abandoned
        else: inc result.failed
  let o = c.query(%*[["SELECT id, s3_key, state, upload_id, store FROM artifacts WHERE run_id NOT IN (SELECT id FROM runs) LIMIT ?", batch]])["results"][0]{"values"}
  if o != nil:
    for v in o:
      var gone = true
      if v[2].getStr == "uploading" and v[3].getStr.len > 0: gone = abortUpload(ss, v[4].getStr, v[1].getStr, v[3].getStr).ok
      elif v[2].getStr == "stored": gone = dropObject(ss, v[4].getStr, v[1].getStr)
      if gone:
        discard c.execute(%*[["DELETE FROM artifacts WHERE id = ?", v[0].getStr]])
        inc result.orphans
      else: inc result.failed
