## A string made of bytes. `cast[string](b)` of a `seq[byte]` is a string that has no terminating zero after its last character, and a copy of it (every `let s = cast[string](b)`, every
## call that takes the string by value) reads one byte past the end of the payload: found by AddressSanitizer (heap-buffer-overflow in `checkEffective`, tconductorhub).

proc bytesToStr*(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)
