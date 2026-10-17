## The tables of the storage module (docs/storage-module.md). The module keeps no state of its own on a disk: everything is here, in the rqlite of the shard it belongs to (or of its
## own, for a module that serves several shards), and every table is named `storage_*` so that the module never touches a table of the core and the core never touches these.
import std/json
import ../common/rqlite

const ddl = [
  # the named stores; the secret (an S3 secret key, or the token of the HTTP nodes) is sealed with the module's own key (core of the module: seal.nim)
  """CREATE TABLE IF NOT EXISTS storage_stores (
       name TEXT PRIMARY KEY, kind TEXT NOT NULL, config TEXT NOT NULL, secret TEXT NOT NULL,
       is_default INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)""",
  # every object the module accepted: what the repair and the check compare the nodes of a mirror with. `key` is the key in the store, with the shard in front.
  """CREATE TABLE IF NOT EXISTS storage_objects (
       store TEXT NOT NULL, key TEXT NOT NULL, size INTEGER NOT NULL, written_at INTEGER NOT NULL, PRIMARY KEY (store, key))""",
  # what a node of a mirror has to be given (`copy`) or to lose (`delete`) for a key; the last operation on a key and a node wins
  """CREATE TABLE IF NOT EXISTS storage_repair (
       store TEXT NOT NULL, key TEXT NOT NULL, node TEXT NOT NULL, op TEXT NOT NULL, since INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
       next_at INTEGER NOT NULL DEFAULT 0, last_error TEXT NOT NULL DEFAULT '', PRIMARY KEY (store, key, node))""",
  "CREATE INDEX IF NOT EXISTS storage_repair_due ON storage_repair (next_at)",
  # the parts of an upload that a shim sent straight to the module (D-61): the digest the module made of the bytes it received, and their number; the core compares them with what the shim
  # reported over its own channel before it completes the upload
  """CREATE TABLE IF NOT EXISTS storage_parts (
       store TEXT NOT NULL, key TEXT NOT NULL, upload TEXT NOT NULL, part INTEGER NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL, written_at INTEGER NOT NULL,
       PRIMARY KEY (store, key, upload, part))""",
  # a job that only one replica of the module does at a time (the repair pass): the holder and the time its hold ends
  """CREATE TABLE IF NOT EXISTS storage_lease (name TEXT PRIMARY KEY, holder TEXT NOT NULL, until INTEGER NOT NULL)""",
]

proc migrate*(c: var RqClient) =
  var stmts = newJArray()
  for s in ddl: stmts.add %s
  discard c.execute(stmts, transaction = true)
