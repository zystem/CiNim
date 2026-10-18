## rqlite answers an error with HTTP 200 and the error in the body (`{"results":[{"error":"..."}]}`); the client must not take that for success. A core that took a failed read for an empty
## one would see a row that is not there. Against a real rqlite; needs CINIM_RQLITE_URL.
import std/[unittest, json, os, strutils]
import common/rqlite

let url = getEnv("CINIM_RQLITE_URL")

suite "rqlite client: a 200 with an error in the body is an error":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    test "a read that fails (a table that is not there, a syntax error) raises RqError and does not return an empty result":
      for sql in ["SELECT * FROM table_that_is_not_there", "SELEKT 1"]:
        var raised = ""
        try: discard c.query(%*[[sql]])
        except RqError as e: raised = e.msg
        check raised.len > 0
      var why = ""
      try: discard c.query(%*[["SELECT * FROM table_that_is_not_there"]])
      except RqError as e: why = e.msg
      check "no such table" in why
    test "a write that fails raises RqError, also when it is not the first statement of the batch":
      discard c.execute(%*["DROP TABLE IF EXISTS bench_err", "CREATE TABLE bench_err (id INTEGER PRIMARY KEY)"])
      var raised = false
      try: discard c.execute(%*[["INSERT INTO bench_err (id) VALUES (1)"], ["INSERT INTO bench_err (id) VALUES (1)"]])      # the second is a duplicate key
      except RqError: raised = true
      check raised
      var again = false
      try: discard c.execute(%*[["INSERT INTO table_that_is_not_there VALUES (1)"]])
      except RqError: again = true
      check again
    test "a read that works returns its rows, and an empty one is empty":
      check c.query(%*[["SELECT 1"]])["results"][0]["values"][0][0].getInt == 1
      let none = c.query(%*[["SELECT id FROM bench_err WHERE id = 99"]])["results"][0]{"values"}
      check none == nil or none.len == 0
