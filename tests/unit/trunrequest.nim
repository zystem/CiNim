## D-73: a run is made from a script in git. `POST /api/v1/runs` takes a repository (with the commit and the path) and refuses a script in the request; a trigger likewise (`ttriggers`).
import std/[unittest, json, strutils]
import core/runrequest

suite "D-73 a script comes from git only":
  test "D-73 a repository is what a run asks for, with a commit and a path as it likes":
    check checkRunRequest(%*{"organization": "acme", "repository": "https://example.test/r.git", "commit": "main"}).code == ""
    check checkRunRequest(%*{"organization": "acme", "repository": "https://example.test/r.git", "commit": "main", "path": ".ci/00.lua", "params": {"A": "1"}}).code == ""
  test "D-73 a script in the request is refused with a code of its own and the way to do it, also next to a repository":
    for body in [%*{"organization": "acme", "script": "return 1"}, %*{"script": ""}, %*{"organization": "acme", "repository": "https://x/r.git", "script": "return 1"}]:
      let r = checkRunRequest(body)
      check r.code == "script_not_accepted"
      check "git" in r.message and "repository" in r.message
  test "D-73 no repository is the old error with the new words, and what is not an object is refused":
    let none = checkRunRequest(%*{"organization": "acme"})
    check none.code == "invalid_request" and "repository" in none.message and "git" in none.message
    check checkRunRequest(%*[1, 2]).code == "invalid_request"
    check checkRunRequest(nil).code == "invalid_request"
