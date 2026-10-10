# Compatibility code to delete (a list, so that it is not forgotten)

The project has no release yet and the owner has said that compatibility with old data is not worth keeping for long. Each line below is code that exists only so that
something made **before** a change still works. Delete it when its condition is met, in the same commit as the change that makes it unnecessary, and strike the line here.
Found by reading the code on 2026-10-11 (`grep` for "legacy", "from before", "wire compat"); this is not a promise that nothing else is left.

| What | Where | Why it exists | Delete when |
|---|---|---|---|
| Journal entries found by **place**, a row without `call_key` read as `key = place` | will be in `executor/replay.nim`, `core/journaldb.nim` once `call_key` is built (docs/parallel.md section 9a) | runs made before the keys | the runs made before the keys are over or purged; then the column is required |
| A step with `journal_seq` NULL is at `ordinal`; a host call with `numbered` false makes the number the place | `core/scheduler.nim` (`COALESCE(s.journal_seq, s.ordinal)`, `let number = if req.numbered …`), `schema.nim` (`journal_seq` nullable) | steps and executors from before the tables | one `UPDATE steps SET journal_seq = ordinal WHERE journal_seq IS NULL`, every executor rebuilt, no run in flight from before; then `numbered` and `step_no` are always sent |
| A journal without a hash chain is chained on first use (`cvLegacy`, `adoptLegacyLocked`, `legacyHashes`) | `core/journalchain.nim`, `core/journaldb.nim` | runs made before the chain (T-03) | the runs without hashes are over or purged (a run is chained the first time the core touches it, so after one more pass over the open runs there are none) |
| An executor chains a record that arrives without a hash | `executorsvc/main.nim` (`toJournal`) | a core from before the chain | the core of the shard always sends hashes (true since the chain was built); safe to delete now |
| `api_versions` empty means "version 1"; `LeaseGranted.api_version` 0 means 1 | `core/scheduler.nim` (`handleLease`), `executorsvc/main.nim`, `common/luaapi.nim` | executors and cores from before the versions of the Lua API | every executor and every core is of the new build; safe to delete now (the field becomes required) |
| `ExecutorRequest.finish_run_id` (unused field "kept for wire compat") | `proto/cicd/internal/v1/executor.proto` | the N/N-1 rule of the channel | delete the field and reserve number 4; nothing reads it |
| A namespace with no controller identity is trusted (`vLegacy`) | `common/ctrlauth.nim`, `core/scheduler.nim` (`handlePoll`) | single-tenant set-ups and tests, where the controller has no bootstrap token | every controller of a shard is enrolled (organisations are, since the core provisions them); then an empty or unknown namespace is refused. **This one is about security**, do it before a first user |
| The columns of the controller's state added by `ALTER TABLE` | `jobcontroller/ctrlstate.nim` (line "state files from before these columns") | controller state files from before | the state volumes of the controllers are made again, or a migration number replaces the ALTERs |
| The `ALTER TABLE … ADD COLUMN` list of the core | `core/schema.nim` (`migrate`) | databases from before each column | when there is a first release: fold the columns into `CREATE TABLE` and number the migrations |
| The host call `sh` and `ci.sh` (a fixture of the tests) | `executor/replay.nim` (`hostKinds`), `executor/bootstrap.lua`, `tests/unit/tluaapi.nim` (`fixtureOnly`) | the early tests of the sandbox | the tests use `Job:sh` |
| The shared executor service | `src/executorsvc`, `ExecutorChannel` on port 19741, the chart's executor | the conductors are not the only way yet | phase 5 of docs/conductors.md |

Not compatibility but interim, and to be replaced: the script of a run kept as a journal row with `seq = -1` (no store for pipeline bundles yet).
