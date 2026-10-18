## D-27: core's log collector is a transparent proxy - block integrity and the retry/refuse decision (pure, no network).
import std/unittest
import crunchy
import common/rqlite
import core/logcollector

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
