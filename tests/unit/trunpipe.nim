## docs/conductors.md section 5: the pipe between the supervisor of a conductor and a run process. Pure framing: a kind, a length, the bytes.
import std/[unittest, options, os, posix]
import common/runpipe

suite "RUN-009 the pipe between a conductor's supervisor and a run process":
  test "a frame survives encoding, with empty and binary payloads":
    var r = PipeReader()
    r.feed encodePipe(pkCall, "")
    r.feed encodePipe(pkReply, "a\0b\xff" & "c")
    let a = r.next
    check a.isSome and a.get.kind == pkCall and a.get.payload == ""
    let b = r.next
    check b.isSome and b.get.kind == pkReply and b.get.payload == "a\0b\xff" & "c"
    check r.next.isNone
  test "a frame arriving in pieces is complete only when all of it is there":
    let bytes = encodePipe(pkFinish, "0123456789")
    var r = PipeReader()
    for i in 0 ..< bytes.len - 1:
      r.feed bytes[i .. i]
      check r.next.isNone
    r.feed bytes[^1 .. ^1]
    check r.next.isSome
  test "two frames in one read come out in order":
    var r = PipeReader()
    r.feed encodePipe(pkCall, "one") & encodePipe(pkCall, "two")
    check r.next.get.payload == "one"
    check r.next.get.payload == "two"
  test "a frame that claims to be too long, or of a kind that does not exist, breaks the reader instead of waiting for it":
    var r = PipeReader()
    r.feed "C\xff\xff\xff\xff"
    check r.next.isNone and r.broken
    var r2 = PipeReader()
    r2.feed "Z\0\0\0\0"
    check r2.next.isNone and r2.broken
  test "RUN-009 of the 256 bytes that can start a frame exactly the 8 letters of the kinds are taken, with the reader and with the blocking read":
    var taken = 0
    for b in 0 .. 255:
      let frame = $char(b) & "\0\0\0\0"
      var r = PipeReader()
      r.feed frame
      let got = r.next
      if got.isSome:
        inc taken
        check char(got.get.kind) == char(b)        # the kind is the letter that named it, not some other value of the enum
      else:
        check r.broken
      var fds: array[2, cint]
      check openPipe(fds)
      check write(fds[1], unsafeAddr frame[0], frame.len) == frame.len
      closeFd fds[1]
      check readPipeFd(fds[0]).isSome == got.isSome
      closeFd fds[0]
    check taken == 8
  test "a frame goes through a real pipe, blocking on both sides":
    var fds: array[2, cint]
    check openPipe(fds)
    check writePipeFd(fds[1], pkLease, "hello run")
    let got = readPipeFd(fds[0])
    check got.isSome and got.get.kind == pkLease and got.get.payload == "hello run"
    closeFd fds[1]
    check readPipeFd(fds[0]).isNone          # the other end closed: no more frames
    closeFd fds[0]
