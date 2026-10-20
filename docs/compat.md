# Compatibility code to delete (a list, so that it is not forgotten)

The project has no release yet and the owner has said that compatibility with old data is not worth keeping for long. Each line below is code that exists only so that
something made **before** a change still works. Delete it when its condition is met, in the same commit as the change that makes it unnecessary, and strike the line here.
Found by reading the code on 2026-10-11 (`grep` for "legacy", "from before", "wire compat"); this is not a promise that nothing else is left.

*Nothing is left (2026-10-18).* A new line goes into this table when code is written that exists only for something made before a change.


## To delete when its condition is met

| Code | Why it exists | Delete when |
|---|---|---|
| `src/common/connecthttp.nim` and its use in `core/transitclient.nim` (`callViaConnect`), `tests/unit/tconnecthttp.nim`, `tests/support/connectproxy.nim` | the `std/httpclient` of Nim 2.2.6 wrote `GET host:port/path` inside the CONNECT tunnel (nim-lang/Nim#25319; fixed in 2.2.8) | every image and every workstation builds with Nim >= 2.2.8 and a test of `std/httpclient` through a real tinyproxy passes (`HSMGATE_TEST_PROXY`): then the client can use `newHttpClient(proxy = ...)` again. Not urgent: the code is correct on every version |

## Deleted (2026-10-18, the second part)

* The `ALTER TABLE … ADD COLUMN` list of the core (56 columns), the loop that dropped `project_id` from `runs` and `triggers` (D-54), the four statements that dropped what a shard kept of its stores before D-60 (`object_stores`, `store_repair`, the `OBJECTSTORE_SECRET_KEY:*` secrets, the `vault_meta` row) and the drop of an old `log_streams`: the columns are in the `CREATE TABLE`s now (`core/schema.nim`; a fresh database and one made by the old code have the same 280 columns, types, defaults and keys, which was compared), and `migrate` has a list `columnsAdded` of the same form, empty, for the next column. The columns of the controller's state (`ctrlstate.nim`) are in its `CREATE TABLE` too. A database or a state file made before the columns existed is not read any more (the TESTING cluster's have them all).
* The host call `sh` and `ci.sh`: the tests of the sandbox and the journal run their fixture through `ci.job` and `Job:sh`. The stub host of the table pass knows `job_sh` only.
* The fields of `ArtifactRequest` and `ArtifactAck` that carried bytes (`part`, `offset`, `length`, `data`; `etag`, `data`) are `reserved`, and the baseline of the protocol check (`proto/compat/baseline.binpb`) was made again.

## Deleted (2026-10-18)

* The way of the bytes through the core (D-61): `put_part` and `get_block` are gone, `put_object` is only for a file of no bytes (its row is all there is of it, nothing is put in the store), `put_end` without the digests of the parts is refused, and a `put_begin` or a read of a shim that does not say it can send straight to the module (`direct`), or of a shard without `storage.directUrl`, is refused with `direct_required`. In the shim: `putViaCore`, the core branch of `fetchTo`, the `fallback` of `directclient` and `directState`. A module that cannot be reached is waited for as long as the patience says, like a core that is away, and then the upload fails (the drain delivers it later). The chart `cinim-shard` requires `storage.directUrl` with `storage.url`. `tools/bench/ingestmem.nim` (it measured the core's path) is gone. In the proto the fields `etag`, `data`, `offset`, `length` and `part` stay (the baseline check), unused.

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

* The Deployment `cinim-job-controller` of an organisation (before D-62 the controller was one): the core deletes it with its Pods at every pass (`superviseController`, a `DELETE` that answers 404 once none is left), and its ClusterRole keeps `delete` on `deployments` for it. Strike this line, the call and the right when no shard has one any more.

Not compatibility but interim, and to be replaced: the script of a run kept as a journal row with `seq = -1` (no store for pipeline bundles yet).
