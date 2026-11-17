## E-004: the classifier of ThreadSanitizer reports (tools/test/tsanreport.nim, used by tools/test/run.sh with CINIM_TEST_TSAN=1): a race of the HTTP library is told and does not fail a run, a race with
## a frame of src/ (or of a test, or of nimgrpc) does. The reports are as GCC 13's libtsan prints them for a Nim program (2026-11-16); the paths are those of a workstation and of the test image.
import std/[unittest, strutils, tables]
import ../../tools/test/tsanreport

const guildenstern = """
==================
WARNING: ThreadSanitizer: data race (pid=1160622)
  Read of size 8 at 0x720c00015ff0 by main thread:
    #0 nimDecRefIsLast lib/system/arc.nim:293 (ttransitclient+0x1a1beb)
    #1 dispatcher::eqdestroy_(var<array<range029, dispatcher::WorkerData> >) /home/u/.nimble/pkgs2/guildenstern-9.0.2-1beb59/guildenstern/dispatcher.nim:78 (ttransitclient+0x2)
    #2 NimMainModule /home/u/.nimble/pkgs2/guildenstern-9.0.2-1beb59/guildenstern/dispatcher.nim:61 (ttransitclient+0x3)
  Previous write of size 8 at 0x720c00015ff0 by thread T1:
    #0 nimIncRef lib/system/arc.nim:94 (ttransitclient+0x4)
    #1 dispatcher::eqcopy_(var<ref<dispatcher::SocketDatacolonObjectType_> >, ref<dispatcher::SocketDatacolonObjectType_>) /home/u/.nimble/pkgs2/guildenstern-9.0.2-1beb59/guildenstern/guildenselectors.nim:117 (ttransitclient+0x5)
    #2 dispatcher::processEvent(ptr<guildenserver::GuildenServerObj>, guildenselectors::ReadyKey) /home/u/.nimble/pkgs2/guildenstern-9.0.2-1beb59/guildenstern/dispatcher.nim:192 (ttransitclient+0x6)
  Location is heap block of size 48 at 0x720c00015ff0 allocated by thread T1:
    #0 malloc ../../../../src/libsanitizer/tsan/tsan_interceptors_posix.cpp:665 (libtsan.so.2+0x54b3f) (BuildId: 2a13a7710e361d06f7babbea53065ca2be93f738)
SUMMARY: ThreadSanitizer: data race lib/system/arc.nim:293 in nimDecRefIsLast
==================
"""

const ours = """
WARNING: ThreadSanitizer: data race (pid=1299876)
  Write of size 8 at 0x55d1b9d59a60 by main thread:
    #0 NimMainModule /home/u/github/CiNim/tests/integration/tconductorhub.nim:249 (tconductorhub+0x1)
  Previous read of size 8 at 0x55d1b9d59a60 by thread T3:
    #0 streamhub::housekeeping(var<streamhub::Hub>) lib/system/iterators.nim:279 (tconductorhub+0x2)
    #1 streamhub::runWorker(tuple<scheduler::Core, int, ptr<shmq::ShmQueue>, ptr<shmq::ShmQueue> >) /home/u/github/CiNim/src/core/streamhub.nim:564 (tconductorhub+0x3)
    #2 system::threadProcWrapDispatch(ptr<Thread<int> >) lib/system/threadimpl.nim:79 (tconductorhub+0x4)
  Location is global 'drainPassSeconds' of size 8 at 0x55d1b9d59a60 (tconductorhub+0x47ba60)
SUMMARY: ThreadSanitizer: data race tests/integration/tconductorhub.nim:249 in NimMainModule
"""

const inImage = """
WARNING: ThreadSanitizer: data race (pid=7)
  Write of size 8 at 0x1 by thread T2:
    #0 stream::push /cicd/workspace/src/src/common/stream.nim:201 (t+0x1)
  Previous write of size 8 at 0x1 by thread T3:
    #0 stream::push /cicd/workspace/src/src/common/stream.nim:207 (t+0x2)
SUMMARY: ThreadSanitizer: data race /cicd/workspace/src/src/common/stream.nim:201 in stream::push
"""

const leakAndSignal = """
WARNING: ThreadSanitizer: thread leak (pid=1160622)
  Thread T1 (tid=1160624, finished) created by main thread at:
    #0 pthread_create ../../../../src/libsanitizer/tsan/tsan_interceptors_posix.cpp:1022 (libtsan.so.2+0x5ac1a)
SUMMARY: ThreadSanitizer: thread leak (libtsan.so.2+0x5ac1a) in pthread_create
WARNING: ThreadSanitizer: signal-unsafe call inside of a signal (pid=1157807)
  #0 malloc ../../../../src/libsanitizer/tsan/tsan_interceptors_posix.cpp:665 (libtsan.so.2+0x54b3f)
SUMMARY: ThreadSanitizer: signal-unsafe call inside of a signal lib/system/mm/malloc.nim:7 in system::allocImpl
"""

const nimgrpcRace = """
WARNING: ThreadSanitizer: data race (pid=9)
  Write of size 8 at 0x2 by thread T1:
    #0 blocking::close /home/u/.nimble/pkgs2/nimgrpc-0.5.0-e560/nimgrpc/h2/blocking.nim:900 (t+0x1)
  Previous read of size 8 at 0x2 by thread T2:
    #0 blocking::reader /home/u/.nimble/pkgs2/nimgrpc-0.5.0-e560/nimgrpc/h2/blocking.nim:700 (t+0x2)
SUMMARY: ThreadSanitizer: data race /home/u/.nimble/pkgs2/nimgrpc-0.5.0-e560/nimgrpc/h2/blocking.nim:900 in blocking::close
"""

const runtimeOnly = """
WARNING: ThreadSanitizer: data race (pid=3)
  Write of size 8 at 0x3 by main thread:
    #0 memset ../../../../src/libsanitizer/sanitizer_common/sanitizer_common_interceptors_memintrinsics.inc:87 (libtsan.so.2+0x8bd30)
    #1 nimCopyMem lib/system/sysmem.nim:8 (t+0x1)
  Previous read of size 8 at 0x3 by thread T1:
    #0 system::threadProcWrapDispatch lib/system/threadimpl.nim:79 (t+0x2)
SUMMARY: ThreadSanitizer: data race lib/system/sysmem.nim:8 in nimCopyMem
"""

suite "E-004 the classifier of ThreadSanitizer reports":
  test "a frame is read as the name, the place and the line, without the module and the build id":
    let f = parseFrame("    #1 dispatcher::eqcopy_(var<ref<x> >, ref<x>) /home/u/pkgs2/guildenstern-9.0.2/guildenstern/guildenselectors.nim:117 (t+0x5) (BuildId: abc)")
    check f.path == "/home/u/pkgs2/guildenstern-9.0.2/guildenstern/guildenselectors.nim" and f.line == 117
    check f.fn.startsWith("dispatcher::eqcopy_(")
    check parseFrame("    #3 free tsan/tsan_interceptors_posix.cpp:724:5 (libtsan.so.2+0x1)").line == 724

  test "a race of the HTTP library is guildenstern, told and not failed on":
    let s = summarize(guildenstern)
    check s.counts == {"guildenstern": 1}.toTable
    check s.failing == 0

  test "a race that has a frame of src/ is ours, and is a failure, whichever side the frame is on":
    let s = summarize(ours)
    check s.counts == {"ours": 1}.toTable
    check s.failing == 1
    check summarize(inImage).failing == 1                     # the path in the image of the tests: /cicd/workspace/src/src/...
    check "ours: " in summarize(ours).lines[0]

  test "a race in nimgrpc is a failure too":
    check summarize(nimgrpcRace).counts == {"nimgrpc": 1}.toTable
    check summarize(nimgrpcRace).failing == 1

  test "two accesses in the runtime only are runtime; a thread leak and a signal-unsafe call are counted under their names and never fail":
    check summarize(runtimeOnly).counts == {"runtime": 1}.toTable and summarize(runtimeOnly).failing == 0
    let s = summarize(leakAndSignal)
    check s.counts == {"thread leak": 1, "signal-unsafe call inside of a signal": 1}.toTable
    check s.failing == 0

  test "a log with several reports is counted by class, and one of ours among the others makes the run fail":
    let s = summarize(guildenstern & ours & leakAndSignal & runtimeOnly)
    check s.counts["guildenstern"] == 1 and s.counts["ours"] == 1 and s.counts["runtime"] == 1 and s.counts["thread leak"] == 1
    check s.failing == 1

  test "a log with no report is nothing":
    check summarize("[OK] a test\n[Summary] 3 tests run: 3 OK\n").counts.len == 0
