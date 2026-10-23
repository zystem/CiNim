## The body of `POST /api/v1/runs` (D-63, D-73, D-68): a script is read from git only. The request names the project (the path of a group that has a repository: `cinim` or `ci/cinim`; the repository is the project's) and, if not the head and the default, the commit and the path of the pipeline's file; a script in the
## request is refused, whoever sends it, so that every run has a history in git, and what a run ran can be found there. `POST /api/v1/pipelines:check`, which runs nothing, may still be
## given a script to look at.
import std/[json, strutils]

type RunRequestCheck* = object
  code*, message*: string              ## "" when the request may go on

proc checkRunRequest*(j: JsonNode): RunRequestCheck =
  if j == nil or j.kind != JObject:
    return RunRequestCheck(code: "invalid_request", message: "a JSON object is required: organization, project (its path), and the commit and the path of the script if not the head and the default")
  if j.hasKey("script"):
    return RunRequestCheck(code: "script_not_accepted", message: "a script is read from git: give the project (its repository holds the script); a script in the request is not taken")
  if j.hasKey("repository"):
    return RunRequestCheck(code: "repository_not_accepted", message: "the repository is the project's (a group with a repository): give project, for example cinim or ci/cinim")
  if j.hasKey("group"):
    return RunRequestCheck(code: "group_not_accepted", message: "a run belongs to a project, the whole path of a group that has a repository: give project, not group")
  if not j.hasKey("project") or j["project"].kind != JString or j["project"].getStr.strip(chars = {'/', ' '}).len == 0:
    return RunRequestCheck(code: "invalid_request", message: "project is required: the path of the project the run belongs to, for example cinim or ci/cinim")
