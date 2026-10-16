## What a step says about its cache (DAT-004): the `cache` option of the step, as bootstrap.lua normalised it into the step's options JSON,
##     "cache": [{"key": "deps-v1", "paths": ["node_modules"], "restore_keys": ["deps-"]}]
## Pure, shared by the core (which checks it when it takes the step and decides what a step may find and save) and the shim (which does it).
import std/[json, strutils, sequtils]

const
  maxKeyLen* = 200
  maxPaths* = 20
  maxRestoreKeys* = 5
  maxCaches* = 4
  maxEntryBytes* = 2'i64 * 1024 * 1024 * 1024

type CacheDecl* = object
  key*: string
  mode*: string                  ## "" restore before the command and save after it; "restore" or "save" only (the steps of `j.cache.restore` and `j.cache.save`)
  paths*, restoreKeys*: seq[string]

func validCacheKey*(k: string): bool =
  ## letters, digits and . _ : + = @ % -, 1..200; no '/', so that a key is one name
  if k.len < 1 or k.len > maxKeyLen: return false
  for ch in k:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', ':', '+', '=', '@', '%', '-'}: return false
  true

func validCachePath*(p: string): bool =
  ## a file or a directory under the workspace: relative, no `..`, no control character
  if p.len < 1 or p.len > 512 or p[0] == '/' or p.endsWith("/"): return false
  for ch in p:
    if ch < ' ' or ch == '\x7f' or ch == '\\': return false
  for part in p.split('/'):
    if part.len == 0 or part == "." or part == "..": return false
  true

proc cacheDecls*(optsJson: string): seq[CacheDecl] =
  ## what the step's options declared, as the Lua side normalised it; damaged options declare nothing
  if optsJson.len == 0: return
  try:
    let a = parseJson(optsJson){"cache"}
    if a == nil or a.kind != JArray: return
    for e in a.elems:
      if e.kind != JObject: continue
      var d = CacheDecl(key: e{"key"}.getStr, mode: e{"mode"}.getStr)
      if e{"paths"} != nil and e["paths"].kind == JArray:
        for p in e["paths"].elems: (if p.kind == JString: d.paths.add p.getStr)
      if e{"restore_keys"} != nil and e["restore_keys"].kind == JArray:
        for p in e["restore_keys"].elems: (if p.kind == JString: d.restoreKeys.add p.getStr)
      result.add d
  except CatchableError: discard

proc checkCacheDecl*(optsJson: string): string =
  ## "" if the step's cache declaration may be taken, else why not (the core's answer to the script)
  let ds = cacheDecls(optsJson)
  if ds.len > maxCaches: return "a step has at most " & $maxCaches & " caches"
  for d in ds:
    if not validCacheKey(d.key): return "a cache key is 1.." & $maxKeyLen & " characters: letters, digits and . _ : + = @ % - (" & d.key & ")"
    if d.mode notin ["", "restore", "save"]: return "the cache " & d.key & ": the mode is restore or save"
    if d.mode == "restore" and d.paths.len > maxPaths: return "the cache " & d.key & " has at most " & $maxPaths & " paths"
    elif d.mode != "restore" and (d.paths.len == 0 or d.paths.len > maxPaths): return "the cache " & d.key & " needs 1.." & $maxPaths & " paths"
    for p in d.paths:
      if not validCachePath(p): return "the cache " & d.key & ": " & p & " is not a path inside the workspace"
    if d.restoreKeys.len > maxRestoreKeys: return "the cache " & d.key & " has at most " & $maxRestoreKeys & " restore keys"
    for k in d.restoreKeys:
      if not validCacheKey(k): return "the cache " & d.key & ": " & k & " is not a restore key"

func mayFind*(ds: seq[CacheDecl]; key: string): bool =
  ## a step may ask for the entry it declared, or one that one of its restore keys names (a prefix)
  for d in ds:
    if key == d.key: return true
    for r in d.restoreKeys:
      if key.startsWith(r): return true

func maySave*(ds: seq[CacheDecl]; key: string): bool = ds.anyIt(it.key == key)

