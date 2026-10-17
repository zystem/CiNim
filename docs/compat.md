# Compatibility code to delete (a list, so that it is not forgotten)

The project has no release yet and the owner has said that compatibility with old data is not worth keeping for long. Each line below is code that exists only so that
something made **before** a change still works. Delete it when its condition is met, in the same commit as the change that makes it unnecessary, and strike the line here.
Found by reading the code on 2026-10-11 (`grep` for "legacy", "from before", "wire compat"); this is not a promise that nothing else is left.

| What | Where | Why it exists | Delete when |
|---|---|---|---|
| The columns of the controller's state added by `ALTER TABLE` | `jobcontroller/ctrlstate.nim` (line "state files from before these columns") | controller state files from before | the state volumes of the controllers are made again, or a migration number replaces the ALTERs |
| The `ALTER TABLE … ADD COLUMN` list of the core | `core/schema.nim` (`migrate`) | databases from before each column | when there is a first release: fold the columns into `CREATE TABLE` and number the migrations |
| `project_id` dropped from `runs` and `triggers`, and its index (D-54) | `core/schema.nim` (`migrate`, the loop over `runs` and `triggers`) | a shard made before D-54 has the column, which is NOT NULL and has no default | every shard has migrated (the TESTING cluster's has); then the loop goes |
| `DROP TABLE object_stores`, `store_repair`, the `OBJECTSTORE_SECRET_KEY:*` secrets of `_platform` and `vault_meta` `objectstore` | `core/schema.nim` (`migrate`, after the DDL) | a shard made before D-60 kept its stores in the core | every shard has migrated; then the four statements go |
| The data operations of the core's ArtifactIngest: `put_object`, `put_part` and `get_block` carrying the bytes, and `put_end` without digests (D-61) | `core/artifactingest.nim` (`handleArtifact`, `handleCache`), `shim/logclient.nim` (`putViaCore`, the core branch of `fetchTo`) | shims from before the direct transfer, a shard without `storage.directUrl`, and the fallback of a shim that cannot reach the module | every shim in use is new and every shard has the port for shims; then the bytes never come to the core and these go |
| The host call `sh` and `ci.sh` (a fixture of the tests) | `executor/replay.nim` (`hostKinds`), `executor/bootstrap.lua`, `tests/unit/tluaapi.nim` (`fixtureOnly`) | the early tests of the sandbox | the tests use `Job:sh` |

## Deleted (2026-10-11)

* A namespace with no controller identity trusted (`vLegacy`): `decide` refuses it now (T-46). Development and tests that run a controller without an identity say so, `CINIM_UNENROLLED_CONTROLLERS=on` (a switch for development, not a compatibility path: the core warns at start; an enrolled namespace is never opened by it).
* The journal read by place, a row without `call_key` read as `key = place`: there is no such reading (the keys are built, docs/parallel.md section 4).
* The shared executor service (`src/executorsvc`, `ExecutorChannel` on port 19741, the chart's executor Deployment, the lease request of the protocol, `handleLease`, `leaseCandidates`): the conductors lead every run; the chart has no `conductor.enabled` any more.
* A host call with `numbered` false: the core refuses a `job_sh` without a number (`executor_too_old`); `steps.journal_seq` is gone.
* A journal record without a key (the plan was to read it as `m#<seq + 1>`): there is no such reading; the keys came in the same rollout and the runs with journals from before were deleted from the live database. `run_journal.call_key` is `''` only in the tests that forge a record.
* A journal without a hash chain (`cvLegacy`, `adoptLegacyLocked`, `legacyHashes`): such a journal is `journal_corrupt` like any other that does not hold; the runs of the live database that had one were deleted.
* The executors chain no record of their own: a record without a hash is `journal_corrupt` at replay.
* An empty `api_versions` as version 1, and `api_version` 0 as 1: a lease request that names no versions is refused (`executor_too_old`).
* `ExecutorRequest.finish_run_id`: removed, number 4 reserved; the baseline of the protocol check (`proto/compat/baseline.binpb`) was made again, because it dated from the first commit and the check had been failing already on the rename of `secret_handles`.

Not compatibility but interim, and to be replaced: the script of a run kept as a journal row with `seq = -1` (no store for pipeline bundles yet).
