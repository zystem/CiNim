## RUN-016, RUN-017: a step whose shim keeps sending heartbeats is alive, however long ago its last *event* was; one whose shim went silent is lost
## after `liveness_timeout` (against a real rqlite). Needs CINIM_RQLITE_URL; otherwise the suite is skipped.
import std/[unittest, json, os, times]
import common/rqlite
import core/[schema, scheduler, components]

let url = getEnv("CINIM_RQLITE_URL")

suite "RUN-017 the watchdog counts heartbeats":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    proc runningStep(): tuple[run: string, seq: int] =
      ## a step that has been RUNNING for 20 minutes, its last event 20 minutes ago
      let r = co.createRun("p", "return 1")
      let long = getTime().toUnix() - 1200
      let jobId = newId()
      discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, 'j', 'RUNNING', ?)", jobId, r, defaultProfile]])
      discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at, claimed_at, shim_n, shim_phase, shim_seen_at) " &
        "VALUES (?, ?, ?, 7, 'sh', 'RUNNING', ?, 'alpine', 'true', '', '1', ?, 3, 'running', ?)", newId(), r, jobId, defaultProfile, long, long]])
      (r, 7)
    proc stateOf(r: string): string =
      c.query(%*[["SELECT state FROM steps WHERE run_id = ?", r]])["results"][0]["values"][0][0].getStr
    test "a shim that sent a heartbeat a moment ago is not lost, one that has been silent for the whole timeout is":
      let alive = runningStep()
      let silent = runningStep()
      discard registryTouch("shim", alive.run & "/7/1", epochTime())
      watchdogPass(c, defaultProfile, getTime().toUnix() - 3600)
      check stateOf(alive.run) == "RUNNING"
      check stateOf(silent.run) == "LOST"
