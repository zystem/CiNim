## STO-006: the core names the runs whose volume may be deleted, in every poll of their organisation's controller, until the controller says it is done
## (against a real rqlite). Needs CINIM_RQLITE_URL; otherwise the suite is skipped.
import std/[unittest, json, os, times]
import common/rqlite
import core/[schema, scheduler, loggate, logcircuit, runstorage]

let url = getEnv("CINIM_RQLITE_URL")

suite "STO-006 the volume of a finished run":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let org = c.addOrganization("s-" & sfx, "S")
    let ns = "cinim-001-s-" & sfx
    let prof = c.ensureOrganizationProfile(org, ns)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    putEnv("CINIM_STORAGE_RETENTION_SUCCEEDED", "0")
    putEnv("CINIM_STORAGE_RETENTION_FAILED", "3600")
    runstorage.coreStartedAt = 0          # the grace after a start has its own tests (tstoragepressure)
    proc setState(runId, state: string; endedAgo: int) =
      discard c.execute(%*[["UPDATE runs SET state = ?, updated_at = ? WHERE id = ?", state, $(getTime().toUnix() - endedAgo), runId]])
    proc poll(released: seq[string] = @[]): seq[string] =
      handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-s-" & sfx, namespace: ns, free_pod_slots: 0, storage_released: released)).release_storage

    test "a run that is still going keeps its volume; one that succeeded releases it at once; one that failed a day later":
      let going = co.createRun("p", "return 1", org, prof)
      let ok = co.createRun("p", "return 1", org, prof)
      let failedNow = co.createRun("p", "return 1", org, prof)
      let failedOld = co.createRun("p", "return 1", org, prof)
      setState(ok, "SUCCEEDED", 5)
      setState(failedNow, "FAILED", 60)
      setState(failedOld, "FAILED", 7200)
      let named = poll()
      check ok in named and failedOld in named
      check going notin named and failedNow notin named
    test "the controller's answer ends it: a released run is not named again, the others are until their turn":
      let a = co.createRun("p", "return 1", org, prof)
      setState(a, "SUCCEEDED", 5)
      check a in poll(@["s1_nothing"])    # a poll that carries an answer looks at once; without one it looks every ten seconds
      check a notin poll(@[a])
      check a notin poll(@[a])
    test "another organisation's controller is not told about this one's runs":
      let r = co.createRun("p", "return 1", org, prof)
      setState(r, "SUCCEEDED", 5)
      let other = handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-o-" & sfx, namespace: "cinim-001-nobody-" & sfx, free_pod_slots: 0,
        storage_released: @[]))
      check r notin other.release_storage
    test "a negative retention keeps the volume for good":
      putEnv("CINIM_STORAGE_RETENTION_FAILED", "-1")
      let r = co.createRun("p", "return 1", org, prof)
      setState(r, "FAILED", 100000)
      check r notin poll(@["s1_nothing"])
      putEnv("CINIM_STORAGE_RETENTION_FAILED", "3600")
    runstorage.coreStartedAt = 0          # the grace after a start has its own tests (tstoragepressure)
    c.deleteOrganization("s-" & sfx)

suite "STO-006 the volume of a failed run: the grace after a start and the pressure on the storage":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let org = c.addOrganization("sp-" & sfx, "S")
    let ns = "cinim-001-sp-" & sfx
    let prof = c.ensureOrganizationProfile(org, ns)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    putEnv("CINIM_STORAGE_RETENTION_SUCCEEDED", "0")
    putEnv("CINIM_STORAGE_RETENTION_FAILED", "600")
    putEnv("CINIM_STORAGE_RETENTION_PRESSURE", "60")
    proc failed(endedAgo: int): string =
      result = co.createRun("p", "return 1", org, prof)
      discard c.execute(%*[["UPDATE runs SET state = 'FAILED', updated_at = ? WHERE id = ?", $(getTime().toUnix() - endedAgo), result]])
    proc poll(used = 0'u64, hard = 0'u64): seq[string] =
      handlePoll(c, defaultProfile, "master", PollRequest(session_id: "jc-sp-" & sfx, namespace: ns, free_pod_slots: 0,
                                                           storage_used_bytes: used, storage_hard_bytes: hard,
                                                           storage_released: @["s1_nothing"])).release_storage      # a poll that carries an answer looks at once

    test "a core that has just started releases no failed run's volume until it has been up for the retention":
      resetPressure()
      let old = failed(7200)                       # failed two hours ago
      runstorage.coreStartedAt = getTime().toUnix() - 30     # the core came back 30 seconds ago
      check old notin poll()
      runstorage.coreStartedAt = getTime().toUnix() - 700    # up for more than 10 minutes
      check old in poll()
    test "short of space (less than 15 % free), a failed run keeps its volume for a minute only, whatever the age of the core":
      resetPressure()
      let r = failed(120)                          # failed two minutes ago: within the retention of 10 minutes
      runstorage.coreStartedAt = getTime().toUnix() - 30
      check r notin poll(used = 50, hard = 100)    # half free: no pressure
      check r in poll(used = 90, hard = 100)       # 10 % free: pressure
      resetPressure()
