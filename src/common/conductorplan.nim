## How many conductors an organisation needs and which of them the core drains (docs/conductors.md sections 4 and 5). Pure.
##
## The number is computed, not set: `ceil(runs that are active or wait / runs_per_conductor)`, with at most `pod_limit` runs counted (an organisation
## never has more active runs than that), at least `conductor_min`, at most `ceil(pod_limit / runs_per_conductor)`. The conductors are named
## `cond-1` .. `cond-N`; the controller makes the first N, and the core drains the ones above N when they have been idle for the idle time.
import std/[strutils, options]

const
  defaultRunsPerConductor* = 10
  defaultConductorMin* = 1
  maxRunsPerConductor* = 100
  conductorPrefix* = "cond-"

type CondState* = object
  id*: string
  idleSince*: float          ## when it last had no run to lead; 0 while it holds one
  draining*: bool            ## it was told to drain

func maxConductors*(podLimit, perConductor: int): int =
  let per = max(perConductor, 1)
  (max(podLimit, 1) + per - 1) div per

func desiredConductors*(activeRuns, waitingRuns, perConductor, conductorMin, podLimit: int): int =
  let per = max(perConductor, 1)
  let top = maxConductors(podLimit, per)
  let runs = min(max(activeRuns, 0) + max(waitingRuns, 0), max(podLimit, 1))
  min(max((runs + per - 1) div per, conductorMin), top)

func conductorId*(n: int): string = conductorPrefix & $n

func conductorNumber*(id: string): Option[int] =
  if not id.startsWith(conductorPrefix) or id.len == conductorPrefix.len: return none(int)
  for ch in id[conductorPrefix.len .. ^1]:
    if ch notin {'0'..'9'}: return none(int)
  let n = parseInt(id[conductorPrefix.len .. ^1])
  if n >= 1: some(n) else: none(int)

func drainTargets*(conds: seq[CondState]; desired: int; now, idleSeconds: float): seq[string] =
  ## the conductors to tell to drain: above the wanted number, holding nothing, idle for the idle time, not told already
  for c in conds:
    let n = conductorNumber(c.id)
    if n.isNone or n.get <= desired or c.draining: continue
    if c.idleSince > 0 and now - c.idleSince >= idleSeconds: result.add c.id
