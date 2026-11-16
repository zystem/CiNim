## Specification 9.1 (errors are Problem Details with a `request_id`): an exception that no handler of the API expected is told to the operator and not to the client (src/core/apifailure.nim). The text of an exception may hold a query,
## a path or an address of the inside; the client gets a reference by which the operator finds the line in the log of the core.
import std/[unittest, strutils]
import core/apifailure

suite "specification 9.1: an unexpected failure of the API":
  test "the client is told a reference and nothing of the exception":
    let f = apiFailure("ab12cd34", "POST", "/api/v1/runs", newException(ValueError, "no such column: runs.secret_x at http://rqlite-0.rqlite:4001"))
    check f.detail == "an internal error; the log of the core has it as ab12cd34"
    check "secret_x" notin f.detail and "rqlite" notin f.detail and "ValueError" notin f.detail

  test "the log has the reference, the request, the kind of the exception and its text on one line":
    let f = apiFailure("ab12cd34", "POST", "/api/v1/runs?x=1", newException(ValueError, "line one\r\nline two"))
    check f.log == "core: api: internal error ab12cd34: POST /api/v1/runs: ValueError: line one  line two"

  test "a long text is cut, and the query of the address (it may carry what a client typed) is not written":
    let f = apiFailure("r", "GET", "/api/v1/audit?token=abc", newException(IOError, 'x'.repeat(2000)))
    check f.log.len < 500
    check "token=abc" notin f.log
    check f.log.endsWith("...")

  test "a reference is eight characters of the alphabet of the ids, and two are not the same":
    let a = failureRef()
    let b = failureRef()
    check a.len == 8 and b.len == 8 and a != b
    check a.allCharsInSet({'0' .. '9', 'a' .. 'f'})
