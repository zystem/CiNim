## The named stores of the module (docs/storage-module.md): a store is an S3 bucket (Garage, `kind: s3`) or a mirror of Caddy nodes with WebDAV (`kind: dav`, docs/store.md). The settings are
## a row of `storage_stores`; the secret (the S3 secret key, or the token the requests to the nodes are signed with) is sealed under the module's key (seal.nim) with the store's name as
## additional data. The operator's calls change them (service.nim, `/v1/admin/...`); the core's calls only read the names.
import std/[json, strutils, sequtils]
import ../common/[rqlite, sigv4, storagebackend]
import schema, seal, s3backend, httpstore, replicas

type
  StoreConfig* = object
    kind*: string                ## "s3" or "dav"
    endpoint*, region*, bucket*, keyId*: string       ## s3
    nodes*: seq[string]          ## dav: http://host:port or https://host:port of each node
    minAcks*: int                ## dav: 0 means every node must confirm a write

  StoreEntry* = object
    name*: string
    cfg*: StoreConfig
    isDefault*: bool

  Loaded* = object
    ok*: bool
    name*: string
    cfg*: StoreConfig
    secret*: string
    error*: string               ## no_such_store, not_configured, unreadable
    retry*: bool

func validStoreName*(name: string): bool =
  ## lowercase letters, digits and `-`, starting with a letter, at most 32
  if name.len < 1 or name.len > 32 or name[0] notin {'a' .. 'z'}: return false
  for ch in name:
    if ch notin {'a' .. 'z', '0' .. '9', '-'}: return false
  true

func checkConfig*(cfg: StoreConfig; secret: string): string =
  ## "" if these may be the settings of the store, else what is wrong
  if cfg.kind == "dav":
    if cfg.nodes.len < 1 or cfg.nodes.len > 4: return "nodes is 1..4 URLs of store nodes"
    for a in cfg.nodes:
      let rest = if a.startsWith("https://"): a[8 .. ^1] elif a.startsWith("http://"): a[7 .. ^1] else: ""
      if rest.len == 0 or a.len > 200 or a.anyIt(it < '!' or it > '~') or rest.split('/')[0].count(':') != 1 or '?' in a or '#' in a: return "a node is http://host:port or https://host:port"
    if cfg.minAcks < 0 or cfg.minAcks > cfg.nodes.len: return "min_acks is 0 (every node, the default) or 1.." & $cfg.nodes.len
    if secret.len < 8 or secret.len > 256 or secret.anyIt(it < '!' or it > '~'): return "token is 8..256 printable characters"
    return ""
  if cfg.kind != "s3": return "kind is s3 (a bucket) or dav (store nodes)"
  if not splitEndpoint(cfg.endpoint).ok: return "endpoint is scheme://host[:port], http or https, with no path"
  if cfg.region.len == 0 or cfg.region.len > 64 or cfg.region.anyIt(it notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_'}): return "region is letters, digits, - and _"
  if cfg.bucket.len < 3 or cfg.bucket.len > 63 or cfg.bucket.anyIt(it notin {'a' .. 'z', '0' .. '9', '-', '.'}): return "bucket is 3..63 lowercase letters, digits, - and ."
  if cfg.keyId.len == 0 or cfg.keyId.len > 128 or cfg.keyId.anyIt(it < '!' or it > '~'): return "access_key_id is 1..128 printable characters"
  if secret.len == 0 or secret.len > 256 or secret.anyIt(it < '!' or it > '~'): return "secret_access_key is 1..256 printable characters"
  ""

func isMirror*(cfg: StoreConfig): bool = cfg.kind == "dav"

proc configJson(cfg: StoreConfig): string =
  $(%*{"endpoint": cfg.endpoint, "region": cfg.region, "bucket": cfg.bucket, "key_id": cfg.keyId, "nodes": cfg.nodes, "min_acks": cfg.minAcks})

proc configOf(kind, config: string): StoreConfig =
  try:
    let j = parseJson(config)
    result = StoreConfig(kind: kind, endpoint: j{"endpoint"}.getStr, region: j{"region"}.getStr, bucket: j{"bucket"}.getStr, keyId: j{"key_id"}.getStr, minAcks: j{"min_acks"}.getInt(0))
    if j{"nodes"} != nil and j["nodes"].kind == JArray:
      for a in j["nodes"].elems: result.nodes.add a.getStr
  except CatchableError: result = StoreConfig()

proc listStores*(c: var RqClient): seq[StoreEntry] =
  let v = c.query(%*[["SELECT name, kind, config, is_default FROM storage_stores ORDER BY name"]])["results"][0]{"values"}
  if v != nil:
    for row in v: result.add StoreEntry(name: row[0].getStr, cfg: configOf(row[1].getStr, row[2].getStr), isDefault: row[3].getInt == 1)

proc defaultStoreName*(c: var RqClient): string =
  let v = c.query(%*[["SELECT name FROM storage_stores WHERE is_default = 1"]])["results"][0]{"values"}
  if v != nil and v.len > 0: v[0][0].getStr else: ""

proc setDefaultStore*(c: var RqClient; name: string): bool =
  ## false if there is no such store
  if c.query(%*[["SELECT count(*) FROM storage_stores WHERE name = ?", name]])["results"][0]{"values"}[0][0].getInt == 0: return false
  discard c.execute(%*[["UPDATE storage_stores SET is_default = CASE WHEN name = ? THEN 1 ELSE 0 END", name]])
  true

proc objectCount*(c: var RqClient; store: string): int64 =
  c.query(%*[["SELECT count(*) FROM storage_objects WHERE store = ?", store]])["results"][0]{"values"}[0][0].getBiggestInt

proc saveStore*(c: var RqClient; key: openArray[byte]; name: string; cfg: StoreConfig; secret: string; makeDefault: bool; now: int64): string =
  ## "" if done, else why not. A store is made or replaced; the first one is the default, and so is one that asks for it.
  if not validStoreName(name): return "a store's name is lowercase letters, digits and -, starting with a letter, at most 32"
  let why = checkConfig(cfg, secret)
  if why.len > 0: return why
  discard c.execute(%*[["INSERT INTO storage_stores (name, kind, config, secret, is_default, created_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?) " &
    "ON CONFLICT(name) DO UPDATE SET kind = excluded.kind, config = excluded.config, secret = excluded.secret, updated_at = excluded.updated_at",
    name, cfg.kind, configJson(cfg), seal(key, name, secret), now, now]])
  # the default is the first store; "no default" rather than "no store" is the test, so that a registration that was cut off between the row and the mark is put right by the next one
  if makeDefault or c.defaultStoreName().len == 0: discard c.setDefaultStore(name)
  ""

proc forgetStore*(c: var RqClient; name: string; force: bool): string =
  ## "" if done. Refused while the inventory holds objects of the store (`force` goes on: the objects stay where they are, only the module forgets the store), and for the default one while
  ## there is another (make that one the default first).
  let v = c.query(%*[["SELECT is_default FROM storage_stores WHERE name = ?", name]])["results"][0]{"values"}
  if v == nil or v.len == 0: return "no such store"
  let held = c.objectCount(name)
  if held > 0 and not force: return "the store holds " & $held & " object(s); forget it with force=1 to leave them where they are"
  if v[0][0].getInt == 1 and c.query(%*[["SELECT count(*) FROM storage_stores WHERE name != ?", name]])["results"][0]{"values"}[0][0].getInt > 0:
    return "this is the default store: make another one the default first"
  discard c.execute(%*[["DELETE FROM storage_stores WHERE name = ?", name], ["DELETE FROM storage_objects WHERE store = ?", name], ["DELETE FROM storage_repair WHERE store = ?", name]], transaction = true)
  ""

proc loadStore*(c: var RqClient; key: openArray[byte]; name: string): Loaded =
  ## the store `name` ("" is the default one) with its secret, ready to use
  let want = if name.len > 0: name else: c.defaultStoreName()
  if want.len == 0:
    result.error = "not_configured"
    return
  let v = c.query(%*[["SELECT kind, config, secret FROM storage_stores WHERE name = ?", want]])["results"][0]{"values"}
  if v == nil or v.len == 0:
    result.error = "no_such_store"
    return
  let opened = unseal(key, want, v[0][2].getStr)
  if not opened.ok:
    result.error = "unreadable"
    return
  result = Loaded(ok: true, name: want, cfg: configOf(v[0][0].getStr, v[0][1].getStr), secret: opened.plain)

proc davSecrets*(c: var RqClient; key: openArray[byte]): seq[string] =
  ## the tokens the requests to HTTP nodes are signed with, one per `dav` store: what a node's `forward_auth` is answered with (service.nim)
  let v = c.query(%*[["SELECT name, secret FROM storage_stores WHERE kind = 'dav'"]])["results"][0]{"values"}
  if v != nil:
    for row in v:
      let opened = unseal(key, row[0].getStr, row[1].getStr)
      if opened.ok: result.add opened.plain

proc backend*(l: Loaded; onMissed: MissedProc = nil): ObjectBackend =
  ## the store as the module talks to it; the one place that says which backend it is
  if l.cfg.kind == "dav":
    return newHttpMirror(l.cfg.nodes.mapIt(newHttpNode(it, l.secret)), l.cfg.minAcks, onMissed)
  S3Backend(endpoint: l.cfg.endpoint, region: l.cfg.region, bucket: l.cfg.bucket, keyId: l.cfg.keyId, secret: l.secret)
