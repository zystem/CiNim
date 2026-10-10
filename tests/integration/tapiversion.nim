## PIP-001: a run records the version of the Lua host API it was made with, and is leased only to an executor that can run that version
## (against a real rqlite). Needs CINIM_RQLITE_URL (a scratch rqlite); otherwise the suite is skipped.
import std/[unittest, json, os, options]
import common/[rqlite, luaapi]
import core/[schema, scheduler]

let url = getEnv("CINIM_RQLITE_URL")
const master = "master"

suite "PIP-001 the version of the host API of a run":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    proc versionOf(run: string): int =
      c.query(%*[["SELECT api_version FROM runs WHERE id = ?", run]])["results"][0]["values"][0][0].getInt
    proc lease(run: string; versions: seq[int]): Option[LeaseGranted] =
      grantLease(c, master, run, "exec-v", versions)
    proc release(run: string) =
      discard c.execute(%*[["UPDATE runs SET lease_until = 0 WHERE id = ?", run]])

    test "a new run records the current version":
      let r = co.createRun("p", "return 1")
      check versionOf(r) == currentApiVersion
    test "a run from before the versions is version 1":
      let r = co.createRun("p", "return 1")
      discard c.execute(%*[["UPDATE runs SET api_version = 1 WHERE id = ?", r]])
      check versionOf(r) == 1
    test "a run of a version the executor cannot run is not leased to it, and is to one that can":
      let r = co.createRun("p", "return 1")
      discard c.execute(%*[["UPDATE runs SET api_version = 5 WHERE id = ?", r]])
      check lease(r, @[1, 2, 3]).isNone
      let g = lease(r, @[3, 4, 5])
      check g.isSome and g.get.api_version == 5
      release(r)
    test "the lease says which version to replay with":
      let r = co.createRun("p", "return 1")
      let g = lease(r, @[currentApiVersion])
      check g.isSome and g.get.api_version == uint32(currentApiVersion)
