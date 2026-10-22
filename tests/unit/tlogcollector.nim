## D-27: core's log collector is a transparent proxy - block integrity and the retry/refuse decision (pure, no network).
import std/unittest
import crunchy
import common/rqlite
import core/logcollector
import ../support/fakevlagent
import std/os

suite "block integrity (checked on the compressed bytes, without decompressing)":
  test "a matching crc32c verifies":
    let data = cast[seq[byte]]("\x1f\x8b some compressed bytes")
    check verifyChunk(LogChunk(data: data, crc32c: crc32c(cast[string](data))))
  test "a flipped bit is caught":
    let data = cast[seq[byte]]("\x1f\x8b some compressed bytes")
    check not verifyChunk(LogChunk(data: data, crc32c: crc32c(cast[string](data)) xor 1'u32))
  test "an empty chunk with crc 0 is valid":
    check verifyChunk(LogChunk())

suite "what vlagent's answer means":
  test "2xx is delivered":
    for c in [200, 202, 204]: check classifyStatus(c) == frOk
  test "overload, timeouts and server errors are retried":
    for c in [408, 429, 500, 502, 503, 504]: check classifyStatus(c) == frRetry
  test "other client errors are refused for good (retrying cannot help)":
    for c in [400, 401, 403, 404, 413, 422]: check classifyStatus(c) == frRejected

suite "D-27/D-29 a core whose database does not answer keeps its threads (the answer is 'try again', never the end of the process)":
  # the database is a port that nothing listens on: every call fails the way a timed-out call does
  proc dead(): RqClient = newRq("http://127.0.0.1:1", timeoutMs = 500)
  test "a batch of the log that cannot be recorded is answered with logs_unavailable: the shim keeps its buffer and tries again":
    var c = dead()
    var req = LogBatch(step: StepRef(run_id: "s1_r", seq: 0, attempt: 1), status: ShimStatus(state_json: """{"v":1,"n":3,"t":1,"ev":"done","run":"s1_r","seq":0,"at":1,"ph":"done"}"""))
    let ack = decodeLogAck(answerLogBatch(c, Collector(rqliteUrl: "http://127.0.0.1:1"), encodeLogBatch(req)))
    check ack.failure.code == "logs_unavailable"
  test "a message that is not a batch is refused for good, not retried for ever":
    var c = dead()
    let ack = decodeLogAck(answerLogBatch(c, Collector(rqliteUrl: "http://127.0.0.1:1"), "\xff\xff not a message"))
    check ack.failure.code == "rejected"
  test "a report of a step that cannot be recorded is answered 'retry later': the shim does not exit and asks again":
    var c = dead()
    let req = StepReport(step: StepRef(run_id: "s1_r", seq: 0, attempt: 1), exit_code: 0, reason: "ok", state_json: """{"v":1,"n":3,"t":1,"ev":"done","run":"s1_r","seq":0,"at":1,"ph":"done"}""")
    let ack = decodeStepReportAck(answerStepReport(c, "master", "default", encodeStepReport(req)))
    check not ack.may_exit and ack.disposition == "retry_later"

suite "D-75 the log and the state of the shim do not wait for each other":
  # the database is a port that nothing listens on; vlagent is a stand-in that takes everything
  proc dead(): RqClient = newRq("http://127.0.0.1:1", timeoutMs = 500)
  let col = Collector(rqliteUrl: "http://127.0.0.1:1", vlagentUrl: "http://127.0.0.1:18795/insert/jsonline")
  func chunk(seq: uint64): LogChunk =
    let data = cast[seq[byte]]("\x1f\x8b block " & $seq)
    LogChunk(seq: seq, data: data, crc32c: crc32c(cast[string](data)), lines: 1)
  test "setup: the stand-in for vlagent starts":
    startFakeVlagent(18795)
    sleep 300
  test "a batch of the log with no state is acknowledged by vlagent alone, whatever the database does":
    var c = dead()
    let req = LogBatch(step: StepRef(run_id: "s1_r1", seq: 0, attempt: 1), chunks: @[chunk(1), chunk(2)])
    let before = takenCount()
    let ack = decodeLogAck(answerLogBatch(c, col, encodeLogBatch(req)))
    check ack.failure.code == "" and ack.acked_seq == 2 and takenCount() == before + 1
  test "the same blocks sent again are acknowledged and not given to vlagent twice":
    var c = dead()
    let req = LogBatch(step: StepRef(run_id: "s1_r1", seq: 0, attempt: 1), chunks: @[chunk(1), chunk(2), chunk(3)])
    let before = takenCount()
    let ack = decodeLogAck(answerLogBatch(c, col, encodeLogBatch(req)))
    check ack.failure.code == "" and ack.acked_seq == 3 and takenCount() == before + 1       # only block 3 went
  test "the state of a shim with the database away is answered 'retry later' on its own channel, and the log goes on":
    var c = dead()
    let rep = StatusReport(step: StepRef(run_id: "s1_r1", seq: 0, attempt: 1), status: ShimStatus(
      state_json: """{"v":1,"n":3,"t":1,"ev":"done","run":"s1_r1","seq":0,"at":1,"ph":"done"}"""))
    let ack = decodeStatusAck(answerStatus(c, encodeStatusReport(rep)))
    check ack.failure.code == "retry_later"
    let req = LogBatch(step: StepRef(run_id: "s1_r1", seq: 0, attempt: 1), chunks: @[chunk(4)])
    check decodeLogAck(answerLogBatch(c, col, encodeLogBatch(req))).acked_seq == 4
  test "a message that is not a status report is refused for good":
    var c = dead()
    check decodeStatusAck(answerStatus(c, "\xff\xff not a message")).failure.code == "rejected"
  test "a shim without the status channel (an older controller) still sends its state in the batch: the state is recorded before the log, as before":
    var c = dead()
    let req = LogBatch(step: StepRef(run_id: "s1_r1", seq: 0, attempt: 1), chunks: @[chunk(5)],
                       status: ShimStatus(state_json: """{"v":1,"n":3,"t":1,"ev":"done","run":"s1_r1","seq":0,"at":1,"ph":"done"}"""))
    check decodeLogAck(answerLogBatch(c, col, encodeLogBatch(req))).failure.code == "logs_unavailable"
  test "teardown":
    stopFakeVlagent()
