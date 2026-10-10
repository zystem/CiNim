# Compatibility code to delete (a list, so that it is not forgotten)

The project has no release yet and the owner has said that compatibility with old data is not worth keeping for long. Each line below is code that exists only so that
something made **before** a change still works. Delete it when its condition is met, in the same commit as the change that makes it unnecessary, and strike the line here.
Found by reading the code on 2026-10-11 (`grep` for "legacy", "from before", "wire compat"); this is not a promise that nothing else is left.

| What | Where | Why it exists | Delete when |
|---|---|---|---|
| Journal entries found by **place**, a row without `call_key` read as `key = place` | will be in `executor/replay.nim`, `core/journaldb.nim` once `call_key` is built (docs/parallel.md section 9a) | runs made before the keys | the runs made before the keys are over or purged; then the column is required |
| A namespace with no controller identity is trusted (`vLegacy`) | `common/ctrlauth.nim`, `core/scheduler.nim` (`handlePoll`) | single-tenant set-ups and tests, where the controller has no bootstrap token | every controller of a shard is enrolled (organisations are, since the core provisions them); then an empty or unknown namespace is refused. **This one is about security**, do it before a first user |
| The columns of the controller's state added by `ALTER TABLE` | `jobcontroller/ctrlstate.nim` (line "state files from before these columns") | controller state files from before | the state volumes of the controllers are made again, or a migration number replaces the ALTERs |
| The `ALTER TABLE … ADD COLUMN` list of the core | `core/schema.nim` (`migrate`) | databases from before each column | when there is a first release: fold the columns into `CREATE TABLE` and number the migrations |
| The host call `sh` and `ci.sh` (a fixture of the tests) | `executor/replay.nim` (`hostKinds`), `executor/bootstrap.lua`, `tests/unit/tluaapi.nim` (`fixtureOnly`) | the early tests of the sandbox | the tests use `Job:sh` |

## Deleted (2026-10-11)

* The shared executor service (`src/executorsvc`, `ExecutorChannel` on port 19741, the chart's executor Deployment, the lease request of the protocol, `handleLease`, `leaseCandidates`): the conductors lead every run; the chart has no `conductor.enabled` any more.
* A step with `journal_seq` NULL at `ordinal`, a host call with `numbered` false: the core refuses a `job_sh` without a number (`executor_too_old`); the column is always set; the live database was filled in by hand before the rollout.
* A journal without a hash chain (`cvLegacy`, `adoptLegacyLocked`, `legacyHashes`): such a journal is `journal_corrupt` like any other that does not hold; the runs of the live database that had one were deleted.
* The executors chain no record of their own: a record without a hash is `journal_corrupt` at replay.
* An empty `api_versions` as version 1, and `api_version` 0 as 1: a lease request that names no versions is refused (`executor_too_old`).
* `ExecutorRequest.finish_run_id`: removed, number 4 reserved; the baseline of the protocol check (`proto/compat/baseline.binpb`) was made again, because it dated from the first commit and the check had been failing already on the rename of `secret_handles`.

Not compatibility but interim, and to be replaced: the script of a run kept as a journal row with `seq = -1` (no store for pipeline bundles yet).
