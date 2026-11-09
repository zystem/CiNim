## What a project says about trust (D-86): which refs are **protected**, and which privileged profiles its pipelines may use. Both are kept on the group row of the project
## (`groups.protected_refs`, `groups.allowed_profiles`, text with one entry to a line). A run on a protected ref is **trusted**: only the people who may start such a run (permission
## `run.start.protected`), or a trigger that one of them set up, make it; a secret marked `protected` goes to trusted runs only, and the profile `deploy` is used by them only. The refs are
## the names a commit was asked by (a branch or a tag): a run started by a bare SHA has no ref and is not trusted, whatever branch the commit is on.
import std/[json, strutils, algorithm]
import ../common/rqlite
import groups, refpattern, deployprofiles
export refpattern

const
  maxRefPatterns* = 32
  privilegedProfiles* = ["build", "deploy"]           ## the profiles that need a grant; the ordinary one needs none

func isFullSha*(s: string): bool =
  ## what is asked by hash has no ref (40 hex digits, or 64 for SHA-256)
  if s.len notin [40, 64]: return false
  for ch in s:
    if ch notin HexDigits: return false
  true

func refNameOf*(asked: string): string =
  ## the ref of what a run was asked for: the name itself, or "" for a hash or for nothing (the head of the repository)
  if isFullSha(asked): "" else: asked

func runRefOf*(asRef, asked: string): string =
  ## the ref a run is on: the one it was found at when it is asked for by its hash (a poll looked at the ref and found the commit), otherwise the name it was asked for by ("" for a hash or nothing)
  if asRef.len > 0: asRef else: refNameOf(asked)

func protectedBy*(patterns: seq[string]; name: string): bool =
  for p in patterns:
    if refMatches(p, name): return true

func entries(text: string): seq[string] =
  for l in text.splitLines:
    let t = l.strip
    if t.len > 0: result.add t

const inheritedColumns = ["protected_refs", "allowed_callers", "required_approvals", "default_ref", "status_target"]     ## the settings of a group that the groups below it inherit

proc chainValues*(c: var RqClient; groupId, column: string): seq[string] =
  ## the value of a setting of `groups` in every group from the top one down to this one (an empty one too), as it is stored: where the settings are inherited from (the organisation, the root,
  ## has none: its default is empty). `column` is one of `inheritedColumns`.
  doAssert column in inheritedColumns
  if groupId.len == 0: return
  let own = c.query(%*[["SELECT tenant_id FROM groups WHERE id = ?", groupId]])["results"][0]{"values"}
  if own == nil or own.len == 0: return
  for g in c.groupChain(own[0][0].getStr, groupId):
    let v = c.query(%*[["SELECT " & column & " FROM groups WHERE id = ?", g.id]])["results"][0]{"values"}
    result.add (if v == nil or v.len == 0 or v[0][0].kind == JNull: "" elif v[0][0].kind == JString: v[0][0].getStr else: $v[0][0])      # a number column comes back as a number

proc nearestValue*(c: var RqClient; groupId, column: string): string =
  ## the value of the nearest group, this one first and then the ones above, that has one: a setting that is one thing (a branch, a target), not a list
  for v in reversed(c.chainValues(groupId, column)):
    if v.len > 0 and v != "0": return v

proc ownProtectedPatterns*(c: var RqClient; groupId: string): seq[string] =
  ## what this group itself lists (what a PUT of its settings wrote)
  let v = c.chainValues(groupId, "protected_refs")
  if v.len > 0: return entries(v[^1])

proc protectedPatterns*(c: var RqClient; groupId: string): seq[string] =
  ## D-86: the refs whose runs are trusted: the patterns of the group and of every group above it (inherited: a group below can add one and cannot take one away; the organisation lists none)
  for text in c.chainValues(groupId, "protected_refs"):
    for e in entries(text):
      if e notin result: result.add e

proc setDefaultRef*(c: var RqClient; groupId, name: string) =
  ## D-82: what the repository itself says its default branch is (a poll trigger asks every minute); a name that is not one is not kept
  if groupId.len == 0 or name.len == 0 or name.len > maxPatternLen or not isRefPattern(name) or name.endsWith("*"): return
  discard c.execute(%*[["UPDATE groups SET default_ref = ? WHERE id = ? AND default_ref <> ?", name, groupId, name]])

proc defaultRef*(c: var RqClient; groupId: string): string =
  ## D-82: the branch of a project that the base of a run falls back to: what the repository says (`default_ref`), else the first protected ref that is a name (not a prefix such as `release/*`), otherwise `main`
  let named = c.nearestValue(groupId, "default_ref")                 # the project's own, else the nearest group above that has one
  if named.len > 0: return named
  for p in c.protectedPatterns(groupId):
    if not p.endsWith("*"): return p
  "main"

proc isProtectedRef*(c: var RqClient; groupId, name: string): bool =
  ## whether a run of this project asked for `name` is on a protected ref
  name.len > 0 and protectedBy(c.protectedPatterns(groupId), name)

proc ownAllowedCallers*(c: var RqClient; groupId: string): seq[string] =
  let v = c.chainValues(groupId, "allowed_callers")
  if v.len > 0: return entries(v[^1])

proc allowedCallers*(c: var RqClient; groupId: string): seq[string] =
  ## D-93: the projects (a path of a project, or of a group: all the projects under it) whose pipelines may start runs of this project with ci.trigger, whoever started them: the ones this group
  ## lists and the ones of every group above it (inherited; the organisation lists none)
  for text in c.chainValues(groupId, "allowed_callers"):
    for e in entries(text):
      if e notin result: result.add e

proc setAllowedCallers*(c: var RqClient; groupId: string; paths: seq[string]): string =
  ## "" when saved, otherwise why not
  if paths.len > maxRefPatterns: return "at most " & $maxRefPatterns & " projects"
  var clean: seq[string]
  for p in paths:
    let n = normalPath(p)
    if n.len == 0 or n.len > 200 or n.split('/').len > 8: return "a caller is the path of a project or of a group (" & p & ")"
    for ch in n:
      if ch notin {'a' .. 'z', '0' .. '9', '-', '/'}: return "a caller is the path of a project or of a group (" & p & ")"
    clean.add n
  discard c.execute(%*[["UPDATE groups SET allowed_callers = ? WHERE id = ?", clean.join("\n"), groupId]])

proc callerAllowed*(c: var RqClient; groupId, callerPath: string): bool =
  ## whether the pipelines of the project at `callerPath` may start runs of this project
  for e in c.allowedCallers(groupId):
    if callerPath == e or callerPath.startsWith(e & "/"): return true

proc ownRequiredApprovals*(c: var RqClient; groupId: string): int =
  let v = c.chainValues(groupId, "required_approvals")
  if v.len > 0: max(1, parseInt(v[^1])) else: 1

proc requiredApprovals*(c: var RqClient; groupId: string): int =
  ## D-93: how many approvals a run of this project that waits for approval needs: the most that this group or any group above it asks for, 1 when none does (inherited: a group below can ask
  ## for more and cannot ask for fewer)
  result = 1
  for v in c.chainValues(groupId, "required_approvals"):
    try: result = max(result, parseInt(v)) except ValueError: discard

proc setRequiredApprovals*(c: var RqClient; groupId: string; n: int) =
  discard c.execute(%*[["UPDATE groups SET required_approvals = ? WHERE id = ?", n, groupId]])

proc setProtectedRefs*(c: var RqClient; groupId: string; patterns: seq[string]): string =
  ## "" when saved, otherwise why not
  if patterns.len > maxRefPatterns: return "at most " & $maxRefPatterns & " patterns"
  for p in patterns:
    if not isRefPattern(p): return "a pattern is a branch or tag name, or a name followed by * (" & p & ")"
  discard c.execute(%*[["UPDATE groups SET protected_refs = ? WHERE id = ?", patterns.join("\n"), groupId]])

proc allowedProfiles*(c: var RqClient; groupId: string): seq[string] =
  ## the privileged profiles the pipelines of this project may use: what the project allows and what the groups above it allow
  if groupId.len == 0: return
  let own = c.query(%*[["SELECT tenant_id, path FROM groups WHERE id = ?", groupId]])["results"][0]{"values"}
  if own == nil or own.len == 0: return
  let tenant = own[0][0].getStr
  let parts = pathParts(own[0][1].getStr)
  var chain: seq[string]
  for i in 1 .. parts.len: chain.add parts[0 ..< i].join("/")
  for path in chain:
    let v = c.query(%*[["SELECT allowed_profiles FROM groups WHERE tenant_id = ? AND path = ?", tenant, path]])["results"][0]{"values"}
    if v != nil and v.len > 0:
      for p in entries(v[0][0].getStr):
        if p notin result: result.add p

func isDeployKind*(profile: string): bool =
  ## `deploy` and a deploy profile of the organisation (D-115) are the same kind of thing for the gate: privileged, and for trusted runs only
  profile == "deploy" or (profile.len > 0 and profile notin privilegedProfiles and profile notin reservedProfileNames)

proc setAllowedProfiles*(c: var RqClient; groupId: string; profiles: seq[string]): string =
  ## `build`, `deploy`, and the name of a deploy profile that the organisation of the project has (D-115): one that is not defined is refused, so that a typo does not grant nothing quietly
  var tenant = ""
  for p in profiles:
    if p in privilegedProfiles: continue
    if not validDeployProfileName(p): return "a profile that needs a grant is build, deploy or a deploy profile of the organisation (" & p & ")"
    if tenant.len == 0:
      let g = c.query(%*[["SELECT tenant_id FROM groups WHERE id = ?", groupId]])["results"][0]{"values"}
      if g != nil and g.len > 0: tenant = g[0][0].getStr
    if not c.deployProfileNamed(tenant, p).found: return "this organisation has no deploy profile " & p & " (PUT /api/v1/organizations/{slug}/deploy-profiles/" & p & ")"
  discard c.execute(%*[["UPDATE groups SET allowed_profiles = ? WHERE id = ?", profiles.join("\n"), groupId]])

proc profileProblem*(c: var RqClient; groupId, profile: string; trusted: bool): string =
  ## why a job of this profile may not be made in a run of this project, "" when it may. The ordinary profile is for everyone.
  if profile notin privilegedProfiles and not profile.isDeployKind: return ""
  if profile notin c.allowedProfiles(groupId):
    return "the profile \"" & profile & "\" is not allowed for this project: someone with profile.grant sets allowed_profiles of the project (PUT .../projects/{path}/settings)"
  if profile.isDeployKind and not trusted:
    return "the profile \"" & profile & "\" is for runs on a protected ref of the project (protected_refs), and this run is not on one"
  ""
