## IAM-003, D-62: the time a controller was last heard from, which the supervision of the controller (orgreconcile.nim) judges its health by.
import std/unittest
import ../../src/core/ctrlpresence

suite "IAM-003 when a controller was last heard":
  test "nobody heard is 0; the last report counts; a forgotten namespace is 0 again":
    check lastPoll("cinim-001-acme") == 0
    notePoll("cinim-001-acme", 1000)
    notePoll("cinim-001-acme", 1005)
    notePoll("cinim-001-other", 7)
    check lastPoll("cinim-001-acme") == 1005 and lastPoll("cinim-001-other") == 7
    forgetPolls("cinim-001-acme")
    check lastPoll("cinim-001-acme") == 0 and lastPoll("cinim-001-other") == 7
