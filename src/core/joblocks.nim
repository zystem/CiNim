## Locks of jobs (PIP-014, D-51): `ci.job{lock = "stand"}` - one test environment, so the jobs that use it run **one at a time, in turn**, also when they belong to
## different runs. The lock is a name in the organisation. The job asks for it (host call `lock`) before its first step and gives it back (`unlock`) when its function ends,
## also when it ends with an error; a run that waits for it is suspended - it holds no conductor place and no Pod - and is led again when the lock is its.
##
##   run_locks     who holds the lock of a name now (one row per name), and how deep (a job inside a job of the same run, with the same name, does not wait for itself)
##   lock_waiters  who waits for a name, in the order of coming (a run waits for one lock at a time)
##
## The journal of the run is what makes it safe to repeat: the record of the call `lock` is written by the core at the moment the lock is granted (at once, or when it
## is the waiter's turn), so a run that is led again finds it and goes on; `unlock` is written when it is called. A lock is never held by a run that has ended: `settle`
## (every few seconds, and after each release) gives back what a finished, cancelled or lost run held, takes the finished off the waiting lists, hands a free lock to the
## first waiter, and completes a hand-over that a crash cut short (the lock is the waiter's but its record and its place on the list are still there).
## A queue is not limited: it is rows in the database, and a long one is worked off when the environment has time.
import std/[json, times]
import ../common/[rqlite, states]
import schema, journaldb, workkick

const
  lockKind* = "lock"
  unlockKind* = "unlock"
  maxLockName* = 64

func validLockName*(name: string): bool =
  ## 1 to 64 of letters, digits and . _ : -
  if name.len < 1 or name.len > maxLockName: return false
  for ch in name:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', ':', '-'}: return false
  true

const finalStates = [rsOk, rsFailed, rsAborted, rsSkipped, rsTimedOut, rsInfrastructureError]

proc finalList(): string =
  for i, s in finalStates: result.add (if i == 0: "'" else: ",'") & protoName(s) & "'"

type Waiter = object
  id: int64
  runId, profileId, name, key, payload, jobKey: string

proc firstWaiter(c: var RqClient; profileId, name: string): tuple[found: bool, w: Waiter] =
  let r = c.query(%*[["SELECT id, run_id, profile_id, name, call_key, payload, job_key FROM lock_waiters WHERE profile_id = ? AND name = ? ORDER BY id LIMIT 1", profileId, name]])
  let v = r["results"][0]{"values"}
  if v == nil or v.len == 0: return
  (true, Waiter(id: v[0][0].getBiggestInt, runId: v[0][1].getStr, profileId: v[0][2].getStr, name: v[0][3].getStr, key: v[0][4].getStr, payload: v[0][5].getStr, jobKey: v[0][6].getStr))

proc finishHandOver(c: var RqClient; w: Waiter) =
  ## the lock is the waiter's: its record is written (once) and it leaves the list, and its profile is told that the run can be led again
  discard c.appendRow(w.runId, w.key, lockKind, w.payload, "")
  discard c.execute(%*[["DELETE FROM lock_waiters WHERE id = ?", w.id]])
  discard c.execute(%*[["UPDATE runs SET dirty = 1 WHERE id = ?", w.runId]])
  kickProfile(w.profileId)

proc holderOf*(c: var RqClient; profileId, name: string): string =
  let r = c.query(%*[["SELECT run_id FROM run_locks WHERE profile_id = ? AND name = ?", profileId, name]])
  let v = r["results"][0]{"values"}
  if v != nil and v.len > 0: v[0][0].getStr else: ""

proc settleName(c: var RqClient; profileId, name: string; now: int64) =
  ## the lock of this name has no holder, or its holder is waiting for it (a hand-over a crash cut short): the first waiter gets it
  for _ in 0 ..< 100:                      # a bound, not a loop that is expected to run: each turn hands the lock to one waiter, and a waiter is never a holder at once twice
    let fw = c.firstWaiter(profileId, name)
    if not fw.found: return
    let holder = c.holderOf(profileId, name)
    if holder.len == 0:
      let got = c.execute(%*[["INSERT OR IGNORE INTO run_locks (profile_id, name, run_id, depth, acquired_at, job_key) VALUES (?, ?, ?, 1, ?, ?)", profileId, name, fw.w.runId, now, fw.w.jobKey]])
      if got["results"][0]{"rows_affected"}.getInt == 0: return        # another thread took it first
      c.finishHandOver(fw.w)
    elif holder == fw.w.runId:
      c.finishHandOver(fw.w)             # it is the waiter's already: only the record and the list are left to do
    else:
      return

proc acquire*(c: var RqClient; runId, profileId, name, key, payload: string; now: int64; jobKey = ""): bool =
  ## true: the lock is the run's now (its record is written); false: the run is on the list and waits, and its record is written when the lock is its.
  ## `jobKey` is the job of the run that asks (the first one, when a job holds it inside a job): the lock can say who holds it
  let mine = c.execute(%*[["UPDATE run_locks SET depth = depth + 1 WHERE profile_id = ? AND name = ? AND run_id = ?", profileId, name, runId]])
  if mine["results"][0]{"rows_affected"}.getInt > 0:
    discard c.appendRow(runId, key, lockKind, payload, "")
    return true
  # a free lock goes to the one who has waited longest: someone is ahead of this run if the list is not empty
  let ahead = c.firstWaiter(profileId, name)
  if not ahead.found:
    let got = c.execute(%*[["INSERT OR IGNORE INTO run_locks (profile_id, name, run_id, depth, acquired_at, job_key) VALUES (?, ?, ?, 1, ?, ?)", profileId, name, runId, now, jobKey]])
    if got["results"][0]{"rows_affected"}.getInt > 0:
      discard c.appendRow(runId, key, lockKind, payload, "")
      return true
  discard c.execute(%*[["INSERT OR IGNORE INTO lock_waiters (run_id, profile_id, name, call_key, payload, since, job_key) VALUES (?, ?, ?, ?, ?, ?, ?)", runId, profileId, name, key, payload, now, jobKey]])
  c.settleName(profileId, name, now)       # the holder may have let go between the look and the entry on the list
  let again = c.query(%*[["SELECT 1 FROM lock_waiters WHERE run_id = ?", runId]])["results"][0]{"values"}
  again == nil or again.len == 0           # the list no longer holds it: the lock came to it in the meantime

proc release*(c: var RqClient; runId, profileId, name: string; now: int64; all = false) =
  ## one level of the run's hold (all of it with `all`); when nothing is left the lock goes to the first waiter
  if not all:
    let up = c.execute(%*[["UPDATE run_locks SET depth = depth - 1 WHERE profile_id = ? AND name = ? AND run_id = ? AND depth > 1", profileId, name, runId]])
    if up["results"][0]{"rows_affected"}.getInt > 0: return
  discard c.execute(%*[["DELETE FROM run_locks WHERE profile_id = ? AND name = ? AND run_id = ?", profileId, name, runId]])
  c.settleName(profileId, name, now)

proc releaseRun*(c: var RqClient; runId: string; now: int64) =
  ## the run has ended (or is cancelled): it holds no lock and waits for none
  var held: seq[(string, string)]
  let r = c.query(%*[["SELECT profile_id, name FROM run_locks WHERE run_id = ?", runId]])["results"][0]{"values"}
  if r != nil:
    for v in r: held.add (v[0].getStr, v[1].getStr)
  discard c.execute(%*[["DELETE FROM lock_waiters WHERE run_id = ?", runId]])
  for (p, n) in held: c.release(runId, p, n, now, all = true)

proc settle*(c: var RqClient; now: int64) =
  ## the sweep: what a run that has ended still holds or waits for is let go, and every name with a list is looked at
  discard c.execute(%*[["DELETE FROM lock_waiters WHERE run_id NOT IN (SELECT id FROM runs WHERE state NOT IN (" & finalList() & "))"]])
  let dead = c.query(%*[["SELECT run_id FROM run_locks WHERE run_id NOT IN (SELECT id FROM runs WHERE state NOT IN (" & finalList() & "))"]])["results"][0]{"values"}
  if dead != nil:
    for v in dead: c.releaseRun(v[0].getStr, now)
  let names = c.query(%*[["SELECT DISTINCT profile_id, name FROM lock_waiters"]])["results"][0]{"values"}
  if names != nil:
    for v in names: c.settleName(v[0].getStr, v[1].getStr, now)

proc waitingFor*(c: var RqClient; runId: string): tuple[waiting: bool, name, heldBy: string] =
  ## for the run's view: the lock it waits for and who holds it
  let r = c.query(%*[["SELECT w.name, COALESCE(l.run_id, '') FROM lock_waiters w LEFT JOIN run_locks l ON l.profile_id = w.profile_id AND l.name = w.name WHERE w.run_id = ?", runId]])
  let v = r["results"][0]{"values"}
  if v != nil and v.len > 0: (true, v[0][0].getStr, v[0][1].getStr) else: (false, "", "")

proc lockView*(c: var RqClient; profileId: string; name = ""): JsonNode =
  ## The jobs in which the locks of an organisation are present: for each name, the job that holds it (the run, the job in it, since when, how deep) and the jobs that
  ## wait for it in the order in which they will get it. One name with `name`, every name that is held or waited for without it.
  var names: seq[string]
  if name.len > 0: names.add name
  else:
    let r = c.query(%*[["SELECT name FROM run_locks WHERE profile_id = ? UNION SELECT name FROM lock_waiters WHERE profile_id = ? ORDER BY name", profileId, profileId]])["results"][0]{"values"}
    if r != nil:
      for v in r: names.add v[0].getStr
  result = newJArray()
  for n in names:
    var entry = %*{"name": n, "holder": newJNull(), "waiting": newJArray()}
    let h = c.query(%*[["SELECT l.run_id, l.job_key, l.acquired_at, l.depth, COALESCE(r.state, '') FROM run_locks l LEFT JOIN runs r ON r.id = l.run_id WHERE l.profile_id = ? AND l.name = ?", profileId, n]])["results"][0]{"values"}
    if h != nil and h.len > 0:
      entry["holder"] = %*{"run_id": h[0][0].getStr, "job": h[0][1].getStr, "since": h[0][2].getBiggestInt, "depth": h[0][3].getInt, "run_state": h[0][4].getStr}
    let w = c.query(%*[["SELECT w.run_id, w.job_key, w.since, COALESCE(r.state, '') FROM lock_waiters w LEFT JOIN runs r ON r.id = w.run_id WHERE w.profile_id = ? AND w.name = ? ORDER BY w.id", profileId, n]])["results"][0]{"values"}
    if w != nil:
      var place = 0
      for v in w:
        inc place
        entry["waiting"].add %*{"run_id": v[0].getStr, "job": v[1].getStr, "since": v[2].getBiggestInt, "place": place, "run_state": v[3].getStr}
    if name.len == 0 or entry["holder"].kind != JNull or entry["waiting"].len > 0: result.add entry
