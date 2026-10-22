## UI-001: the run as the API gives it says when each step started and ended (epoch seconds, 0 for not yet), so that a page can say how long it took. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os]
import common/rqlite
import core/[schema, scheduler]

let url = getEnv("CINIM_RQLITE_URL")

suite "UI-001 the times of the steps of a run":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let profile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: profile, namespace: "cinim-default-ns")
    let tenant = c.addOrganization("st" & newId()[^6 .. ^1], "ST")
    let runId = co.createRun("return 1", tenant, c.ensureOrganizationProfile(tenant, "cinim-001-st"))
    proc addStep(ordinal: int; state: string; started, finished: string) =
      discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, queued_at, started_at, finished_at) " &
                            "VALUES (?, ?, 'j', ?, 'job_sh', ?, ?, 'img', 'true', '1', ?, ?)", newId(), runId, ordinal, state, profile, started, finished]])
    test "a step that ran has both times, one that goes on has a start and no end, one that has not started has neither":
      addStep(1, "SUCCEEDED", "1800000010", "1800000070")
      addStep(2, "RUNNING", "1800000080", "")
      addStep(3, "QUEUED", "", "")
      let steps = co.getRun(runId)["steps"]
      check steps[0]["started_at"].getInt == 1800000010 and steps[0]["finished_at"].getInt == 1800000070
      check steps[1]["started_at"].getInt == 1800000080 and steps[1]["finished_at"].getInt == 0
      check steps[2]["started_at"].getInt == 0 and steps[2]["finished_at"].getInt == 0
