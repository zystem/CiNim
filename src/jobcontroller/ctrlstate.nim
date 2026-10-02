## The job-controller's own memory, in sqlite (D-29): which step Pods it created, whether it saw their container run,
## when it last read their log, whether their end has been reported to core. A restarted controller picks up exactly where the
## old one stopped (adoption) instead of forgetting its Pods; a Pod that is in the namespace but not here is an orphan.
import std/[os, strutils]
import db_connector/db_sqlite

type
  TrackedPod* = object
    name*, runId*: string
    seq*, attempt*: int
    createdAt*: int64
    started*: bool             ## this controller saw the container running (so a vanished Pod "may have run")
    lastLog*: float            ## when the Pod's log was last read (unix seconds)
    reportedAt*: int64         ## when the Pod's end was reported to core and acknowledged (0 = not yet)
    ok*: bool                  ## the reported end was a success (decides how long the Pod is kept)

  CtrlState* = object
    db: DbConn

proc openState*(path: string): CtrlState =
  ## `:memory:` for tests
  if path != ":memory:": createDir(parentDir(path))
  result.db = open(path, "", "", "")
  result.db.exec(sql"""CREATE TABLE IF NOT EXISTS pods (
    name TEXT PRIMARY KEY, run_id TEXT NOT NULL, seq INTEGER NOT NULL, attempt INTEGER NOT NULL, created_at INTEGER NOT NULL,
    started INTEGER NOT NULL DEFAULT 0, last_log REAL NOT NULL DEFAULT 0, reported_at INTEGER NOT NULL DEFAULT 0,
    ok INTEGER NOT NULL DEFAULT 0)""")

proc close*(s: CtrlState) = s.db.close()

proc rowToPod(r: Row): TrackedPod =
  TrackedPod(name: r[0], runId: r[1], seq: parseInt(r[2]), attempt: parseInt(r[3]), createdAt: parseBiggestInt(r[4]),
             started: r[5] == "1", lastLog: parseFloat(r[6]), reportedAt: parseBiggestInt(r[7]), ok: r[8] == "1")

const cols = "name, run_id, seq, attempt, created_at, started, last_log, reported_at, ok"

proc track*(s: CtrlState; name, runId: string; seq, attempt: int; now: int64) =
  ## recorded *before* the Pod is created: if the controller dies in between, the Pod it may have made is not an orphan
  s.db.exec(sql"INSERT OR IGNORE INTO pods (name, run_id, seq, attempt, created_at) VALUES (?, ?, ?, ?, ?)",
            name, runId, seq, attempt, now)

proc get*(s: CtrlState; name: string): TrackedPod =
  let r = s.db.getRow(sql("SELECT " & cols & " FROM pods WHERE name = ?"), name)
  if r[0].len > 0: result = rowToPod(r)

proc has*(s: CtrlState; name: string): bool = s.db.getValue(sql"SELECT 1 FROM pods WHERE name = ?", name) == "1"

proc markStarted*(s: CtrlState; name: string) = s.db.exec(sql"UPDATE pods SET started = 1 WHERE name = ?", name)
proc setLastLog*(s: CtrlState; name: string; t: float) = s.db.exec(sql"UPDATE pods SET last_log = ? WHERE name = ?", t, name)

proc markReported*(s: CtrlState; name: string; ok: bool; now: int64) =
  s.db.exec(sql"UPDATE pods SET reported_at = ?, ok = ? WHERE name = ?", now, (if ok: 1 else: 0), name)

proc forget*(s: CtrlState; name: string) = s.db.exec(sql"DELETE FROM pods WHERE name = ?", name)

proc active*(s: CtrlState): seq[TrackedPod] =
  ## Pods whose end has not been reported yet: the ones to watch
  for r in s.db.getAllRows(sql("SELECT " & cols & " FROM pods WHERE reported_at = 0 ORDER BY created_at")): result.add rowToPod(r)

proc reported*(s: CtrlState): seq[TrackedPod] =
  ## Pods whose end core has: kept for a while (to look at), then removed
  for r in s.db.getAllRows(sql("SELECT " & cols & " FROM pods WHERE reported_at > 0")): result.add rowToPod(r)

proc all*(s: CtrlState): seq[TrackedPod] =
  for r in s.db.getAllRows(sql("SELECT " & cols & " FROM pods")): result.add rowToPod(r)
