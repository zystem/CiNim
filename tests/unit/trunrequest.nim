## D-73: a run is made from a script in git. `POST /api/v1/runs` takes a repository (with the commit and the path) and refuses a script in the request; a trigger likewise (`ttriggers`).
import std/[unittest, json, strutils]
import core/runrequest

suite "D-73, D-68 a script comes from git, and a run is of a project":
  test "D-68 a project is what a run asks for (the path of a project: `cinim` or `ci/cinim`), with a commit and a path as it likes":
    check checkRunRequest(%*{"organization": "acme", "project": "cinim", "commit": "main"}).code == ""
    check checkRunRequest(%*{"organization": "acme", "project": "ci/cinim", "commit": "main", "path": ".ci/00.lua", "params": {"A": "1"}}).code == ""
  test "D-73 a script in the request is refused with a code of its own and the way to do it, also next to a project":
    for body in [%*{"organization": "acme", "script": "return 1"}, %*{"script": ""}, %*{"organization": "acme", "project": "cinim", "script": "return 1"}]:
      let r = checkRunRequest(body)
      check r.code == "script_not_accepted"
      check "git" in r.message and "project" in r.message
  test "D-68 the repository is the project's: one in the request is refused, and so is the old name of the project (group); no project, or one that is not text, is refused":
    let repo = checkRunRequest(%*{"organization": "acme", "project": "cinim", "repository": "https://x/r.git"})
    check repo.code == "repository_not_accepted" and "project" in repo.message
    check checkRunRequest(%*{"organization": "acme", "group": "team", "project": "cinim"}).code == "group_not_accepted"
    let none = checkRunRequest(%*{"organization": "acme"})
    check none.code == "invalid_request" and "project" in none.message
    check checkRunRequest(%*{"organization": "acme", "project": 7}).code == "invalid_request"
    check checkRunRequest(%*{"organization": "acme", "project": "  / "}).code == "invalid_request"
  test "what is not an object is refused":
    check checkRunRequest(%*[1, 2]).code == "invalid_request"
    check checkRunRequest(nil).code == "invalid_request"
