## The cache between runs (DAT-004): "the cache key is immutable; restore-keys select the latest compatible object". A step declares `cache = {key = ..., paths = {...},
## restore_keys = {...}}` (docs/cache.md); the shim restores before the command and saves after a success, moving the bytes to and from the core over the same channel as the
## artifacts (core/artifactingest.nim), and the core keeps them in the object store (core/storagebackend.nim). What is here is the core's side without the wire: the rows, the
## choice of the entry, the room for a new one, and the sweep. An entry belongs to an organisation and to a scope - the group the run is in (D-54; "" is the organisation itself) -
## so a run sees the caches of its own group only. Not built: the separation of trusted and untrusted refs (there are no refs yet), and the settings per organisation
## (the quota and the retention are the shard's: CINIM_CACHE_QUOTA, CINIM_CACHE_RETENTION).
import std/[json, strutils, os, sequtils, algorithm]
import checksums/sha2
import ../common/[rqlite, cachedecl]
export cachedecl
import storagebackend, groups

const
  defaultQuota* = 10'i64 * 1024 * 1024 * 1024
  defaultRetention* = 7 * 86400'i64
  batch* = 100

func objectKeyOf*(tenant, scope, key: string): string =
  ## the object's name: the key is hashed, so that nothing a script wrote becomes part of a name in the store
  var h = ""
  for c in secureHash(Sha_256, key): h.add toHex(ord(c), 2).toLowerAscii
  tenant & "/cache/" & (if scope.len > 0: scope else: "_") & "/" & h

func likeEscape(s: string): string = s.multiReplace(("\\", "\\\\"), ("%", "\\%"), ("_", "\\_"))

type Entry* = object
  found*: bool
  key*, s3Key*, sha256*: string
  size*: int64

proc storedEntry*(c: var RqClient; tenant, scope, key: string): Entry =
  let v = c.query(%*[["SELECT key, s3_key, size, sha256 FROM caches WHERE tenant_id = ? AND scope = ? AND key = ? AND state = 'stored'", tenant, scope, key]])["results"][0]{"values"}
  if v != nil and v.len > 0: result = Entry(found: true, key: v[0][0].getStr, s3Key: v[0][1].getStr, size: v[0][2].getBiggestInt, sha256: v[0][3].getStr)

proc findEntry*(c: var RqClient; tenant, scope, wanted: string; restoreKeys: seq[string]; now: int64): Entry =
  ## The entry with the key itself, else, for each restore key in order, the latest entry whose key starts with it (VAR: "the latest compatible object"). A hit is a use.
  result = c.storedEntry(tenant, scope, wanted)
  if not result.found:
    for r in restoreKeys:
      let v = c.query(%*[["SELECT key, s3_key, size, sha256 FROM caches WHERE tenant_id = ? AND scope = ? AND state = 'stored' AND key LIKE ? ESCAPE '\\' ORDER BY created_at DESC, key DESC LIMIT 1",
        tenant, scope, likeEscape(r) & "%"]])["results"][0]{"values"}
      if v != nil and v.len > 0:
        result = Entry(found: true, key: v[0][0].getStr, s3Key: v[0][1].getStr, size: v[0][2].getBiggestInt, sha256: v[0][3].getStr)
        break
  if result.found: discard c.execute(%*[["UPDATE caches SET last_used_at = ? WHERE tenant_id = ? AND scope = ? AND key = ?", now, tenant, scope, result.key]])

proc beginEntry*(c: var RqClient; id, tenant, scope, key, s3Key: string; size: int64; sha256, state, uploadId: string; now: int64): bool =
  ## False: the key is there already, stored or being uploaded (a key is immutable; a second saver gives way)
  c.execute(%*[["INSERT OR IGNORE INTO caches (id, tenant_id, scope, key, s3_key, size, sha256, state, upload_id, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    id, tenant, scope, key, s3Key, size, sha256, state, uploadId, now, now]])["results"][0]{"rows_affected"}.getInt > 0

proc setEntryUpload*(c: var RqClient; tenant, scope, key, uploadId: string) =
  discard c.execute(%*[["UPDATE caches SET upload_id = ? WHERE tenant_id = ? AND scope = ? AND key = ? AND state = 'uploading'", uploadId, tenant, scope, key]])

proc uploadingEntry*(c: var RqClient; tenant, scope, key: string): tuple[found: bool, s3Key, uploadId: string, size: int64] =
  let v = c.query(%*[["SELECT s3_key, upload_id, size FROM caches WHERE tenant_id = ? AND scope = ? AND key = ? AND state = 'uploading'", tenant, scope, key]])["results"][0]{"values"}
  if v != nil and v.len > 0: (true, v[0][0].getStr, v[0][1].getStr, v[0][2].getBiggestInt) else: (false, "", "", 0'i64)

proc markEntryStored*(c: var RqClient; tenant, scope, key: string): bool =
  c.execute(%*[["UPDATE caches SET state = 'stored', upload_id = '' WHERE tenant_id = ? AND scope = ? AND key = ? AND state = 'uploading'", tenant, scope, key]])["results"][0]{"rows_affected"}.getInt > 0

proc forgetEntry*(c: var RqClient; tenant, scope, key: string) =
  discard c.execute(%*[["DELETE FROM caches WHERE tenant_id = ? AND scope = ? AND key = ? AND state = 'uploading'", tenant, scope, key]])

proc bytesHeld*(c: var RqClient; tenant: string): int64 =
  c.query(%*[["SELECT COALESCE(sum(size), 0) FROM caches WHERE tenant_id = ?", tenant]])["results"][0]{"values"}[0][0].getBiggestInt

proc cacheQuotaFromEnv*(): int64 =
  try: parseBiggestInt(getEnv("CINIM_CACHE_QUOTA", $defaultQuota)) except ValueError: defaultQuota

proc cacheRetentionFromEnv*(): int64 =
  try: parseBiggestInt(getEnv("CINIM_CACHE_RETENTION", $defaultRetention)) except ValueError: defaultRetention

proc dropObject(be: ObjectBackend; key: string): bool =
  let r = be.deleteObject(key)
  r.ok or (not r.retry and "no such object" in r.error.toLowerAscii)

# ------------------------------------------------------------------ the limits: the shard's, the organisation's, the groups'

type CacheLimit* = object
  quota*, retentionDays*: int64         ## 0: nothing of its own here (the level above decides); quota > 0 bytes; retention -1 for ever, > 0 days. For an organisation quota -1 is no limit

proc orgLimit*(c: var RqClient; tenant: string): CacheLimit =
  let v = c.query(%*[["SELECT cache_quota_bytes, cache_retention_days FROM execution_profiles WHERE tenant_id = ? LIMIT 1", tenant]])["results"][0]{"values"}
  if v != nil and v.len > 0: CacheLimit(quota: v[0][0].getBiggestInt, retentionDays: v[0][1].getBiggestInt)
  else: CacheLimit()

proc groupLimit*(c: var RqClient; groupId: string): CacheLimit =
  let v = c.query(%*[["SELECT cache_quota_bytes, cache_retention_days FROM group_settings WHERE group_id = ?", groupId]])["results"][0]{"values"}
  if v != nil and v.len > 0: CacheLimit(quota: v[0][0].getBiggestInt, retentionDays: v[0][1].getBiggestInt)
  else: CacheLimit()

proc setGroupLimit*(c: var RqClient; groupId: string; quota, retentionDays: int64) =
  discard c.execute(%*[["INSERT INTO group_settings (group_id, cache_quota_bytes, cache_retention_days) VALUES (?, ?, ?) ON CONFLICT(group_id) DO UPDATE SET " &
    "cache_quota_bytes = excluded.cache_quota_bytes, cache_retention_days = excluded.cache_retention_days", groupId, quota, retentionDays]])

func validGroupLimit*(quota, retentionDays: int64): string =
  ## "" if a group may have these (0 is nothing of its own)
  if quota < 0 or (quota > 0 and quota < 1024 * 1024) or quota > 1'i64 shl 50: "cache_quota_bytes must be 0 (nothing of its own) or 1 MiB..1 PiB"
  elif retentionDays notin -1'i64 .. 3650'i64: "cache_retention_days must be 0 (the level above decides), -1 (for ever) or 1..3650"
  else: ""

proc retentionSeconds*(c: var RqClient; tenant, scope: string; shardSeconds: int64): int64 =
  ## How long an entry of this scope may stay unused, in seconds; 0 or less is for ever. The nearest group that says something wins, then the organisation, then the shard.
  for g in reversed(c.groupChain(tenant, scope)):
    let l = c.groupLimit(g.id)
    if l.retentionDays != 0: return (if l.retentionDays < 0: 0'i64 else: l.retentionDays * 86400)
  let o = c.orgLimit(tenant)
  if o.retentionDays != 0: return (if o.retentionDays < 0: 0'i64 else: o.retentionDays * 86400)
  shardSeconds

type Pool = object
  quota: int64
  groupPath: string                     ## "" is the organisation's whole pool; else the group and every group below it
  name: string

proc quotaPools(c: var RqClient; tenant, scope: string; shardQuota: int64): seq[Pool] =
  ## the limits that bind an entry of this scope, from the organisation down to its own group: each bounds the bytes of the entries at that level and below
  let o = c.orgLimit(tenant)
  let oq = if o.quota == 0: shardQuota elif o.quota < 0: 0'i64 else: o.quota
  if oq > 0: result.add Pool(quota: oq, name: "the organisation's")
  for g in c.groupChain(tenant, scope):
    let l = c.groupLimit(g.id)
    if l.quota > 0: result.add Pool(quota: l.quota, groupPath: g.path, name: "the group " & g.path & "'s")

const inPool = " AND (? = '' OR EXISTS (SELECT 1 FROM groups g WHERE g.id = c.scope AND (g.path = ? OR substr(g.path, 1, length(?) + 1) = ? || '/')))"

proc poolBytes(c: var RqClient; tenant: string; p: Pool): int64 =
  c.query(%*[["SELECT COALESCE(sum(c.size), 0) FROM caches c WHERE c.tenant_id = ?" & inPool, tenant, p.groupPath, p.groupPath, p.groupPath, p.groupPath]])["results"][0]{"values"}[0][0].getBiggestInt

proc makeRoom*(c: var RqClient; be: ObjectBackend; tenant, scope: string; needed: int64; shardQuota: int64): tuple[ok: bool, why: string] =
  ## The caches are bounded (E-003): an entry of `needed` bytes goes in when every limit that binds it holds - the organisation's, and those of its group and the groups
  ## above - the least recently used entries of that pool giving way. Not ok: it cannot fit even in an empty pool (bigger than the limit), or the store would not let an
  ## entry go; `why` names the limit.
  if needed > maxEntryBytes: return (false, "an entry is at most " & $maxEntryBytes & " bytes")
  for p in c.quotaPools(tenant, scope, shardQuota):
    if needed > p.quota: return (false, "the entry is bigger than " & p.name & " cache quota of " & $p.quota & " bytes")
    while c.poolBytes(tenant, p) + needed > p.quota:
      let v = c.query(%*[["SELECT c.id, c.s3_key FROM caches c WHERE c.tenant_id = ? AND c.state = 'stored'" & inPool & " ORDER BY c.last_used_at, c.created_at LIMIT 1",
        tenant, p.groupPath, p.groupPath, p.groupPath, p.groupPath]])["results"][0]{"values"}
      if v == nil or v.len == 0: return (false, "what is held under " & p.name & " cache quota is being uploaded, and is not taken")
      if not dropObject(be, v[0][1].getStr): return (false, "the store would not let an entry go")
      discard c.execute(%*[["DELETE FROM caches WHERE id = ?", v[0][0].getStr]])
  (true, "")

type SweepReport* = object
  expired*, abandoned*, failed*: int

proc sweepCaches*(c: var RqClient; be: ObjectBackend; now: int64; shardRetention = defaultRetention; abandonAfter = 86400'i64): SweepReport =
  ## one pass: entries not used for the retention of their scope (the group's, else the organisation's, else the shard's; 0 or less keeps for ever) go, and so does an upload
  ## that was begun and never ended
  let scopes = c.query(%*[["SELECT DISTINCT tenant_id, scope FROM caches WHERE state = 'stored' LIMIT 2000"]])["results"][0]{"values"}
  if scopes != nil:
    for sc in scopes:
      let retention = c.retentionSeconds(sc[0].getStr, sc[1].getStr, shardRetention)
      if retention <= 0: continue
      let v = c.query(%*[["SELECT id, s3_key FROM caches WHERE tenant_id = ? AND scope = ? AND state = 'stored' AND last_used_at < ? ORDER BY last_used_at LIMIT ?",
        sc[0].getStr, sc[1].getStr, now - retention, batch]])["results"][0]{"values"}
      if v != nil:
        for row in v:
          if dropObject(be, row[1].getStr):
            discard c.execute(%*[["DELETE FROM caches WHERE id = ?", row[0].getStr]])
            inc result.expired
          else: inc result.failed
  if abandonAfter > 0:
    let v = c.query(%*[["SELECT id, s3_key, upload_id FROM caches WHERE state = 'uploading' AND created_at < ? ORDER BY created_at LIMIT ?", now - abandonAfter, batch]])["results"][0]{"values"}
    if v != nil:
      for row in v:
        var gone = true
        if row[2].getStr.len > 0:
          let a = be.abortMultipart(row[1].getStr, row[2].getStr)
          gone = a.ok or (not a.retry and ("no such" in a.error.toLowerAscii or "nosuchupload" in a.error.toLowerAscii))
        if gone:
          discard c.execute(%*[["DELETE FROM caches WHERE id = ?", row[0].getStr]])
          inc result.abandoned
        else: inc result.failed
