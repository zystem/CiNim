## What a project says about trust (D-86): which refs are **protected**, and which privileged profiles its pipelines may use. Both are kept on the group row of the project
## (`groups.protected_refs`, `groups.allowed_profiles`, text with one entry to a line). A run on a protected ref is **trusted**: only the people who may start such a run (permission
## `run.start.protected`), or a trigger that one of them set up, make it; a secret marked `protected` goes to trusted runs only, and the profile `deploy` is used by them only. The refs are
## the names a commit was asked by (a branch or a tag): a run started by a bare SHA has no ref and is not trusted, whatever branch the commit is on.
import std/[json, strutils]
import ../common/rqlite
import groups, refpattern
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

proc protectedPatterns*(c: var RqClient; groupId: string): seq[string] =
  if groupId.len == 0: return
  let v = c.query(%*[["SELECT protected_refs FROM groups WHERE id = ?", groupId]])["results"][0]{"values"}
  if v != nil and v.len > 0: return entries(v[0][0].getStr)

proc isProtectedRef*(c: var RqClient; groupId, name: string): bool =
  ## whether a run of this project asked for `name` is on a protected ref
  name.len > 0 and protectedBy(c.protectedPatterns(groupId), name)

proc requiredApprovals*(c: var RqClient; groupId: string): int =
  ## D-93: how many approvals a run of this project that waits for approval needs (1 unless the project says more)
  if groupId.len == 0: return 1
  let v = c.query(%*[["SELECT required_approvals FROM groups WHERE id = ?", groupId]])["results"][0]{"values"}
  if v != nil and v.len > 0: max(1, v[0][0].getInt) else: 1

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

proc setAllowedProfiles*(c: var RqClient; groupId: string; profiles: seq[string]): string =
  for p in profiles:
    if p notin privilegedProfiles: return "a profile that needs a grant is build or deploy (" & p & ")"
  discard c.execute(%*[["UPDATE groups SET allowed_profiles = ? WHERE id = ?", profiles.join("\n"), groupId]])

proc profileProblem*(c: var RqClient; groupId, profile: string; trusted: bool): string =
  ## why a job of this profile may not be made in a run of this project, "" when it may. The ordinary profile is for everyone.
  if profile notin privilegedProfiles: return ""
  if profile notin c.allowedProfiles(groupId):
    return "the profile \"" & profile & "\" is not allowed for this project: someone with profile.grant sets allowed_profiles of the project (PUT .../projects/{path}/settings)"
  if profile == "deploy" and not trusted:
    return "the profile \"deploy\" is for runs on a protected ref of the project (protected_refs), and this run is not on one"
  ""
