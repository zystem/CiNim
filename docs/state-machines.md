# State machines

Generated from `src/common/states.nim`; do not edit by hand. Tests check that this file is current and that
state names match `proto/cicd/internal/v1/common.proto`.

## Run (RUN-001)

Transitions are compare-and-swap writes in rqlite. Terminal states are final: a retry of a finished run is a new run (PIP-015).

```mermaid
stateDiagram-v2
  [*] --> rsCreated
  rsCreated --> rsCompiling
  rsCreated --> rsWaiting
  rsCreated --> rsAborted
  rsCreated --> rsSkipped
  rsCreated --> rsInfrastructureError
  rsCompiling --> rsQueued
  rsCompiling --> rsFailed
  rsCompiling --> rsAborted
  rsCompiling --> rsSkipped
  rsCompiling --> rsInfrastructureError
  rsQueued --> rsRunning
  rsQueued --> rsFailed
  rsQueued --> rsAborted
  rsQueued --> rsTimedOut
  rsQueued --> rsInfrastructureError
  rsRunning --> rsWaiting
  rsRunning --> rsOk
  rsRunning --> rsFailed
  rsRunning --> rsAborted
  rsRunning --> rsTimedOut
  rsRunning --> rsInfrastructureError
  rsWaiting --> rsQueued
  rsWaiting --> rsRunning
  rsWaiting --> rsFailed
  rsWaiting --> rsAborted
  rsWaiting --> rsTimedOut
  rsWaiting --> rsInfrastructureError
  rsOk --> [*]
  rsFailed --> [*]
  rsAborted --> [*]
  rsSkipped --> [*]
  rsTimedOut --> [*]
  rsInfrastructureError --> [*]
```

## Step attempt (RUN-001, RUN-002)

`pending` is `queued` in the queue example of 7.2 and `starting` is `dispatched` (A.3). A retry creates a new attempt in `pending`.
`starting -> pending` is allowed only when no Pod exists yet (the launch gate closed before creation, RUN-015).
`lost` means the Pod disappeared without a final status (RUN-002).

```mermaid
stateDiagram-v2
  [*] --> ssPending
  ssPending --> ssStarting
  ssPending --> ssAborted
  ssPending --> ssTimedOut
  ssStarting --> ssPending
  ssStarting --> ssRunning
  ssStarting --> ssFailed
  ssStarting --> ssAborted
  ssStarting --> ssTimedOut
  ssStarting --> ssLost
  ssRunning --> ssOk
  ssRunning --> ssFailed
  ssRunning --> ssAborted
  ssRunning --> ssTimedOut
  ssRunning --> ssLost
  ssOk --> [*]
  ssFailed --> [*]
  ssAborted --> [*]
  ssTimedOut --> [*]
  ssLost --> [*]
```

## Launch gate (RUN-015)

The gate is closed until the log circuit state is known (also after a scheduler restart) and closes within 10 s of a failure.

```mermaid
stateDiagram-v2
  [*] --> gsClosedUnknown
  gsClosedUnknown --> gsOpen
  gsClosedUnknown --> gsClosed
  gsOpen --> gsClosedUnknown
  gsOpen --> gsClosed
  gsClosed --> gsClosedUnknown
  gsClosed --> gsOpen
```

## Input / approval (PIP-013)

An input is decided exactly once.

```mermaid
stateDiagram-v2
  [*] --> isPending
  isPending --> isApproved
  isPending --> isRejected
  isPending --> isExpired
  isPending --> isCanceled
  isApproved --> [*]
  isRejected --> [*]
  isExpired --> [*]
  isCanceled --> [*]
```
