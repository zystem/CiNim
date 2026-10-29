## A ref pattern: a branch or tag name, or a name followed by one `*` (D-86 protected refs; D-92 the refs a role binding holds for). Pure.
import std/strutils

const
  maxPatternLen* = 100

func refMatches*(pattern, name: string): bool =
  ## `main` is that name only; `release/*` and `v*` are the names that begin so (a `*` at the end only: a pattern is a name or a prefix, nothing cleverer to get wrong)
  if pattern.len == 0 or name.len == 0: return false
  if pattern.endsWith("*"):
    let head = pattern[0 ..< pattern.len - 1]
    return head.len > 0 and name.startsWith(head)
  pattern == name

func isRefPattern*(p: string): bool =
  ## letters, digits and . _ - / for a name; one * at the end; at most 100 characters
  if p.len < 1 or p.len > maxPatternLen: return false
  for i, ch in p:
    if ch == '*':
      if i != p.high or p.len == 1: return false
    elif ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '-', '/'}: return false
  true
