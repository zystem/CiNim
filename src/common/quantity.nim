## A quantity of Kubernetes as bytes ("500Gi", "100Mi", "1G", "1024"): what the ResourceQuota of a namespace says about storage. Only whole numbers with the suffixes of
## bytes; anything else (a fraction, milli, an exponent, a sign, a space) is not read.
import std/[options, strutils]

func parseQuantity*(s: string): Option[uint64] =
  if s.len == 0: return none(uint64)
  var digits = 0
  while digits < s.len and s[digits] in {'0' .. '9'}: inc digits
  if digits == 0: return none(uint64)
  let suffix = s[digits .. ^1]
  let mult = case suffix
    of "": 1'u64
    of "Ki": 1'u64 shl 10
    of "Mi": 1'u64 shl 20
    of "Gi": 1'u64 shl 30
    of "Ti": 1'u64 shl 40
    of "Pi": 1'u64 shl 50
    of "k": 1_000'u64
    of "M": 1_000_000'u64
    of "G": 1_000_000_000'u64
    of "T": 1_000_000_000_000'u64
    of "P": 1_000_000_000_000_000'u64
    else: 0'u64
  if mult == 0: return none(uint64)
  try:
    let n = parseBiggestUInt(s[0 ..< digits])
    if n > high(uint64) div mult: return none(uint64)
    some(n * mult)
  except ValueError:
    none(uint64)
