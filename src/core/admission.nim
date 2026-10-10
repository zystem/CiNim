## Which pending steps of an organisation may be handed to its controller now (RUN-004, docs/conductors.md section 4). Pure.
##
## Two limits, both from the organisation's execution profile:
##   - `pod_limit`: the most step Pods the organisation has in flight at once (steps handed out and not finished);
##   - `job_pod_limit`: the most one run may have in flight, `job_pod_limit_percent` of `pod_limit` (rounded up, at least 1).
## The order of the steps that may go: a higher priority first; then the run with the fewest steps in flight, so that one run with
## many steps does not take the places of the others (the fairness rule GitLab uses between projects); then the oldest step.
## The choice is made one step at a time and the counts move with it, so a single call spreads the free places across the runs.
import std/[tables, algorithm]

type
  Candidate* = object
    id*: string
    runId*: string
    priority*: int
    queuedAt*: int64

const
  minPodLimit* = 1
  maxPodLimit* = 10000
  defaultPodLimit* = 20
  defaultJobPodLimitPercent* = 20

func jobPodLimit*(podLimit, percent: int): int =
  ## the most step Pods one run may have in flight: `percent` of the organisation's limit, rounded up, at least 1, at most the limit
  if podLimit <= 0: return 1
  let byPercent = (podLimit * max(percent, 0) + 99) div 100
  result = min(max(byPercent, 1), podLimit)

func validateLimits*(podLimit, percent: int): string =
  ## "" if valid, else what is wrong (the API answers 400 with it)
  if podLimit notin minPodLimit .. maxPodLimit: "pod_limit must be " & $minPodLimit & ".." & $maxPodLimit
  elif percent notin 1 .. 100: "job_pod_limit_percent must be 1..100"
  else: ""

proc admit*(pending: seq[Candidate]; inFlightByRun: Table[string, int]; totalInFlight, podLimit, runLimit, slots: int): seq[string] =
  ## The ids of the steps to hand out, in the order to hand them out: at most `slots` of them (what the controller can take now), and
  ## never more than leaves `totalInFlight` at or below `podLimit` or any run above `runLimit`.
  var counts = inFlightByRun
  var total = totalInFlight
  var left = pending
  # steps of one run keep their order of waiting; the pick below only chooses the run
  left.sort(proc (a, b: Candidate): int =
    if a.priority != b.priority: return cmp(b.priority, a.priority)
    if a.queuedAt != b.queuedAt: return cmp(a.queuedAt, b.queuedAt)
    cmp(a.id, b.id))
  var taken = newSeq[bool](left.len)
  while result.len < slots and total < podLimit:
    var best = -1
    for i, c in left:
      if taken[i]: continue
      let n = counts.getOrDefault(c.runId, 0)
      if n >= runLimit: continue
      if best < 0:
        best = i
        continue
      let b = left[best]
      if c.priority != b.priority:
        if c.priority > b.priority: best = i
        continue
      let nb = counts.getOrDefault(b.runId, 0)
      if n < nb or (n == nb and (c.queuedAt < b.queuedAt or (c.queuedAt == b.queuedAt and c.id < b.id))): best = i
    if best < 0: break
    taken[best] = true
    result.add left[best].id
    counts[left[best].runId] = counts.getOrDefault(left[best].runId, 0) + 1
    inc total
