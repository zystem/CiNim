## Liveness of a step's Pod and shim as seen by core (D-29). Pure.
## One timeout from the profile (`liveness_timeout`, default 5 min, set in the UI) covers both failures core can see:
##   - the Pod never came up (bad image, unschedulable, the controller died before creating it): no word from the shim since
##     the step was handed to a controller;
##   - the shim has gone quiet: no heartbeat, no log batch, nothing from the Pod's log for this long (the shim heartbeats every
##     5 s, so this is a dead shim, a dead node or a partition that did not heal).
## Silence is measured from the later of the last sign of life and core's own start, so a restart of core never kills the Pods
## of steps that were fine while core was down.
import ../common/states

type
  Liveness* = enum
    lOk
    lStartTimeout        ## no sign of life from a step handed out at least `timeout` ago: the Pod did not come up
    lSilent              ## it had been alive, then went silent for `timeout`

  StepLiveness* = object
    state*: StepState
    claimedAt*: int64    ## when the step was handed to a controller
    shimN*: int          ## the number of the newest shim event recorded (0 = never heard from the shim)
    shimSeenAt*: int64   ## when that was recorded

func judge*(s: StepLiveness; now, coreStartedAt: int64; timeout: int): Liveness =
  if s.state notin {ssStarting, ssRunning}: return lOk
  if s.shimN == 0:
    if s.state == ssStarting and now - max(s.claimedAt, coreStartedAt) > timeout: return lStartTimeout
    return lOk
  if now - max(s.shimSeenAt, coreStartedAt) > timeout: return lSilent
  lOk
