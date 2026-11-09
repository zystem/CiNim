# Compatibility code to delete (a list, so that it is not forgotten)

The project has no release yet and the owner has said that compatibility with old data is not worth keeping for long. Each line below is code that exists only so that
something made **before** a change still works. Delete it when its condition is met, in the same commit as the change that makes it unnecessary, and strike the line here.
Found by reading the code on 2026-10-11 (`grep` for "legacy", "from before", "wire compat"); this is not a promise that nothing else is left.

*Nothing is left (2026-11-10).* A new line goes into this table when code is written that exists only for something made before a change; the list is checked against the live shard now and then (the table `columnsAdded` grew again unnoticed).



Not compatibility but interim, and to be replaced: the script of a run kept as a journal row with `seq = -1` (no store for pipeline bundles yet).

Entries that were deleted are not kept here: `git log -- docs/compat.md` has them.
