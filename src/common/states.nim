## State machines of the platform as data: run and step (RUN-001), launch gate (RUN-015), input (PIP-013).
## The tables are the single source of truth; docs/state-machines.md is generated from them (tools/gen_state_docs.nim)
## and the names are checked against proto/cicd/internal/v1/common.proto in the tests.

import std/[strutils]

type
  RunState* = enum
    rsCreated, rsCompiling, rsQueued, rsRunning, rsWaiting, rsSucceeded, rsFailed, rsCanceled, rsSkipped,
    rsTimedOut, rsInfrastructureError

  StepState* = enum
    ssPending, ssStarting, ssRunning, ssSucceeded, ssFailed, ssCanceled, ssTimedOut, ssLost

  GateState* = enum
    gsClosedUnknown, gsOpen, gsClosed

  InputState* = enum
    isPending, isApproved, isRejected, isExpired, isCanceled

const
  runProtoNames = ["CREATED", "COMPILING", "QUEUED", "RUNNING", "WAITING", "SUCCEEDED", "FAILED", "CANCELED", "SKIPPED",
                   "TIMED_OUT", "INFRASTRUCTURE_ERROR"]
  stepProtoNames = ["PENDING", "STARTING", "RUNNING", "SUCCEEDED", "FAILED", "CANCELED", "TIMED_OUT", "LOST"]
  gateStart* = gsClosedUnknown   ## after a scheduler restart the gate is closed until the state is received (criterion 26)

func protoName*(s: RunState): string = runProtoNames[s.ord]
func protoName*(s: StepState): string = stepProtoNames[s.ord]

func runNext*(s: RunState): set[RunState] =
  ## Compare-and-swap transitions (RUN-001). A retry of a finished run is a new run (PIP-015), so terminal states are final.
  case s
  of rsCreated: {rsCompiling, rsSkipped, rsCanceled, rsInfrastructureError}
  of rsCompiling: {rsQueued, rsFailed, rsSkipped, rsCanceled, rsInfrastructureError}
  of rsQueued: {rsRunning, rsCanceled, rsTimedOut, rsInfrastructureError}
  of rsRunning: {rsWaiting, rsSucceeded, rsFailed, rsCanceled, rsTimedOut, rsInfrastructureError}
  of rsWaiting: {rsRunning, rsCanceled, rsTimedOut, rsInfrastructureError}
  of rsSucceeded, rsFailed, rsCanceled, rsSkipped, rsTimedOut, rsInfrastructureError: {}

func stepNext*(s: StepState): set[StepState] =
  ## Step states are per attempt; a retry creates a new step attempt in `pending` (RUN-002).
  case s
  of ssPending: {ssStarting, ssCanceled, ssTimedOut}
  of ssStarting: {ssPending, ssRunning, ssFailed, ssCanceled, ssTimedOut, ssLost}
  of ssRunning: {ssSucceeded, ssFailed, ssCanceled, ssTimedOut, ssLost}
  of ssSucceeded, ssFailed, ssCanceled, ssTimedOut, ssLost: {}

func gateNext*(s: GateState): set[GateState] =
  case s
  of gsClosedUnknown: {gsOpen, gsClosed}
  of gsOpen: {gsClosed, gsClosedUnknown}
  of gsClosed: {gsOpen, gsClosedUnknown}

func inputNext*(s: InputState): set[InputState] =
  case s
  of isPending: {isApproved, isRejected, isExpired, isCanceled}
  of isApproved, isRejected, isExpired, isCanceled: {}

func isTerminal*(s: RunState): bool = runNext(s).card == 0
func isTerminal*(s: StepState): bool = stepNext(s).card == 0
func canRun*(a, b: RunState): bool = b in runNext(a)
func canStep*(a, b: StepState): bool = b in stepNext(a)

func stepGuard*(a, b: StepState): string =
  ## Condition that must hold in the same CAS write for a conditional transition ("" if unconditional).
  if a == ssStarting and b == ssPending: "no Pod exists yet (gate closed before creation)"
  else: ""

# ---------------------------------------------------------------- documentation

proc diagram[T: enum](title: string; init: T; terminalsToEnd: bool; next: proc (s: T): set[T]): string =
  result = "```mermaid\nstateDiagram-v2\n  [*] --> " & $init & "\n"
  for s in T:
    for n in next(s): result.add "  " & $s & " --> " & $n & "\n"
    if terminalsToEnd and next(s).card == 0: result.add "  " & $s & " --> [*]\n"
  result.add "```\n"

func runNextP(s: RunState): set[RunState] = runNext(s)
func stepNextP(s: StepState): set[StepState] = stepNext(s)
func gateNextP(s: GateState): set[GateState] = gateNext(s)
func inputNextP(s: InputState): set[InputState] = inputNext(s)

proc renderDocs*(): string =
  ## docs/state-machines.md, generated: `nim r tools/gen_state_docs.nim`
  result = "# State machines\n\nGenerated from `src/common/states.nim`; do not edit by hand. Tests check that this file is current and that\n" &
    "state names match `proto/cicd/internal/v1/common.proto`.\n\n"
  result.add "## Run (RUN-001)\n\nTransitions are compare-and-swap writes in rqlite. Terminal states are final: a retry of a finished run is a new run (PIP-015).\n\n"
  result.add diagram("run", rsCreated, true, runNextP)
  result.add "\n## Step attempt (RUN-001, RUN-002)\n\n`pending` is `queued` in the queue example of 7.2 and `starting` is `dispatched` (ADR 0012). A retry creates a new attempt in `pending`.\n" &
    "`starting -> pending` is allowed only when no Pod exists yet (the launch gate closed before creation, RUN-015).\n" &
    "`lost` means the Pod disappeared without a final status (RUN-002).\n\n"
  result.add diagram("step", ssPending, true, stepNextP)
  result.add "\n## Launch gate (RUN-015)\n\nThe gate is closed until the log circuit state is known (also after a scheduler restart) and closes within 10 s of a failure.\n\n"
  result.add diagram("gate", gateStart, false, gateNextP)
  result.add "\n## Input / approval (PIP-013)\n\nAn input is decided exactly once.\n\n"
  result.add diagram("input", isPending, true, inputNextP)
