## The body of `POST /api/v1/runs` (D-63, D-73): a script is read from git only. The request names the repository (and the commit and the path of the pipeline's file); a script in the
## request is refused, whoever sends it, so that every run has a history in git, and what a run ran can be found there. `POST /api/v1/pipelines:check`, which runs nothing, may still be
## given a script to look at.
import std/json

type RunRequestCheck* = object
  code*, message*: string              ## "" when the request may go on

proc checkRunRequest*(j: JsonNode): RunRequestCheck =
  if j == nil or j.kind != JObject:
    return RunRequestCheck(code: "invalid_request", message: "a JSON object is required: organization, repository, commit and path of the script")
  if j.hasKey("script"):
    return RunRequestCheck(code: "script_not_accepted", message: "a script is read from git: give repository, commit and path (a script in the request is not taken)")
  if not j.hasKey("repository"):
    return RunRequestCheck(code: "invalid_request", message: "repository (with commit and path) is required: the script is read from git")
