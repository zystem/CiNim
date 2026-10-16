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
import storagebackend, groups, objectstore

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
  key*, s3Key*, sha256*, store*: string
  size*: int64

proc storedEntry*(c: var RqClient; tenant, scope, key: string): Entry =
  let v = c.query(%*[["SELECT key, s3_key, size, sha256, store FROM caches WHERE tenant_id = ? AND scope = ? AND key = ? AND state = 'stored'", tenant, scope, key]])["results"][0]{"values"}
  if v != nil and v.len > 0: result = Entry(found: true, key: v[0][0].getStr, s3Key: v[0][1].getStr, size: v[0][2].getBiggestInt, sha256: v[0][3].getStr, store: v[0][4].getStr)

proc findEntry*(c: var RqClient; tenant, scope, wanted: string; restoreKeys: seq[string]; now: int64): Entry =
  ## The entry with the key itself, else, for each restore key in order, the latest entry whose key starts with it (VAR: "the latest compatible object"). A hit is a use.
  result = c.storedEntry(tenant, scope, wanted)
  if not result.found:
    for r in restoreKeys:
      let v = c.query(%*[["SELECT key, s3_key, size, sha256, store FROM caches WHERE tenant_id = ? AND scope = ? AND state = 'stored' AND key LIKE ? ESCAPE '\\' ORDER BY created_at DESC, key DESC LIMIT 1",
        tenant, scope, likeEscape(r) & "%"]])["results"][0]{"values"}
      if v != nil and v.len > 0:
        result = Entry(found: true, key: v[0][0].getStr, s3Key: v[0][1].getStr, size: v[0][2].getBiggestInt, sha256: v[0][3].getStr, store: v[0][4].getStr)
        break
  if result.found: discard c.execute(%*[["UPDATE caches SET last_used_at = ? WHERE tenant_id = ? AND scope = ? AND key = ?", now, tenant, scope, result.key]])

proc beginEntry*(c: var RqClient; id, tenant, scope, key, s3Key: string; size: int64; sha256, state, uploadId: string; now: int64; store = ""): bool =
  ## False: the key is there already, stored or being uploaded (a key is immutable; a second saver gives way)
  c.execute(%*[["INSERT OR IGNORE INTO caches (id, tenant_id, scope, key, s3_key, size, sha256, state, upload_id, created_at, last_used_at, store) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    id, tenant, scope, key, s3Key, size, sha256, state, uploadId, now, now, store]])["results"][0]{"rows_affected"}.getInt > 0

proc setEntryUpload*(c: var RqClient; tenant, scope, key, uploadId: string) =
  discard c.execute(%*[["UPDATE caches SET upload_id = ? WHERE tenant_id = ? AND scope = ? AND key = ? AND state = 'uploading'", uploadId, tenant, scope, key]])

proc uploadingEntry*(c: var RqClient; tenant, scope, key: string): tuple[found: bool, s3Key, uploadId: string, size: int64, store: string] =
  let v = c.query(%*[["SELECT s3_key, upload_id, size, store FROM caches WHERE tenant_id = ? AND scope = ? AND key = ? AND state = 'uploading'", tenant, scope, key]])["results"][0]{"values"}
  if v != nil and v.len > 0: (true, v[0][0].getStr, v[0][1].getStr, v[0][2].getBiggestInt, v[0][3].getStr) else: (false, "", "", 0'i64, "")

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

proc dropObject(ss: StoreSet; store, key: string): bool =
  let rb = ss.resolve(store)
  if rb.be == nil: return false              # the store is not there (or its secret cannot be read now): the row stays for another pass
  let r = rb.be.deleteObject(key)
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

proc makeRoom*(c: var RqClient; ss: StoreSet; tenant, scope: string; needed: int64; shardQuota: int64): tuple[ok: bool, why: string] =
  ## The caches are bounded (E-003): an entry of `needed` bytes goes in when every limit that binds it holds - the organisation's, and those of its group and the groups
  ## above - the least recently used entries of that pool giving way. Not ok: it cannot fit even in an empty pool (bigger than the limit), or the store would not let an
  ## entry go; `why` names the limit.
  if needed > maxEntryBytes: return (false, "an entry is at most " & $maxEntryBytes & " bytes")
  for p in c.quotaPools(tenant, scope, shardQuota):
    if needed > p.quota: return (false, "the entry is bigger than " & p.name & " cache quota of " & $p.quota & " bytes")
    while c.poolBytes(tenant, p) + needed > p.quota:
      let v = c.query(%*[["SELECT c.id, c.s3_key, c.store FROM caches c WHERE c.tenant_id = ? AND c.state = 'stored'" & inPool & " ORDER BY c.last_used_at, c.created_at LIMIT 1",
        tenant, p.groupPath, p.groupPath, p.groupPath, p.groupPath]])["results"][0]{"values"}
      if v == nil or v.len == 0: return (false, "what is held under " & p.name & " cache quota is being uploaded, and is not taken")
      if not dropObject(ss, v[0][2].getStr, v[0][1].getStr): return (false, "the store would not let an entry go")
      discard c.execute(%*[["DELETE FROM caches WHERE id = ?", v[0][0].getStr]])
  (true, "")

type SweepReport* = object
  expired*, abandoned*, failed*: int

proc sweepCaches*(c: var RqClient; ss: StoreSet; now: int64; shardRetention = defaultRetention; abandonAfter = 86400'i64): SweepReport =
  ## one pass: entries not used for the retention of their scope (the group's, else the organisation's, else the shard's; 0 or less keeps for ever) go, and so does an upload
  ## that was begun and never ended
  let scopes = c.query(%*[["SELECT DISTINCT tenant_id, scope FROM caches WHERE state = 'stored' LIMIT 2000"]])["results"][0]{"values"}
  if scopes != nil:
    for sc in scopes:
      let retention = c.retentionSeconds(sc[0].getStr, sc[1].getStr, shardRetention)
      if retention <= 0: continue
      let v = c.query(%*[["SELECT id, s3_key, store FROM caches WHERE tenant_id = ? AND scope = ? AND state = 'stored' AND last_used_at < ? ORDER BY last_used_at LIMIT ?",
        sc[0].getStr, sc[1].getStr, now - retention, batch]])["results"][0]{"values"}
      if v != nil:
        for row in v:
          if dropObject(ss, row[2].getStr, row[1].getStr):
            discard c.execute(%*[["DELETE FROM caches WHERE id = ?", row[0].getStr]])
            inc result.expired
          else: inc result.failed
  if abandonAfter > 0:
    let v = c.query(%*[["SELECT id, s3_key, upload_id, store FROM caches WHERE state = 'uploading' AND created_at < ? ORDER BY created_at LIMIT ?", now - abandonAfter, batch]])["results"][0]{"values"}
    if v != nil:
      for row in v:
        var gone = true
        if row[2].getStr.len > 0:
          let rb = ss.resolve(row[3].getStr)
          let a = if rb.be == nil: fail("the store is not available: " & rb.error, retry = true) else: rb.be.abortMultipart(row[1].getStr, row[2].getStr)
          gone = a.ok or (not a.retry and ("no such" in a.error.toLowerAscii or "nosuchupload" in a.error.toLowerAscii))
        if gone:
          discard c.execute(%*[["DELETE FROM caches WHERE id = ?", row[0].getStr]])
          inc result.abandoned
        else: inc result.failed

# ------------------------------------------------------------------ the view of the caches (the API) and the deletion of entries by hand

type
  CacheRow* = object
    groupPath*, key*, state*, sha256*: string      ## groupPath "" is the organisation's own
    size*, createdAt*, lastUsedAt*: int64
  PoolUse* = object
    name*, groupPath*: string
    quota*, bytes*: int64                           ## quota 0: no limit

proc listCaches*(c: var RqClient; tenant, groupPath: string; limit = 500): seq[CacheRow] =
  ## The entries of an organisation, the most recently used first; with a group's path, those of the group and of the groups below it.
  let gp = groupPath.strip(chars = {'/'})
  let v = c.query(%*[["SELECT COALESCE(g.path, ''), c.key, c.state, c.size, c.created_at, c.last_used_at, c.sha256 FROM caches c LEFT JOIN groups g ON g.id = c.scope " &
    "WHERE c.tenant_id = ?" & inPool & " ORDER BY c.last_used_at DESC, c.key LIMIT ?", tenant, gp, gp, gp, gp, max(1, min(limit, 1000))]])["results"][0]{"values"}
  if v != nil:
    for row in v:
      result.add CacheRow(groupPath: row[0].getStr, key: row[1].getStr, state: row[2].getStr, size: row[3].getBiggestInt, createdAt: row[4].getBiggestInt,
                          lastUsedAt: row[5].getBiggestInt, sha256: row[6].getStr)

proc poolUsage*(c: var RqClient; tenant: string; shardQuota: int64): seq[PoolUse] =
  ## What each limit that binds holds now: the organisation's (its own quota, else the shard's; -1 is none) and those of the groups that have one of their own
  let o = c.orgLimit(tenant)
  let oq = if o.quota == 0: shardQuota elif o.quota < 0: 0'i64 else: o.quota
  result.add PoolUse(name: "organization", quota: oq, bytes: c.bytesHeld(tenant))
  let v = c.query(%*[["SELECT g.path, s.cache_quota_bytes FROM group_settings s JOIN groups g ON g.id = s.group_id WHERE g.tenant_id = ? AND s.cache_quota_bytes > 0 ORDER BY g.path", tenant]])["results"][0]{"values"}
  if v != nil:
    for row in v:
      let p = Pool(quota: row[1].getBiggestInt, groupPath: row[0].getStr)
      result.add PoolUse(name: "group", groupPath: p.groupPath, quota: p.quota, bytes: c.poolBytes(tenant, p))

proc deleteEntries*(c: var RqClient; ss: StoreSet; tenant, scope, key: string): tuple[deleted, failed: int] =
  ## The stored entries of exactly this scope ('' the organisation's own): the one named by `key`, or every one when `key` is empty. Entries being uploaded stay; the next run that
  ## looks for one finds a miss.
  var sql = "SELECT id, s3_key, store FROM caches WHERE tenant_id = ? AND scope = ? AND state = 'stored'"
  var args = %*[sql, tenant, scope]
  if key.len > 0:
    sql.add " AND key = ?"
    args = %*[sql, tenant, scope, key]
  let v = c.query(%*[args])["results"][0]{"values"}
  if v != nil:
    for row in v:
      if dropObject(ss, row[2].getStr, row[1].getStr):
        discard c.execute(%*[["DELETE FROM caches WHERE id = ?", row[0].getStr]])
        inc result.deleted
      else: inc result.failed
