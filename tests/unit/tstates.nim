## State machines of run, step, launch gate and input (RUN-001, RUN-002, RUN-006, RUN-015, PIP-013): invariants, sync with .proto, generated docs.
import std/[unittest, strutils, sets, sequtils, random, os]
import common/states

proc protoEnumNames(file, prefix: string): seq[string] =
  ## enum value names of proto/<file> with the given prefix, without the UNSPECIFIED zero value
  for line in readFile("proto" / file).splitLines:
    let l = line.strip
    if l.startsWith(prefix) and "=" in l and not l.contains("UNSPECIFIED"):
      result.add l.split('=')[0].strip

suite "RUN-001 run state machine":
  test "RUN-001 terminal states have no outgoing transitions, every other state has at least one":
    for s in RunState:
      if s.isTerminal: check runNext(s).len == 0
      else: check runNext(s).len > 0

  test "RUN-001 every state is reachable from created and every non-terminal state can still finish":
    var seen = initHashSet[RunState]()
    var stack = @[rsCreated]
    while stack.len > 0:
      let s = stack.pop
      if s in seen: continue
      seen.incl s
      for n in runNext(s): stack.add n
    check seen.len == RunState.high.ord + 1
    for s in RunState:
      if s.isTerminal: continue
      var r = initHashSet[RunState]()
      var st = @[s]
      while st.len > 0:
        let x = st.pop
        if x in r: continue
        r.incl x
        for n in runNext(x): st.add n
      check r.anyIt(it.isTerminal)

  test "RUN-006 cancel and infrastructure_error are possible from every non-terminal state":
    for s in RunState:
      if s.isTerminal: continue
      check rsCanceled in runNext(s)
      check rsInfrastructureError in runNext(s)

  test "PIP-013 waiting is entered only from running and leaves to running, canceled, timed_out or infrastructure_error":
    for s in RunState:
      if s != rsRunning: check rsWaiting notin runNext(s)
    check runNext(rsWaiting) == {rsRunning, rsCanceled, rsTimedOut, rsInfrastructureError}

  test "RUN-001 skipped is decided before execution starts; nothing returns to created":
    for s in RunState:
      if rsSkipped in runNext(s): check s in {rsCreated, rsCompiling}
      check rsCreated notin runNext(s)
    check rsRunning notin runNext(rsCreated)      # a run is compiled and queued first

  test "PIP-015 retry of a finished run is a new run: terminal states never reopen":
    for s in RunState:
      if s.isTerminal:
        for t in RunState: check not canRun(s, t)

  test "random walks along the table never leave it and always end in a terminal state":
    var r = initRand(11)
    for _ in 0 ..< 2000:
      var s = rsCreated
      for _ in 0 ..< 2000:
        let n = runNext(s).toSeq
        if n.len == 0: break
        s = n[r.rand(n.high)]
      check s.isTerminal

suite "RUN-001 step state machine":
  test "step: terminal states have no outgoing transitions, others reach a terminal state":
    for s in StepState:
      if s.isTerminal: check stepNext(s).len == 0
      else: check stepNext(s).len > 0

  test "RUN-002 lost is only reachable from starting and running (the Pod disappeared)":
    for s in StepState:
      if ssLost in stepNext(s): check s in {ssStarting, ssRunning}
    check not stepNext(ssPending).contains(ssLost)

  test "RUN-015 a dispatched step can go back to pending only while it has no Pod":
    check canStep(ssStarting, ssPending)
    check not canStep(ssRunning, ssPending)
    check stepGuard(ssStarting, ssPending) == "no Pod exists yet (gate closed before creation)"

  test "RUN-006 cancel is possible from pending, starting and running":
    for s in [ssPending, ssStarting, ssRunning]: check canStep(s, ssCanceled)

  test "RUN-002 a retry is a new attempt starting at pending, not a transition out of a terminal state":
    for s in StepState:
      if s.isTerminal:
        for t in StepState: check not canStep(s, t)

suite "RUN-015 launch gate and PIP-013 input":
  test "RUN-015 the gate starts closed (unknown) and opens only after the state was received":
    check gateStart == gsClosedUnknown
    check gateNext(gsClosedUnknown) == {gsOpen, gsClosed}
    check gsOpen in gateNext(gsClosed) and gsClosed in gateNext(gsOpen)
    check gsClosedUnknown in gateNext(gsOpen)     # scheduler restart

  test "PIP-013 an input is decided once; decided inputs are final":
    check inputNext(isPending) == {isApproved, isRejected, isExpired, isCanceled}
    for s in [isApproved, isRejected, isExpired, isCanceled]: check inputNext(s).len == 0

suite "sync between code, .proto and documentation":
  test "run states match RUN_STATE_* in common.proto (names, order)":
    let fromProto = protoEnumNames("cicd/internal/v1/common.proto", "RUN_STATE_")
    check fromProto == RunState.toSeq.mapIt("RUN_STATE_" & it.protoName)

  test "step states match STEP_STATE_* in common.proto (names, order)":
    let fromProto = protoEnumNames("cicd/internal/v1/common.proto", "STEP_STATE_")
    check fromProto == StepState.toSeq.mapIt("STEP_STATE_" & it.protoName)

  test "docs/state-machines.md is generated from the tables and up to date":
    check readFile("docs/state-machines.md") == renderDocs()
