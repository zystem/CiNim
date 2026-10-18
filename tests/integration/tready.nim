## The readiness of the core (`GET /readyz`): the database answers. Liveness (`/healthz`) says only that the process is there; a core that cannot reach rqlite is alive and not ready.
## Needs CINIM_RQLITE_URL (a scratch rqlite) for the case that works.
import std/[unittest, os, times]
import common/dbready

let url = getEnv("CINIM_RQLITE_URL")

suite "the core is ready when the database answers":
  test "a database that is not there is not ready, and the answer is quick and says why":
    let t0 = epochTime()
    let r = databaseReady("http://127.0.0.1:1", 500)
    check not r.ok and r.why.len > 0
    check epochTime() - t0 < 5.0
  test "a database that answers is ready":
    if url.len == 0:
      echo "  skipped: CINIM_RQLITE_URL is not set"
    else:
      check databaseReady(url, 2000).ok
  test "the answer is kept for a moment: probes do not become a load of their own":
    if url.len == 0:
      echo "  skipped: CINIM_RQLITE_URL is not set"
    else:
      let first = readyCached(url, 2000, 100.0)
      check first.ok
      check readyCached("http://127.0.0.1:1", 500, 101.0).ok          # within the moment: the earlier answer, whatever is asked now
      check not readyCached("http://127.0.0.1:1", 500, 200.0).ok      # later: asked again
