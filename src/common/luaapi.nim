## The version of the Lua host API (spec 6.7) a run is written against (PIP-001, docs/conductors.md section 6). A run records, when it is made, the
## version of the core that made it; an executor says which versions it can run; the core leases a run only to an executor that can run its
## version, and the replay uses the prelude of that version, so that an upgrade of the platform does not change the meaning of the calls of a run
## that is going. The current version and the two before it are kept; an older one leaves when the third newer one arrives.
import std/strutils

const
  currentApiVersion* = 1        ## what a run made by this build records
  keptApiVersions* = 3          ## the current one and the two before it

func supportedApiVersions*(current = currentApiVersion): seq[int] =
  for v in max(1, current - keptApiVersions + 1) .. current: result.add v

func sqlVersionList*(versions: seq[int]): string =
  ## numbers for an `IN (...)`; an executor that sent none is one from before the versions and runs version 1 only
  if versions.len == 0: return "1"
  var parts: seq[string]
  for v in versions: parts.add $v
  parts.join(",")
