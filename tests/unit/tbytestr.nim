import std/unittest
import ../../src/common/bytestr

suite "RUN-016 the bytes of a payload become a string":
  test "the string has the bytes and its terminating zero, also when empty":
    for payload in [@[], @[byte 0x7b, 0x7d], @[byte 1, 0, 2, 0xff]]:
      let s = bytesToStr(payload)
      check s.len == payload.len
      for i, b in payload: check byte(s[i]) == b
      check cstring(s)[s.len] == '\0'
  test "the string is a copy: the bytes may change or go after it was made":
    var payload = @[byte 'a'.ord, 'b'.ord, 'c'.ord]
    let s = bytesToStr(payload)
    payload[0] = byte 'z'.ord
    payload.setLen(0)
    check s == "abc"
