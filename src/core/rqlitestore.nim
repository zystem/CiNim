## StateStore on rqlite (DAT-010: state and leadership live in the rqlite of the shard). Compare-and-set through a revision column.

import std/[json, strutils]
import ../common/rqlite
import logcircuit

type RqliteStore* = ref object of StateStore
  client: RqClient
  table: string

proc newRqliteStore*(url: string; table = "coordinator_state"): RqliteStore =
  result = RqliteStore(client: newRq(url), table: table)
  discard result.client.execute(%*["CREATE TABLE IF NOT EXISTS " & table &
    " (key TEXT PRIMARY KEY, value TEXT NOT NULL, rev INTEGER NOT NULL)"])

proc dropTable*(url, table: string) =
  var c = newRq(url)
  discard c.execute(%*["DROP TABLE IF EXISTS " & table])

method get*(s: RqliteStore; key: string): (string, int) =
  let r = s.client.query(%*[["SELECT value, rev FROM " & s.table & " WHERE key = ?", key]])
  let vals = r["results"][0]{"values"}
  if vals == nil or vals.len == 0: raise newException(StoreNotFound, key)
  (vals[0][0].getStr, vals[0][1].getInt)

method create*(s: RqliteStore; key, value: string): int =
  try:
    discard s.client.execute(%*[["INSERT INTO " & s.table & " (key, value, rev) VALUES (?, ?, 1)", key, value]])
  except RqError as e:
    if "UNIQUE" in e.msg or "constraint" in e.msg.toLowerAscii: raise newException(StoreConflict, key)
    raise
  1

method update*(s: RqliteStore; key, value: string; rev: int): int =
  ## rqlite omits rows_affected when it is 0, so "not applied" is the absence of the field (ADR 0004)
  let r = s.client.execute(%*[["UPDATE " & s.table & " SET value = ?, rev = rev + 1 WHERE key = ? AND rev = ?", value, key, rev]])
  if r["results"][0]{"rows_affected"}.getInt(0) != 1:
    discard s.get(key)                         # raises StoreNotFound when the key does not exist at all
    raise newException(StoreConflict, key)
  rev + 1

method keys*(s: RqliteStore; prefix: string): seq[string] =
  let r = s.client.query(%*[["SELECT key FROM " & s.table & " WHERE substr(key, 1, length(?)) = ?", prefix, prefix]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for row in vals: result.add row[0].getStr
