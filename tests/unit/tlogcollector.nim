## D-27: core's log collector is a transparent proxy - block integrity and the retry/refuse decision (pure, no network).
import std/unittest
import crunchy
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
