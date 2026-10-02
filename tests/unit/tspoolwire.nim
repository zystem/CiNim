import std/[unittest, strutils]
import common/spoolwire

proc fr(seq: uint64; data: string): Frame = Frame(seq: seq, firstLn: seq * 10, lines: 3, encoding: "gzip", data: data)

suite "spool frames":
  test "round trip, binary data and newlines inside the data included":
    let a = fr(1, "plain")
    let b = fr(2, "bin\0ary\nwith\nnewlines\xFF")
    let p = parseFrames(encodeFrame(a) & encodeFrame(b))
    check not p.damaged and p.frames.len == 2
    check p.frames[0] == a and p.frames[1] == b
    check p.consumed == encodeFrame(a).len + encodeFrame(b).len
  test "an incomplete last frame is left for more bytes, the whole ones before it are returned":
    let s = encodeFrame(fr(1, "first")) & encodeFrame(fr(2, "second"))
    let p = parseFrames(s[0 ..< s.len - 3])
    check p.frames.len == 1 and not p.damaged and p.consumed == encodeFrame(fr(1, "first")).len
    check parseFrames(s[0 ..< 5]).frames.len == 0
  test "a flipped bit is caught, and nothing after it is trusted":
    var s = encodeFrame(fr(1, "first")) & encodeFrame(fr(2, "second"))
    s[s.find("first")] = 'X'
    let p = parseFrames(s)
    check p.damaged and p.frames.len == 0
  test "stray output (an error from the exec) is damage, not a frame":
    check parseFrames("OCI runtime exec failed: ...\n").damaged
    check parseFrames(encodeFrame(fr(1, "ok")) & "garbage\n").damaged
  test "absurd lengths are refused":
    check parseFrames("CICD-BLK 1 0 1 gzip 99999999999 00000000\n").damaged
