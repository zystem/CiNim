## A conductor (docs/conductors.md section 5): one Pod that leads up to `CINIM_RUNS_PER_CONDUCTOR` runs of one organisation, each in a process of
## its own. The *supervisor* (this program without arguments) keeps the connection to the core on the push channel, takes the leases the core pushes,
## starts a *run process* (this program with `--run`) for each, and carries the run's host calls to the core and the answers back over a pipe. It runs
## no Lua. A run process has one Lua state, the run's journal for replay, no credentials and no network access of its own: it has nothing but the pipe
## (its limits are set in `runMode`; a seccomp filter that denies sockets is not built yet - docs/conductors.md).
import std/[os, options, strutils, times, tables, sequtils, random]
import posix
import protobuf_serialization
import protobuf_serialization/files/type_generator
import common/[zmqcurve, stream, streamstate, runpipe]
import executor/[sandbox, journal, replay, steptable]

import_proto3 "../../build/nimproto/all.proto"

# ------------------------------------------------------------------ what both modes share

proc wireString(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

proc toJournal(entries: seq[JournalEntry]): Journal =
  # the core keeps the hash chain (T-03) and sends each record with its hash: taken as they come, and replay checks the chain
  for e in entries:
    result.entries.add Entry(seq: int(e.seq), kind: e.kind, payload: cast[string](e.payload), result: cast[string](e.result),
                             hash: cast[string](e.hash))

# ------------------------------------------------------------------ the run process

const   # Linux
  rlimitCpu = 0.cint
  rlimitCore = 4.cint
  rlimitNofile = 7.cint
  rlimitAs = 9.cint

proc prctl(option: cint; a2, a3, a4, a5: culong): cint {.importc, header: "<sys/prctl.h>".}

proc limit(resource: cint; value: int) =
  var r = RLimit(rlim_cur: value, rlim_max: value)
  discard setrlimit(resource, r)

proc runMode() =
  ## fd 0: from the supervisor; fd 1 is the way to it (stdout is moved to stderr so that nothing a script prints can look like a frame)
  let toSup = dup(1)
  discard dup2(2, 1)
  let memoryMb = try: parseInt(getEnv("CINIM_RUN_MEMORY_MB", "1024")) except ValueError: 1024
  let cpuSeconds = try: parseInt(getEnv("CINIM_RUN_CPU_SECONDS", "3600")) except ValueError: 3600
  limit(rlimitAs, memoryMb * 1024 * 1024)          # the Lua heap has its own limit (PIP-006); this is the process as a whole
  limit(rlimitCpu, cpuSeconds)
  limit(rlimitCore, 0)
  limit(rlimitNofile, 64)
  discard prctl(38, 1, 0, 0, 0)                      # PR_SET_NO_NEW_PRIVS
  proc send(kind: PipeKind; payload: string) =
    if not writePipeFd(toSup, kind, payload): quit(2)
  let first = readPipeFd(0)
  if first.isNone or first.get.kind != pkLease: quit(2)
  let g = Protobuf.decode(cast[seq[byte]](first.get.payload), LeaseGranted)
  let runId = g.run_id
  let token = g.lease_token
  let apiVersion = int(g.api_version)
  var sb = newSandbox(apiVersion = apiVersion)
  var jj = toJournal(g.journal)
  var lostLease = ""
  # the numbers of the steps (docs/parallel.md section 3): the table the core has kept, or one made now by a pass of the script and sent to the core
  var prep = prepare(g.script, g.params.mapIt((it.key, it.value)), apiVersion, g.step_table)
  if prep.refused:
    # more than 200 steps, or an id used twice: an error for the author, before anything is made
    send(pkFinish, wireString(Protobuf.encode(FinishRun(run_id: runId, state: RUN_STATE_FAILED, message: prep.message, code: prep.code, lease_token: token))))
    quit(0)
  proc callCore(seq: int; kind, payload: string; numbered = false; stepNo = 0): ExecutorResponse =
    send(pkCall, wireString(Protobuf.encode(HostCall(run_id: runId, lease_token: token, seq: uint64(seq), kind: kind,
                                                       payload: cast[seq[byte]](payload), numbered: numbered, step_no: uint32(stepNo)))))
    let back = readPipeFd(0)
    if back.isNone or back.get.kind != pkReply: quit(2)         # the supervisor is gone: nothing more to do here
    Protobuf.decode(cast[seq[byte]](back.get.payload), ExecutorResponse)
  if prep.toSend.len > 0:
    let sent = callCore(0, "table", prep.toSend)
    if sent.body.kind == ExecutorResponseBodyKind.failure and sent.body.failure.code == "lease_lost":
      send(pkLost, sent.body.failure.detail)
      quit(0)
  let host: HostCallProc = proc (seq: int; kind, payload: string): Option[string] =
    let resp = callCore(seq, kind, payload, numbered = kind == "job_sh" and prep.numbering.lastNo >= 0, stepNo = max(prep.numbering.lastNo, 0))
    if resp.body.kind == ExecutorResponseBodyKind.failure and resp.body.failure.code == "lease_lost":
      lostLease = resp.body.failure.detail
      return none(string)
    if resp.body.kind == ExecutorResponseBodyKind.failure:
      raise (ref HostRefusal)(code: resp.body.failure.code, msg: resp.body.failure.detail)
    if resp.body.kind != ExecutorResponseBodyKind.result: return none(string)
    if resp.body.result.suspended: return none(string)
    some(cast[string](resp.body.result.result))
  let r = replay.execute(sb, jj, g.script, host, runId = runId, params = g.params.mapIt((it.key, it.value)),
                         onSite = proc (seq: int; kind: string; line: int) = prep.numbering.onSite(kind, line))
  if lostLease.len > 0:
    send(pkLost, lostLease)
  elif r.status == esSuspended:
    send(pkSuspended, r.message)
  else:
    send(pkFinish, wireString(Protobuf.encode(FinishRun(run_id: runId,
      state: (if r.status == esDone: RUN_STATE_SUCCEEDED else: RUN_STATE_FAILED), message: r.message, code: r.code, lease_token: token))))
  quit(0)

# ------------------------------------------------------------------ the supervisor

type
  RunProc = object
    runId: string
    pid: Pid
    toRun, fromRun: cint
    reader: PipeReader
    ended: bool               ## it said what became of the run (finished, suspended, lost)
    eof: bool

  Flight = object             ## a frame sent to the core and not answered yet
    runId: string
    payload: string
    isFinish: bool

var
  runs: Table[string, RunProc]
  flights: Table[uint64, Flight]
  stopping = false

proc onTerm(sig: cint) {.noconv.} = stopping = true

proc startRun(g: LeaseGranted): bool =
  var inP, outP: array[2, cint]      # inP: supervisor writes [1], run reads [0]; outP: run writes [1], supervisor reads [0]
  if not openPipe(inP) or not openPipe(outP): return false
  for fd in [inP[1], outP[0]]: discard fcntl(fd, F_SETFD, FD_CLOEXEC)       # the other runs must not inherit this run's ends
  for fd in [inP[0], outP[1]]: discard fcntl(fd, F_SETFD, FD_CLOEXEC)
  var actions: Tposix_spawn_file_actions
  var attr: Tposix_spawnattr
  discard posix_spawn_file_actions_init(actions)
  discard posix_spawnattr_init(attr)
  discard posix_spawn_file_actions_adddup2(actions, inP[0], 0)
  discard posix_spawn_file_actions_adddup2(actions, outP[1], 1)
  let argv = allocCStringArray([getAppFilename(), "--run"])
  # the run process gets no environment of the Pod: no credentials, no addresses; only its limits
  let envp = allocCStringArray(["CINIM_RUN_MEMORY_MB=" & getEnv("CINIM_RUN_MEMORY_MB", "1024"),
                                "CINIM_RUN_CPU_SECONDS=" & getEnv("CINIM_RUN_CPU_SECONDS", "3600")])
  var pid: Pid
  let rc = posix_spawn(pid, getAppFilename().cstring, actions, attr, argv, envp)
  discard posix_spawn_file_actions_destroy(actions)
  discard posix_spawnattr_destroy(attr)
  deallocCStringArray(argv)
  deallocCStringArray(envp)
  closeFd inP[0]
  closeFd outP[1]
  if rc != 0:
    closeFd inP[1]
    closeFd outP[0]
    return false
  runs[g.run_id] = RunProc(runId: g.run_id, pid: pid, toRun: inP[1], fromRun: outP[0])
  writePipeFd(inP[1], pkLease, wireString(Protobuf.encode(g)))

proc closeRun(r: RunProc) =
  closeFd r.toRun
  closeFd r.fromRun

proc main() =
  setStdIoUnbuffered()
  randomize()
  let
    certs = getEnv("CINIM_CERTS", getCurrentDir() / "tests" / "certs")
    addr0 = getEnv("CINIM_CORE_STREAM_ADDR", "")
    ns = getEnv("CINIM_NAMESPACE", "")
    conductorId = getEnv("CINIM_CONDUCTOR_ID", "")
    credential = getEnv("CINIM_CONDUCTOR_CREDENTIAL", "")
    perConductor = try: parseInt(getEnv("CINIM_RUNS_PER_CONDUCTOR", "10")) except ValueError: 10
    drainSeconds = try: parseInt(getEnv("CINIM_DRAIN_SECONDS", "30")) except ValueError: 30
  if addr0.len == 0 or ns.len == 0 or conductorId.len == 0 or credential.len == 0:
    stderr.writeLine "conductor: CINIM_CORE_STREAM_ADDR, CINIM_NAMESPACE, CINIM_CONDUCTOR_ID and CINIM_CONDUCTOR_CREDENTIAL are required"
    quit 2
  signal(SIGTERM, onTerm)
  signal(SIGINT, onTerm)
  signal(SIGPIPE, SIG_IGN)
  var session = conductorId & "-" & $getCurrentProcessId() & "-" & $rand(1_000_000_000)
  let conn = connectStream(addr0, loadPublicKey(certs, "core"), loadKeypair(certs, "client"))
  var inbox = initInbox()
  var frameNo = 0'u64
  var helloDirty = true
  var lastHello = 0.0
  echo "conductor: ", conductorId, " for ", ns, ", session ", session, ", up to ", perConductor, " runs"

  proc sendHello() =
    inc frameNo
    let free = if stopping: 0 else: max(0, perConductor - runs.len)
    let hello = ConductorHello(conductor_id: conductorId, namespace: ns, credential: credential,
                               api_versions: executorApiVersions().mapIt(uint32(it)), free_places: uint32(free), held_runs: toSeq(runs.keys))
    discard conn.sendFrame(frame(session, "conductor.hello", wireString(Protobuf.encode(hello)), id = frameNo, ack = inbox.ackValue, key = ns & "#conductors"))
    helloDirty = false
    lastHello = epochTime()

  proc sendToCore(f: Flight) =
    inc frameNo
    flights[frameNo] = f
    discard conn.sendFrame(frame(session, "conductor.call", f.payload, id = frameNo, ack = inbox.ackValue, key = ns & "#conductors"))

  proc onCore(f: StreamFrame) =
    case f.kind
    of "conductor.lease":
      case inbox.accept(f.id)
      of acApply:
        let g = Protobuf.decode(cast[seq[byte]](f.payload), LeaseGranted)
        if g.run_id notin runs:
          if startRun(g): echo "conductor: run ", g.run_id, " started"
          else: stderr.writeLine "conductor: could not start a process for run " & g.run_id & "; its lease runs out and the core gives it to another"
        discard conn.sendFrame(frame(session, "ping", ack = inbox.ackValue, key = ns & "#conductors"))      # acknowledged at once, so that it is not sent again
        helloDirty = true
      of acDuplicate: discard conn.sendFrame(frame(session, "ping", ack = inbox.ackValue, key = ns & "#conductors"))
      of acGap: discard
    of "conductor.reply":
      if f.re in flights:
        let fl = flights[f.re]
        flights.del f.re
        if not fl.isFinish and fl.runId in runs:
          discard writePipeFd(runs[fl.runId].toRun, pkReply, f.payload)
    of "conductor.drain":
      if not stopping:
        stopping = true
        echo "conductor: the core asks it to drain"
    of "conductor.welcome":
      if f.payload == "unauthorized":
        stderr.writeLine "conductor: the core does not accept this conductor's credential"
        quit 3
    of "resync":
      # the core does not know this session (it was restarted, or dropped us): its numbering starts again, so ours must too
      inbox = initInbox()
      helloDirty = true
      for id, fl in flights:
        discard conn.sendFrame(frame(session, "conductor.call", fl.payload, id = id, ack = inbox.ackValue, key = ns & "#conductors"))
    else: discard

  proc pump() =
    ## what the run processes have said, without waiting for them
    var done: seq[string]
    for id, r in runs.mpairs:
      var pfd = TPollfd(fd: r.fromRun, events: POLLIN)
      while not r.eof and poll(addr pfd, 1, 0) > 0:
        var buf: array[65536, char]
        let n = read(r.fromRun, addr buf[0], buf.len)
        if n <= 0:
          r.eof = true
          break
        var chunk = newString(n)
        copyMem(addr chunk[0], addr buf[0], n)
        r.reader.feed chunk
      while true:
        let fr = r.reader.next
        if fr.isNone: break
        case fr.get.kind
        of pkCall:
          let call = Protobuf.decode(cast[seq[byte]](fr.get.payload), HostCall)
          sendToCore Flight(runId: id, payload: wireString(Protobuf.encode(ExecutorRequest(header: Header(protocol: 1),
            body: ExecutorRequestBody(kind: ExecutorRequestBodyKind.call, call: call)))))
        of pkFinish:
          let fin = Protobuf.decode(cast[seq[byte]](fr.get.payload), FinishRun)
          sendToCore Flight(runId: id, isFinish: true, payload: wireString(Protobuf.encode(ExecutorRequest(header: Header(protocol: 1),
            body: ExecutorRequestBody(kind: ExecutorRequestBodyKind.finish, finish: fin)))))
          r.ended = true
          echo "conductor: run ", id, " finished ", fin.code
        of pkSuspended:
          r.ended = true
          echo "conductor: run ", id, " suspended"
        of pkLost:
          r.ended = true
          echo "conductor: run ", id, ": the lease is lost (", fr.get.payload, "); left to its new holder"
        else: discard
      if r.reader.broken:
        stderr.writeLine "conductor: the pipe of run " & id & " is broken"
        r.eof = true
      var status: cint
      if waitpid(r.pid, status, WNOHANG) == r.pid:
        if not r.ended:
          # it died by itself (a limit, a crash): its lease runs out and the core gives the run to a conductor again
          stderr.writeLine "conductor: the process of run " & id & " ended without a word (status " & $status & ")"
        done.add id
    for id in done:
      closeRun runs[id]
      runs.del id
      helloDirty = true

  var drainStarted = 0.0
  while true:
    if stopping and drainStarted == 0.0:
      drainStarted = epochTime()
      helloDirty = true                            # no free places: the core gives us nothing more
      echo "conductor: draining (", runs.len, " runs)"
    if stopping and (runs.len == 0 or epochTime() - drainStarted > drainSeconds.float): break
    let got = try: conn.receive(5)
              except CatchableError: none(StreamFrame)         # a signal (the drain) interrupts the wait
    if got.isSome: onCore(got.get)
    pump()
    if helloDirty or epochTime() - lastHello >= 5.0: sendHello()
  for id, r in runs:
    discard kill(r.pid, SIGKILL)
    closeRun r
  sendHello()
  conn.close()
  echo "conductor: stopped"

if paramCount() >= 1 and paramStr(1) == "--run": runMode()
else: main()
