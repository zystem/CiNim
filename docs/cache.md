# Cache

A **cache** keeps files between runs: the dependencies a build downloads every time, a compiler's output. It is not an artifact (docs/artifacts.md): an artifact is a result of one run that people or later steps read; a cache is a convenience that a run may find or not, and that lives for as long as it is used. Requirement: DAT-004.

## In a pipeline

```lua
ci.job({ image = "node:22", cache = { key = "npm-" .. run.params.LOCKFILE_HASH, paths = { "node_modules" }, restore_keys = { "npm-" } } }, function(j)
  j:sh("npm ci && npm test")
end)
```

* `cache` is an option of `ci.job` and of `Job:sh`, one table or a list of up to 4. A job's declaration and a step's are added together; the same key is the step's.
* **key**: 1 to 200 characters, letters, digits and `. _ : + = @ % -` (no `/`). **paths**: 1 to 20 files or directories of the workspace, relative, without `..`. **restore_keys**: up to 5 prefixes.
* **Before the command** the shim restores the entry with the key, or, if there is none, the **latest** entry whose key starts with the first restore key that matches (they are tried in order), into the workspace. A miss is a line in the log and the command runs on.
* **After a command that succeeded** the shim saves the paths under the key, **unless the key was found**: a key is **immutable**, an entry is never replaced. To change a cache, change its key (a hash of the lock file is the usual way). A command that failed or was cut off saves nothing. When two runs save the same key at once, one gives way (the log says so).
* A cache never fails a step. A miss, a store that does not answer, an archive that is damaged or refused is a line in the step's log (`cicd-shim: cache npm-1: restored from npm-0 (1200 files, 31457280 bytes)`, `miss`, `saved`, `not saved (...)`).

## Restore and save in the middle of a job (`j.cache`)

The signatures of the API v1 (`lua/stdlib/cicd.d.lua`) give a job two calls of its own, each a step in the job's Pod on the run's workspace:

```lua
ci.job({ image = "node:22" }, function(j)
  local got = j.cache.restore({ "npm-" .. run.params.LOCKFILE_HASH, "npm-" })   -- the key, then key prefixes to fall back on
  if not got.hit then j:sh("npm ci") end                                          -- got.hit, and got.key: the key that was restored
  j:sh("npm test")
  j.cache.save("npm-" .. run.params.LOCKFILE_HASH, { "node_modules" })
end)
```

* `restore(keys)`: 1 to 6 keys; the first is the key itself, the others are prefixes as `restore_keys` (the latest entry that starts with one). It returns `{hit = true, key = <the key restored>}` or `{hit = false}`. A miss is not an error. The shim says which key it restored, the core writes that in the step's result in the journal, so a replay sees the same answer.
* `save(key, paths)`: packs the paths and stores them under the key, as the `cache` option does after a command; a key that is stored already is not an error (a key is immutable). It saves nothing if the step does not succeed.
* Each is a step (it counts toward the 200 of a run) and needs a shell in the job's image, like `Job:sh`. They do not touch the job's own `cache` option, which belongs to the steps of `j:sh`. The two modes are `mode` in the step's options (`"restore"` needs no path; `"save"` needs them).

## The view and the deletion by hand

```
GET    /api/v1/organizations/{slug}/caches[?group=<path>&limit=500]     every role that reads
DELETE /api/v1/organizations/{slug}/caches?key=<key>[&group=<path>]     rw, admin: one entry of exactly one scope
DELETE /api/v1/organizations/{slug}/caches?all=true[&group=<path>]      rw, admin: every entry of exactly that scope
```

`GET` lists the entries, the most recently used first (`group`, `key`, `state`, `size`, `sha256`, `created_at`, `last_used_at`; with `group` those of the group and of the groups below it), and `pools`: what each limit that binds holds now - the organisation's (`quota` 0 is none) and the groups that have a quota of their own. `DELETE` takes stored entries out of the store and the database; the scope is the group in `group`, and with none the organisation's own entries (a group's entries are not touched by a delete of its parent). An entry that is being uploaded stays; the next run that looks for a deleted key finds a miss. A deletion is in the audit (`cache.delete`).

## What it is and where it is

An entry is one archive in the object store (docs/artifacts.md), named by the organisation, the **group** the run is in (the groups of docs/variables.md; a run sees the caches of its own group only, and a run of the organisation itself those of the organisation) and a hash of the key. The shim packs the paths into a tar stream cut into 4 MiB chunks, each compressed (gzip) on its own, so that nothing is held in memory but a chunk (`shim/cachepack.nim`), and sends them to the core over the channel of the artifacts (port 19744), which puts them into the store; the steps never reach the store. The archive is a file on the run's volume for a while, not in the Pod's ephemeral storage. The SHA-256 is checked after the fetch.

* An entry is at most 2 GiB.

## The limits: the shard, the organisation, the groups

Two limits, each set at three places: the shard's (the defaults, `CINIM_CACHE_QUOTA` 10 GiB and `CINIM_CACHE_RETENTION` 7 days; the Helm values `cache.quota` and `cache.retention`), the organisation's, and a group's.

| | the organisation (`PUT /api/v1/profile?organization=<slug>`, docs/settings.md) | a group (`PUT /api/v1/organizations/{slug}/groups/{path}/settings`) |
|:---|:---|:---|
| **quota** `cache_quota_bytes` | 0 the shard's; **-1 no limit**; 1 MiB..1 PiB | 0 nothing of its own; 1 MiB..1 PiB |
| **retention** `cache_retention_days` | 0 the shard's; **-1 for ever**; 1..3650 | 0 the level above decides; -1 for ever; 1..3650 |

* **Quota** is a pool. The organisation's limit bounds all its caches. A group's limit bounds the entries **of that group and of every group below it** (not its neighbours); the organisation's also holds over them. An entry is saved when **every limit that binds it holds**: for each pool from the organisation down to the entry's own group, the entries of that pool **used least recently go first** until the new one fits. An entry bigger than a limit is refused (`quota_exceeded`, in the log, with the limit it broke).
* **Retention** is for one entry: the **nearest group** (from the entry's own group up) that says something wins, then the organisation, then the shard. An entry not used (restored from) for that long is deleted by the core's sweep, every ten minutes together with the artifacts; so is an upload that was begun and never ended for a day.
* `GET .../groups/{path}/settings` shows what the group has set and `effective_cache_retention_seconds` (0 is for ever).
* A step may find and read only what it declared (its key, or what one of its restore keys names), and save only its own key.

## Security

The cache is the classic way to poison a build: what a run saved, a later run unpacks. What is done about it here: the entries are separated by organisation and by group; a key is immutable, so a later run cannot replace an entry that other runs rely on; the archive is unpacked strictly (a name that is absolute or has `..`, a type other than a file, a directory and a symbolic link, a path whose parent is a symbolic link and a link that points out of the workspace are refused, counted, and shown in the log); a file is hashed and checked. **Not built:** the separation of trusted and untrusted refs (pull requests from forks, DAT-004): there are no refs in a run yet; until there are, a group is the boundary, and a group that runs untrusted code should not share its caches with one that deploys.

## Checked

Unit tests of the archive (`tcachepack`: round trip with modes, links, empty files, a file bigger than a chunk, long names, damaged and cut archives, the attacks above) and of the declaration (`tpipeline`); integration tests of the choice of the entry, the immutability, the room, the sweep and the requests of the channel against a store in memory (`tcache`).

On the TESTING cluster (2026-10-13): a run with `cache = {key = "npm-1", paths = {"deps"}, restore_keys = {"npm-"}}` (a 3 MB random file and a text file): the first said `miss` and `saved (2 files, 3003663 bytes)`; the second, with the same key, said `restored from npm-1` and its command printed the same SHA-256 of the random file, and `not saved (the key was restored, and a key is immutable)`; a third with the key `npm-2` and the restore key `npm-` said `restored from npm-1` and saved `npm-2`; the same key in the group `team` said `miss` (the groups do not share). A first attempt found that a step with only a cache was not given the credential of the channel (`not restored (…no credential)`); it is now, and a test says so. The limits (2026-10-13): the organisation's profile took `cache_quota_bytes` and `cache_retention_days` and refused 5 bytes; the group `team` was given a quota of 5 MB and a retention of 2 days, and its subgroup `team/sub` showed `effective_cache_retention_seconds` of 172800 (inherited); a cache of 3 MB saved in `team`, another of 3 MB saved in `team/sub` made room by dropping the first (the pool of `team` holds its subgroups), and asking for the first again was a `miss`; a value a group may not have was refused. Not checked: an entry of more than one block (several parts; the requests are those of the artifacts and a test of the core covers them), a quota that makes room, the sweep against the real store, a cache of tens of thousands of files.

Unit tests of `j.cache.restore` and `j.cache.save` (`tpipeline`: the options they make, the answer, a failing step, what they refuse); integration tests of the answer of a restore step in the journal (`tcacherestore`) and of the view, the pools and the deletion by hand (`tcache`). Not checked on a cluster: the shim's restore and save in the two modes, and the answer reaching the script.

## Not built

The separation of trusted and untrusted refs; a cache that several keys share; a view of the caches in the UI (there is no UI yet).
